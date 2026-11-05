//
//  PresetStore.swift
//  EQtargets (macOS)
//
//  Built-in + user presets for both layers ("Corrections" = Target presets,
//  "Tunings" = Fine-Tune presets) and device → Correction bindings, persisted as
//  JSON in UserDefaults under `eqtargets.mac.*`.
//
//  Two details that matter:
//  • Keys, not UUIDs, identify presets. `BuiltinPresets` mints a fresh `UUID()`
//    every launch, so a saved selection of a built-in would never resolve again.
//    Built-ins are keyed by name (`builtin:<name>`), user presets by their UUID.
//  • Decoding is tolerant per element. One corrupt or older-format preset must
//    not wipe the whole library, so every record decodes on its own with
//    defaults for missing fields, and bands go through `EQLayerState.init`
//    (pads to 10 bands, clamps every range).
//

import Foundation
import Observation

struct PresetKey: Hashable, Codable, RawRepresentable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static func builtin(_ name: String) -> PresetKey { PresetKey(rawValue: "builtin:" + name) }
    static func user(_ id: UUID) -> PresetKey { PresetKey(rawValue: "user:" + id.uuidString) }

    var isBuiltin: Bool { rawValue.hasPrefix("builtin:") }
}

enum PresetKind: String, Codable {
    case correction, tuning

    var layer: EQLayer { self == .correction ? .target : .fineTune }
    init(_ layer: EQLayer) { self = layer == .target ? .correction : .tuning }
}

struct PresetEntry: Identifiable, Hashable {
    let key: PresetKey
    var name: String
    var layer: EQLayerState
    var isBuiltin: Bool { key.isBuiltin }
    var id: PresetKey { key }

    /// Copy-deck name for the built-in flat Correction.
    var displayName: String {
        key == PresetStore.flatCorrectionKey ? "None (flat)" : name
    }
}

/// Where a Correction is used. Keyed by `OutputDevice.uid`, never by name; the
/// name is stored only so Settings can list bindings for unplugged devices.
struct DeviceBinding: Codable, Hashable {
    var presetKey: PresetKey
    var deviceName: String
}

enum LayerCompare {
    /// Same sound, ignoring band identities and the layer's On switch (turning a
    /// layer off is not an edit of the preset).
    static func sameSound(_ a: EQLayerState, _ b: EQLayerState) -> Bool {
        guard abs(a.preamp - b.preamp) < 1e-6, a.bands.count == b.bands.count else { return false }
        for (x, y) in zip(a.bands, b.bands) {
            if x.filterType != y.filterType || x.isEnabled != y.isEnabled
                || abs(x.frequency - y.frequency) > 1e-6 || abs(x.gain - y.gain) > 1e-6
                || abs(x.q - y.q) > 1e-6 { return false }
        }
        return true
    }
}

// MARK: - Tolerant storage records

struct StoredLayer: Codable {
    var preamp: Double?
    var bands: [StoredBand]?

    init(_ l: EQLayerState) { preamp = l.preamp; bands = l.bands.map(StoredBand.init) }

    var layer: EQLayerState {
        EQLayerState(preamp: preamp?.isFinite == true ? preamp! : 0,
                     bands: (bands ?? []).compactMap(\.band))
    }
}

/// Wraps `EQBand`'s own (already tolerant) Codable so one bad band is skipped
/// instead of failing the whole preset.
struct StoredBand: Codable {
    var band: EQBand?
    init(_ b: EQBand) { band = b }
    init(from decoder: Decoder) throws {
        band = try? EQBand(from: decoder)
        if let b = band, !(b.frequency.isFinite && b.gain.isFinite && b.q.isFinite) { band = nil }
    }
    func encode(to encoder: Encoder) throws { try band?.encode(to: encoder) }
}

private struct StoredPreset: Codable {
    var id: UUID?
    var name: String?
    var layer: StoredLayer?
}

/// Decodes each element independently; failures are dropped, not fatal.
struct LossyArray<T: Decodable>: Decodable {
    var elements: [T]
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        var out: [T] = []
        while !c.isAtEnd {
            if let v = try? c.decode(T.self) { out.append(v) }
            else { _ = try? c.decode(Skip.self) }
        }
        elements = out
    }
    private struct Skip: Decodable {}
}

// MARK: - Store

@MainActor
@Observable
final class PresetStore {
    nonisolated static let flatCorrectionKey = PresetKey.builtin(BuiltinPresets.targets.first?.name ?? "Flat (No Target)")
    nonisolated static let flatTuningKey = PresetKey.builtin(BuiltinPresets.fineTunes.first?.name ?? "Flat / Neutral")

    enum Keys {
        static let corrections = "eqtargets.mac.presets.corrections"
        static let tunings = "eqtargets.mac.presets.tunings"
        static let bindings = "eqtargets.mac.deviceBindings"
    }

    private(set) var userCorrections: [PresetEntry] = []
    private(set) var userTunings: [PresetEntry] = []
    private(set) var bindings: [String: DeviceBinding] = [:]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let persist: Bool

    init(defaults: UserDefaults, persist: Bool = true) {
        self.defaults = defaults
        self.persist = persist
        userCorrections = Self.loadPresets(defaults, key: Keys.corrections)
        userTunings = Self.loadPresets(defaults, key: Keys.tunings)
        if let data = defaults.data(forKey: Keys.bindings),
           let b = try? JSONDecoder().decode([String: DeviceBinding].self, from: data) {
            bindings = b
        }
    }

    // MARK: Queries

    func builtins(_ kind: PresetKind) -> [PresetEntry] {
        let list = kind == .correction ? BuiltinPresets.targets : BuiltinPresets.fineTunes
        return list.map { PresetEntry(key: .builtin($0.name), name: $0.name, layer: $0.layer) }
    }

    func user(_ kind: PresetKind) -> [PresetEntry] {
        kind == .correction ? userCorrections : userTunings
    }

    func all(_ kind: PresetKind) -> [PresetEntry] { builtins(kind) + user(kind) }

    func entry(_ key: PresetKey?, _ kind: PresetKind) -> PresetEntry? {
        guard let key else { return nil }
        return all(kind).first { $0.key == key }
    }

    /// "Name", "Name 2", "Name 3"… across built-ins and user presets.
    func uniqueName(_ base: String, _ kind: PresetKind, excluding: PresetKey? = nil) -> String {
        let trimmed = String(base.trimmingCharacters(in: .whitespacesAndNewlines).prefix(AutoEQImport.maxNameLength))
        let root = trimmed.isEmpty ? (kind == .correction ? "Correction" : "Tuning") : trimmed
        let taken = Set(all(kind).filter { $0.key != excluding }.map { $0.name.lowercased() })
        if !taken.contains(root.lowercased()) { return root }
        var n = 2
        while taken.contains("\(root) \(n)".lowercased()) { n += 1 }
        return "\(root) \(n)"
    }

    // MARK: Mutations

    @discardableResult
    func add(_ kind: PresetKind, name: String, layer: EQLayerState) -> PresetEntry {
        var l = layer
        l.isBypassed = false
        let e = PresetEntry(key: .user(UUID()), name: uniqueName(name, kind), layer: l)
        if kind == .correction { userCorrections.append(e) } else { userTunings.append(e) }
        save(kind)
        return e
    }

    func update(_ key: PresetKey, _ kind: PresetKind, layer: EQLayerState) {
        mutate(key, kind) { $0.layer = layer; $0.layer.isBypassed = false }
    }

    func rename(_ key: PresetKey, _ kind: PresetKind, to name: String) {
        let unique = uniqueName(name, kind, excluding: key)
        mutate(key, kind) { $0.name = unique }
    }

    func delete(_ key: PresetKey, _ kind: PresetKind) {
        guard !key.isBuiltin else { return }
        if kind == .correction {
            userCorrections.removeAll { $0.key == key }
            // "Devices using it go back to no correction."
            bindings = bindings.filter { $0.value.presetKey != key }
            saveBindings()
        } else {
            userTunings.removeAll { $0.key == key }
        }
        save(kind)
    }

    func bind(deviceUID: String, deviceName: String, to key: PresetKey) {
        bindings[deviceUID] = DeviceBinding(presetKey: key, deviceName: deviceName)
        saveBindings()
    }

    func unbind(deviceUID: String) {
        bindings[deviceUID] = nil
        saveBindings()
    }

    func boundKey(for deviceUID: String?) -> PresetKey? {
        guard let deviceUID else { return nil }
        return bindings[deviceUID]?.presetKey
    }

    func devices(boundTo key: PresetKey) -> [(uid: String, name: String)] {
        bindings.filter { $0.value.presetKey == key }
            .map { (uid: $0.key, name: $0.value.deviceName) }
            .sorted { $0.name < $1.name }
    }

    // MARK: Persistence

    private func mutate(_ key: PresetKey, _ kind: PresetKind, _ change: (inout PresetEntry) -> Void) {
        guard !key.isBuiltin else { return }
        if kind == .correction, let i = userCorrections.firstIndex(where: { $0.key == key }) {
            change(&userCorrections[i])
        } else if kind == .tuning, let i = userTunings.firstIndex(where: { $0.key == key }) {
            change(&userTunings[i])
        } else { return }
        save(kind)
    }

    private func save(_ kind: PresetKind) {
        guard persist else { return }
        let list = user(kind).map { e -> StoredPreset in
            let id = UUID(uuidString: String(e.key.rawValue.dropFirst("user:".count)))
            return StoredPreset(id: id, name: e.name, layer: StoredLayer(e.layer))
        }
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: kind == .correction ? Keys.corrections : Keys.tunings)
        }
    }

    private func saveBindings() {
        guard persist, let data = try? JSONEncoder().encode(bindings) else { return }
        defaults.set(data, forKey: Keys.bindings)
    }

    private static func loadPresets(_ defaults: UserDefaults, key: String) -> [PresetEntry] {
        guard let data = defaults.data(forKey: key),
              let list = try? JSONDecoder().decode(LossyArray<StoredPreset>.self, from: data) else { return [] }
        var seen = Set<UUID>()
        return list.elements.compactMap { p in
            let id = p.id ?? UUID()
            guard seen.insert(id).inserted else { return nil }
            let name = (p.name?.isEmpty == false ? p.name! : "Untitled")
            return PresetEntry(key: .user(id), name: String(name.prefix(AutoEQImport.maxNameLength)),
                               layer: p.layer?.layer ?? .flat)
        }
    }
}
