//
//  LinkKey.swift
//  EQtargets (iOS)
//
//  The secret the app and the extension use to prove themselves to each other
//  over the loopback link (see EQTLink.h). The app makes it the first time it
//  opens. It lives in a Keychain group only these two targets can read, never
//  leaves this device, and stays readable while the phone is locked so audio
//  keeps working in a pocket.
//

import Foundation
import Security

enum LinkKey {
    static let byteCount = Int(EQT_LINK_KEY_BYTES)

    /// The Keychain calls, separate so the rules below can be tested without one.
    struct Store {
        var read: () -> (status: OSStatus, key: [UInt8]?)
        var add: ([UInt8]) -> OSStatus
        var remove: () -> OSStatus
        var random: (Int) -> [UInt8]?
    }

    /// The app's side: reuses the key or makes one. Nil keeps the link closed,
    /// because there is nothing weaker it would be safe to fall back to.
    static func loadOrCreate(using store: Store = .system) -> [UInt8]? {
        let (status, existing) = store.read()
        switch status {
        case errSecSuccess:
            if let existing, existing.count == byteCount { return existing }
            guard store.remove() == errSecSuccess else { return nil }   // damaged: replace it
        case errSecItemNotFound:
            break
        default:
            return nil
        }
        guard let fresh = store.random(byteCount), fresh.count == byteCount else { return nil }
        switch store.add(fresh) {
        case errSecSuccess:
            return fresh
        case errSecDuplicateItem:
            return load(using: store)       // created a moment ago: use that one
        default:
            return nil
        }
    }

    /// The extension's side. It never makes a key of its own: one the app doesn't
    /// have could never pass the handshake.
    static func load(using store: Store = .system) -> [UInt8]? {
        let (status, key) = store.read()
        guard status == errSecSuccess, let key, key.count == byteCount else { return nil }
        return key
    }

    /// True before the first unlock after a restart, when the app's saved settings
    /// can't be read either. The key is stored with the same protection.
    static func settingsAreLocked(using store: Store = .system) -> Bool {
        store.read().status == errSecInteractionNotAllowed
    }

    fileprivate static func randomBytes(_ count: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: count)
        return SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess ? bytes : nil
    }
}

/// The extension can be picked moments before the app first opens and makes the
/// key, so it keeps looking for as long as its session lasts: quickly at first, then
/// more slowly, so a route left selected can't keep an idle phone waking.
@MainActor
final class LinkKeyWaiter {
    typealias Schedule = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void

    private static let quickDelay: TimeInterval = 0.5
    private static let quickLooks = 60              // 30 seconds of them
    private static let slowestDelay: TimeInterval = 30

    private let store: LinkKey.Store
    private let schedule: Schedule
    private var search = 0                          // a newer search retires a scheduled look

    init(store: LinkKey.Store = .system, schedule: @escaping Schedule = LinkKeyWaiter.onMainQueue) {
        self.store = store
        self.schedule = schedule
    }

    /// Looks now and keeps looking. Starting again retires the search before it.
    func look(isWanted: @escaping @MainActor () -> Bool, found: @escaping @MainActor ([UInt8]) -> Void) {
        search += 1
        step(search, looks: 0, isWanted, found)
    }

    static func delay(afterLooks looks: Int) -> TimeInterval {
        guard looks >= quickLooks else { return quickDelay }
        let doublings = min(looks - quickLooks + 1, 16)
        return min(quickDelay * pow(2, Double(doublings)), slowestDelay)
    }

    private func step(_ id: Int, looks: Int,
                      _ isWanted: @escaping @MainActor () -> Bool,
                      _ found: @escaping @MainActor ([UInt8]) -> Void) {
        guard id == search, isWanted() else { return }
        if let key = LinkKey.load(using: store) {
            found(key)
            return
        }
        schedule(Self.delay(afterLooks: looks)) { [self] in
            step(id, looks: looks + 1, isWanted, found)
        }
    }

    static func onMainQueue(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated { action() }
        }
    }
}

extension LinkKey.Store {
    #if targetEnvironment(simulator)

    /// No extension and no shared Keychain here: the Preview's two ends share one
    /// key that lives only as long as the process.
    static let system: LinkKey.Store = {
        final class Memory: @unchecked Sendable {
            let lock = NSLock()
            var key: [UInt8]?
        }
        let memory = Memory()
        return LinkKey.Store(
            read: {
                memory.lock.withLock { memory.key.map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil) }
            },
            add: { key in
                memory.lock.withLock { memory.key = key }
                return errSecSuccess
            },
            remove: {
                memory.lock.withLock { memory.key = nil }
                return errSecSuccess
            },
            random: LinkKey.randomBytes)
    }()

    #else

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.eqtargets.ios.link",
         kSecAttrAccount as String: "link-key-v1",
         kSecAttrAccessGroup as String: Bundle.main.object(forInfoDictionaryKey: "EQTLinkKeychainGroup") as? String ?? "",
         kSecUseDataProtectionKeychain as String: true]
    }

    static let system = LinkKey.Store(
        read: {
            var q = query
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            let status = SecItemCopyMatching(q as CFDictionary, &out)
            return (status, (out as? Data).map { [UInt8]($0) })
        },
        add: { key in
            var q = query
            q[kSecValueData as String] = Data(key)
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(q as CFDictionary, nil)
        },
        remove: { SecItemDelete(query as CFDictionary) },
        random: LinkKey.randomBytes)

    #endif
}
