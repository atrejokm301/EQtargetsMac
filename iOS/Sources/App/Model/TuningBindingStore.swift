//
//  TuningBindingStore.swift
//  EQtargets (iOS)
//
//  Which Fine-Tune ("Your tuning") preset each output loads by itself, the way
//  `PresetStore` binds Corrections. A phone speaker has no measurement to
//  correct against, so what it gets is taste: a Tuning, not a Correction.
//  It has its own key, so the shared Mac preset file stays as it is.
//

import Foundation
import Observation

@MainActor
@Observable
final class TuningBindingStore {

    static let key = "eqtargets.ios.tuningBindings"

    /// Output UID to the Tuning it loads.
    private(set) var bindings: [String: DeviceBinding] = [:]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let persist: Bool

    init(defaults: UserDefaults, persist: Bool = true) {
        self.defaults = defaults
        self.persist = persist
        if let data = defaults.data(forKey: Self.key),
           let b = try? JSONDecoder().decode([String: DeviceBinding].self, from: data) {
            bindings = b
        }
    }

    func bind(deviceUID: String, deviceName: String, to key: PresetKey) {
        bindings[deviceUID] = DeviceBinding(presetKey: key, deviceName: deviceName)
        save()
    }

    func unbind(deviceUID: String) {
        bindings[deviceUID] = nil
        save()
    }

    /// A deleted Tuning: the outputs that used it keep whatever is loaded.
    func removeBindings(to key: PresetKey) {
        let kept = bindings.filter { $0.value.presetKey != key }
        guard kept.count != bindings.count else { return }
        bindings = kept
        save()
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

    private func save() {
        guard persist, let data = try? JSONEncoder().encode(bindings) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
