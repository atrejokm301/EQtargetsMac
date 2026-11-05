//
//  AppModel.swift
//  EQtargets (macOS)
//
//  The app's single source of truth: both EQ layers, Bass Style, output
//  protection, compare, selection, presets and device bindings. Views read it;
//  the engine receives it as `ChainParameters`.
//
//  Engine hand-off rules (ARCHITECTURE §4 contract):
//  • `apply` is pushed through a 60 Hz throttle with a guaranteed trailing
//    update (see `ThrottleGate`), so a 120 Hz trackpad drag never exceeds the
//    contract and the resting value always lands. Compare skips the throttle:
//    "bypass on at press-down, no delay".
//  • Identical parameters are never re-sent (`editingLayer` is normalised out:
//    which layer you edit is UI state, not DSP state).
//  • `setPowered` is called once at launch: On only if "Turn on when
//    EQtargets opens" is checked (unchecked = opens Off, as the label says).
//
//  Undo (DESIGN §6.8): snapshot-based, one step per gesture / committed field /
//  preset load / import / reset. Covers DualEQState + BassProcessorState and the
//  selected preset keys; power, routing and settings are deliberately not undoable.
//

import Foundation
import AppKit
import Observation

@MainActor
@Observable
final class AppModel {

    enum Mode { case live, preview }

    enum Keys {
        static let state = "eqtargets.mac.state"
        static let powered = "eqtargets.mac.powered"
        static let protection = "eqtargets.mac.outputProtection"
        static let pinnedOutput = "eqtargets.mac.pinnedOutputUID"
        static let onboardingDone = "eqtargets.mac.onboardingCompleted"
        static let turnOnAtLaunch = "eqtargets.mac.turnOnAtLaunch"
        static let showMenuBar = "eqtargets.mac.showMenuBarExtra"
        static let showInDock = "eqtargets.mac.showInDock"
        static let graphScale = "eqtargets.mac.graphScale"
    }

    // MARK: Dependencies

    @ObservationIgnored let engine: any EngineDriving
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let mode: Mode
    let presets: PresetStore
    let meters: MeterHub

    // MARK: Engine display

    /// Snapshot mode injects "running on AirPods" here; live mode leaves it nil.
    var displayOverride: EngineDisplay?
    var display: EngineDisplay { displayOverride ?? EngineDisplay(engine: engine) }

    // Status / power ALONE, for views that show nothing else (menu bar icon,
    // power switch, Compare, menus, banners). Reading `display` also reads
    // `engine.stats`, which the engine re-assigns every 0.5 s while audio
    // plays, so every such view re-rendered twice a second.
    var displayStatus: EngineStatus { displayOverride?.status ?? engine.status }
    var displayIsPowered: Bool { displayOverride?.isPowered ?? engine.isPowered }
    var displayIsProcessing: Bool { EngineDisplay.isProcessing(displayStatus) }

    // MARK: Sound state (persisted, undoable)

    var dual: DualEQState = .flat {
        didSet { if dual != oldValue { soundDidChange() } }
    }
    var bass: BassProcessorState = .flat {
        didSet { if bass != oldValue { soundDidChange() } }
    }
    var outputProtection = true {
        didSet {
            guard outputProtection != oldValue else { return }
            defaults.set(outputProtection, forKey: Keys.protection)
            pushParameters()
        }
    }
    var correctionKey: PresetKey? = PresetStore.flatCorrectionKey { didSet { scheduleSave() } }
    var tuningKey: PresetKey? = PresetStore.flatTuningKey { didSet { scheduleSave() } }

    // MARK: Compare

    var compareLatched = false { didSet { if compareLatched != oldValue { sendParameters() } } }
    var compareHeld = false { didSet { if compareHeld != oldValue { sendParameters() } } }
    var isComparing: Bool { compareLatched || compareHeld }

    // MARK: Selection / UI state

    /// Last band selected per layer; the inspector always shows it (never empty).
    var lastBand: [EQLayer: Int] = [.target: 0, .fineTune: 0]
    /// Whether that band is highlighted on the graph (click empty plot clears it).
    var bandHighlighted = false
    var isDraggingGraph = false
    /// Y scale held still while a graph drag is in progress (re-scales on mouse-up).
    var graphFrozenYMax: Double?
    var graphScale: GraphScale = .auto { didSet { defaults.set(graphScale.rawValue, forKey: Keys.graphScale) } }
    var showCorrectionCurve = true
    var showTuningCurve = true
    var bassPanelRegular = true
    var bassPanelCompact = false
    var isCompactWidth = false

    var toast: Toast?
    var importPreview: ImportPreview?
    var showFileImporter = false
    var namePrompt: NamePrompt?
    var pendingDelete: PendingDelete?

    // MARK: Onboarding / settings

    var onboardingCompleted: Bool { didSet { defaults.set(onboardingCompleted, forKey: Keys.onboardingDone) } }
    var onboardingStep: OnboardingStep = .welcome
    var installState: InstallState = .idle
    var turnOnAtLaunch: Bool { didSet { defaults.set(turnOnAtLaunch, forKey: Keys.turnOnAtLaunch) } }
    var showMenuBarExtra: Bool { didSet { defaults.set(showMenuBarExtra, forKey: Keys.showMenuBar) } }
    var showInDock: Bool {
        didSet {
            defaults.set(showInDock, forKey: Keys.showInDock)
            if mode == .live { NSApp.setActivationPolicy(showInDock ? .regular : .accessory) }
        }
    }
    private(set) var pinnedOutputUID: String?

    // MARK: Plumbing

    @ObservationIgnored weak var undoManager: UndoManager?
    @ObservationIgnored weak var mainWindow: NSWindow?
    @ObservationIgnored var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    @ObservationIgnored private var gate = ThrottleGate(interval: 1.0 / 60)
    @ObservationIgnored private var trailingPush: Task<Void, Never>?
    @ObservationIgnored private(set) var lastPushed: ChainParameters?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var gestureStart: EditSnapshot?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var resignActiveObserver: (any NSObjectProtocol)?
    /// `compareHeld` was set by a B key-down (not by the Compare button).
    @ObservationIgnored private var compareHeldByKey = false
    @ObservationIgnored private var started = false

    // MARK: Init

    init(engine: any EngineDriving, defaults: UserDefaults, mode: Mode) {
        self.engine = engine
        self.defaults = defaults
        self.mode = mode
        self.presets = PresetStore(defaults: defaults, persist: mode == .live)
        self.meters = MeterHub()
        onboardingCompleted = defaults.bool(forKey: Keys.onboardingDone)
        turnOnAtLaunch = defaults.object(forKey: Keys.turnOnAtLaunch) as? Bool ?? true
        showMenuBarExtra = defaults.object(forKey: Keys.showMenuBar) as? Bool ?? true
        showInDock = defaults.object(forKey: Keys.showInDock) as? Bool ?? true
        outputProtection = defaults.object(forKey: Keys.protection) as? Bool ?? true
        pinnedOutputUID = defaults.string(forKey: Keys.pinnedOutput)
        graphScale = GraphScale(rawValue: defaults.string(forKey: Keys.graphScale) ?? "") ?? .auto
        loadState()

        meters.read = { [weak self] in self?.engine.meters() ?? ChainMeters() }
        meters.readUnderruns = { [weak self] in self?.engine.stats.underruns ?? 0 }
        meters.protectionOn = { [weak self] in self?.outputProtection ?? true }
    }

    /// Live launch: wire the engine, push the first parameters, restore routing
    /// and power. Never runs in snapshot / self-test mode.
    func start() {
        guard mode == .live, !started else { return }
        started = true
        engine.onOutputChanged = { [weak self] device in self?.outputDidChange(device) }
        sendParameters()
        if let pin = pinnedOutputUID { engine.selectOutput(uid: pin) }
        // The checkbox decides, as its label says. (`Keys.powered` is still
        // written by `setPowered` for older builds, but quitting never sets it
        // to false, so `turnOnAtLaunch || lastPowered` turned an unchecked box
        // into "On again at every launch".)
        engine.setPowered(turnOnAtLaunch)
        if !showInDock { NSApp.setActivationPolicy(.accessory) }
        installKeyMonitor()
    }

    /// `applicationWillTerminate`: flush state, hand macOS its output back.
    func shutdown() {
        saveTask?.cancel()
        saveNow()
        if mode == .live { engine.shutdown() }
    }

    // MARK: Engine parameters

    var chainParameters: ChainParameters {
        var d = dual
        d.target.sanitizeForDSP()
        d.fineTune.sanitizeForDSP()
        d.editingLayer = .fineTune     // UI state, not DSP state
        return ChainParameters(dual: d, bass: bass.sanitized(), outputProtection: outputProtection,
                               masterBypass: isComparing)
        // outputGainDB / outputMuted stay at their defaults: the volume fallback
        // is the engine's job (it owns systemVolume + hasHardwareVolume).
    }

    private func soundDidChange() {
        pushParameters()
        scheduleSave()
    }

    /// Throttled (≤ 60 Hz) with a guaranteed trailing update.
    func pushParameters() {
        switch gate.offer(now: clock()) {
        case .fire:
            sendParameters()
        case .schedule(let delay):
            trailingPush = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard let self else { return }
                self.gate.trailingFired(now: self.clock())
                self.sendParameters()
            }
        case .coalesce:
            break
        }
    }

    private func sendParameters() {
        let p = chainParameters
        guard p != lastPushed else { return }
        lastPushed = p
        engine.apply(p)
    }

    // MARK: Power / output

    func setPowered(_ on: Bool) {
        if !on { compareLatched = false; compareHeld = false }
        defaults.set(on, forKey: Keys.powered)
        engine.setPowered(on)
    }

    /// nil = Follow macOS.
    func selectOutput(uid: String?) {
        pinnedOutputUID = uid
        if let uid { defaults.set(uid, forKey: Keys.pinnedOutput) } else { defaults.removeObject(forKey: Keys.pinnedOutput) }
        engine.selectOutput(uid: uid)
    }

    /// A device bound to a Correction loads it when it becomes the output.
    /// If that Correction is already the selected one, edited or not, nothing
    /// happens: the engine reports nil → the same device at every launch, Off →
    /// On and Try Again, and reloading then threw away the user's (persisted,
    /// unsaved) edits — with no undo at launch, before the window exists.
    func outputDidChange(_ device: OutputDevice?) {
        guard let device, let key = presets.boundKey(for: device.uid),
              let entry = presets.entry(key, .correction) else { return }
        if correctionKey == key { return }
        perform("Load Correction") { applyCorrection(entry, keepEditingLayer: true) }
        showToast("Now playing through \(device.name) \u{2014} loaded \u{201C}\(entry.displayName)\u{201D}")
    }

    // MARK: Undo

    struct EditSnapshot: Equatable {
        var dual: DualEQState
        var bass: BassProcessorState
        var correctionKey: PresetKey?
        var tuningKey: PresetKey?
    }

    var editSnapshot: EditSnapshot {
        EditSnapshot(dual: dual, bass: bass, correctionKey: correctionKey, tuningKey: tuningKey)
    }

    private func restore(_ s: EditSnapshot) {
        dual = s.dual
        bass = s.bass
        correctionKey = s.correctionKey
        tuningKey = s.tuningKey
    }

    /// Start of a continuous gesture (drag, slider, scroll burst, pinch).
    func beginGesture() {
        if gestureStart == nil { gestureStart = editSnapshot }
    }

    /// End of the gesture: ONE undo step for the whole thing.
    func endGesture(_ actionName: String) {
        guard let start = gestureStart else { return }
        gestureStart = nil
        registerUndo(from: start, name: actionName)
    }

    var isInGesture: Bool { gestureStart != nil }

    /// A discrete, undoable change. Inside a running gesture it folds into it.
    func perform(_ actionName: String, _ change: () -> Void) {
        guard gestureStart == nil else { change(); return }
        let before = editSnapshot
        change()
        registerUndo(from: before, name: actionName)
    }

    private func registerUndo(from before: EditSnapshot, name: String) {
        guard before != editSnapshot, let um = undoManager else { return }
        um.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.swapTo(before, name: name) }
        }
        um.setActionName(name)
    }

    /// Undo and redo are the same operation: swap to the other snapshot and
    /// register the way back.
    private func swapTo(_ snapshot: EditSnapshot, name: String) {
        let current = editSnapshot
        restore(snapshot)
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.swapTo(current, name: name) }
        }
        undoManager?.setActionName(name)
    }

    // MARK: Toast

    func showToast(_ text: String) {
        let t = Toast(text: text)
        toast = t
        toastTask?.cancel()
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self, self.toast?.id == t.id else { return }
            self.toast = nil
        }
    }

    // MARK: Persistence

    private struct PersistedState: Codable {
        var target: StoredLayer?
        var fineTune: StoredLayer?
        var targetBypassed: Bool?
        var fineTuneBypassed: Bool?
        var editingLayer: EQLayer?
        var bass: BassProcessorState?
        var correctionKey: PresetKey?
        var tuningKey: PresetKey?

        @MainActor init(model: AppModel) {
            target = StoredLayer(model.dual.target)
            fineTune = StoredLayer(model.dual.fineTune)
            targetBypassed = model.dual.target.isBypassed
            fineTuneBypassed = model.dual.fineTune.isBypassed
            editingLayer = model.dual.editingLayer
            bass = model.bass
            correctionKey = model.correctionKey
            tuningKey = model.tuningKey
        }

        // Every field on its own: one unreadable field must not reset the rest.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            target = try? c.decodeIfPresent(StoredLayer.self, forKey: .target)
            fineTune = try? c.decodeIfPresent(StoredLayer.self, forKey: .fineTune)
            targetBypassed = try? c.decodeIfPresent(Bool.self, forKey: .targetBypassed)
            fineTuneBypassed = try? c.decodeIfPresent(Bool.self, forKey: .fineTuneBypassed)
            editingLayer = try? c.decodeIfPresent(EQLayer.self, forKey: .editingLayer)
            bass = try? c.decodeIfPresent(BassProcessorState.self, forKey: .bass)
            correctionKey = try? c.decodeIfPresent(PresetKey.self, forKey: .correctionKey)
            tuningKey = try? c.decodeIfPresent(PresetKey.self, forKey: .tuningKey)
        }
    }

    private func loadState() {
        guard let data = defaults.data(forKey: Keys.state),
              let s = try? JSONDecoder().decode(PersistedState.self, from: data) else { return }
        var d = DualEQState.flat
        if let t = s.target { d.target = t.layer }
        if let f = s.fineTune { d.fineTune = f.layer }
        d.target.isBypassed = s.targetBypassed ?? false
        d.fineTune.isBypassed = s.fineTuneBypassed ?? false
        d.editingLayer = s.editingLayer ?? .fineTune
        dual = d
        if let b = s.bass { bass = b.sanitized() }
        correctionKey = s.correctionKey
        tuningKey = s.tuningKey
    }

    private func scheduleSave() {
        guard mode == .live else { return }
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private func saveNow() {
        guard mode == .live, let data = try? JSONEncoder().encode(PersistedState(model: self)) else { return }
        defaults.set(data, forKey: Keys.state)
    }

    // MARK: Keyboard: hold B to compare

    /// Holding B (no modifiers, main window key, not typing) works like holding
    /// Compare (§6.4). A local monitor rather than `.onKeyPress`, because
    /// onKeyPress needs a focused SwiftUI view and the window often has none.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            // Local monitors run on the main thread; the event never leaves it.
            nonisolated(unsafe) let e = event
            let handled = MainActor.assumeIsolated { self?.handleKey(e) ?? false }
            return handled ? nil : event
        }
        // ⌘-Tab away while holding B: the key-up goes to another app.
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appDidResignActive() }
        }
    }

    /// True if the event was a B press/release that drove Compare (consumed).
    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.charactersIgnoringModifiers?.lowercased() == "b" else { return false }
        let window = event.window
        let eligible = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function]).isEmpty
            && window != nil && window === mainWindow
            && !(window?.firstResponder is NSText)
            && display.isProcessing
        return handleCompareKey(isDown: event.type == .keyDown, isRepeat: event.isARepeat, eligible: eligible)
    }

    /// Hold-B state machine. `eligible` = no modifiers, main window key, not
    /// typing, audio routed. A B key-up ALWAYS ends a hold that a B key-down
    /// started, whatever changed in between (⌘ pressed for ⌘B, focus moved into
    /// a text field, another window became key, the status flipped); otherwise
    /// Compare stuck on, with no Stop button (that shows only when latched).
    /// Returns true if the event was consumed.
    func handleCompareKey(isDown: Bool, isRepeat: Bool, eligible: Bool) -> Bool {
        if !isDown, compareHeldByKey {
            compareHeldByKey = false
            compareHeld = false
            return true                  // its key-down was ours too
        }
        guard eligible else { return false }
        if isDown {
            if !isRepeat { compareHeld = true; compareHeldByKey = true }
        } else {
            compareHeld = false
        }
        return true
    }

    /// The app lost focus: no key-up or mouse-up will reach us, so a hold ends.
    func appDidResignActive() {
        compareHeldByKey = false
        compareHeld = false
    }
}

// MARK: - Small value types

enum GraphScale: String, CaseIterable, Identifiable {
    case auto, twelve, twentyFour
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "Auto"
        case .twelve: return "\u{00B1}12 dB"
        case .twentyFour: return "\u{00B1}24 dB"
        }
    }
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let text: String
}

struct ImportPreview: Identifiable {
    let id = UUID()
    var result: Result<ImportedCorrection, ImportFailure>
    var name: String
    var bindToCurrentOutput = true

    init(result: Result<ImportedCorrection, ImportFailure>) {
        self.result = result
        if case .success(let c) = result { name = c.suggestedName } else { name = "" }
    }
}

struct NamePrompt: Identifiable {
    enum Purpose { case saveAs, rename }
    let id = UUID()
    let kind: PresetKind
    let purpose: Purpose
    var name: String
    /// Rename THIS preset (Settings). nil = the currently selected one.
    var key: PresetKey? = nil
}

struct PendingDelete: Identifiable {
    let id = UUID()
    let kind: PresetKind
    let entry: PresetEntry
}

enum OnboardingStep: Int, CaseIterable { case welcome, driver, installing, done }

enum InstallState: Equatable {
    case idle, installing, done, cancelled
    case failed(String)
}
