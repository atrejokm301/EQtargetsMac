//
//  EQControlState.swift
//  EQtargets (iOS)
//
//  What the Control Center tiles show. The app writes it and the tile extension
//  reads it through a shared Keychain group, so the extension needs none of the
//  audio code. It is not secret: this group needs no setup in the developer portal,
//  which an App Group would.
//

import Foundation
import Security
import os

private let log = Logger(subsystem: "com.eqtargets.ios", category: "controls")

struct EQControlState: Codable, Equatable {
    var isOn: Bool
    var bassName: String
    var bassSymbol: String
    /// An app that gets killed can't say so, so On is only believed until this time.
    var onUntil: Date?

    /// Before the app has ever run, and for a damaged saved state.
    static let placeholder = EQControlState(isOn: false, bassName: "Off", bassSymbol: "speaker.slash.fill")
    static let leaseSeconds: TimeInterval = 150
    static let leaseRenewSeconds: TimeInterval = 60
}

/// How the app updates the tiles.
struct EQControlOutput {
    var save: (EQControlState) -> Bool
    var redraw: () -> Void
}

enum EQControlID {
    static let powerKind = "com.eqtargets.ios.control.power"
    static let bassKind = "com.eqtargets.ios.control.bass"
}

struct EQControlStore {
    /// The Keychain calls, separate so the rules below can be tested without one.
    struct Backing {
        var read: () -> Data?
        var update: (Data) -> OSStatus
        var add: (Data) -> OSStatus
    }

    private let backing: Backing

    init(backing: Backing = .keychain) {
        self.backing = backing
    }

    func load(now: Date = Date()) -> EQControlState {
        guard let data = backing.read(),
              var state = try? JSONDecoder().decode(EQControlState.self, from: data) else {
            return .placeholder
        }
        if state.isOn, (state.onUntil ?? .distantPast) <= now { state.isOn = false }
        return state
    }

    @discardableResult
    func save(_ state: EQControlState) -> Bool {
        guard let data = try? JSONEncoder().encode(state) else { return false }
        var status = backing.update(data)
        if status == errSecItemNotFound { status = backing.add(data) }
        guard status == errSecSuccess else {
            log.error("saving the tile state failed: \(status, privacy: .public)")
            return false
        }
        return true
    }
}

extension EQControlStore.Backing {
    /// Its own Keychain group, so the tile extension can never read the link key.
    /// The group must be named: otherwise the item lands in the app's first group.
    static func itemQuery(group: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.eqtargets.ios.controls",
         kSecAttrAccount as String: "control-state-v1",
         kSecAttrAccessGroup as String: group,
         kSecUseDataProtectionKeychain as String: true]
    }

    private static var query: [String: Any] {
        itemQuery(group: Bundle.main.object(forInfoDictionaryKey: "EQTControlsKeychainGroup") as? String ?? "")
    }

    static let keychain = EQControlStore.Backing(
        read: {
            var q = query
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
            return out as? Data
        },
        update: { data in
            SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        },
        add: { data in
            var q = query
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(q as CFDictionary, nil)
        })
}
