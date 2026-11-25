//
//  AppModel.swift
//  EQtargets (iOS)
//
//  The app's single source of truth, ported from the Mac model: both EQ layers,
//  Bass Style, output protection, compare, selection, presets and device
//  bindings. Views read it; the engine receives it as `ChainParameters`.
//
//  Engine hand-off rules (same as the Mac):
//  - `apply` goes through a 60 Hz throttle with a guaranteed trailing update, so
//    a 120 Hz drag never exceeds the contract and the resting value always lands.
//    Compare skips the throttle: bypass at press-down, no delay.
//  - Identical parameters are never re-sent (`editingLayer` is normalised out:
//    which layer you edit is UI state, not DSP state).
//  - `setPowered` is called once at launch, from the "Turn on when EQtargets
//    opens" setting.
//
//  Undo is snapshot-based, one step per gesture, committed field, preset load,
//  import or reset. It covers DualEQState, BassProcessorState and the selected
//  preset keys. Power, routing and settings are deliberately not undoable.
//
//  iOS differences:
//  - The model owns its UndoManager. The Undo and Redo buttons need observable
//    state, and a manager that groups by run-loop event would merge two quick
//    gestures into one step.
//  - Leaving the active scene ends everything a touch was holding open, because
//    a swipe into Control Center cancels the touch without any "ended" callback.
//

import Foundation
import Observation

@MainActor
@Observable
final class AppModel {

    enum Mode { case live, preview }

    enum Keys {
        static let state = "eqtargets.ios.state"
        static let protection = "eqtargets.ios.outputProtection"
        static let turnOnAtLaunch = "eqtargets.ios.turnOnAtLaunch"
        static let graphScale = "eqtargets.ios.graphScale"
    }

    // MARK: Dependencies

    @ObservationIgnored let engine: any EngineDriving
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let mode: Mode
    let presets: PresetStore
    let tuningBindings: TuningBindingStore
    let meters: MeterHub

    // MARK: Engine display

    /// Snapshots inject a state here; live mode leaves it nil.
    var displayOverride: EngineDisplay?
    /// Reads `engine.stats`, which changes up to 4 times a second while audio
    /// plays. Only leaf views that show those numbers may use it.
    var display: EngineDisplay { displayOverride ?? EngineDisplay(engine: engine) }

    var displayStatus: EngineStatus { displayOverride?.status ?? engine.status }
    var displayIsPowered: Bool { displayOverride?.isPowered ?? engine.isPowered }
    var displayIsProcessing: Bool { EngineDisplay.isProcessing(displayStatus) }

    /// Read without `display`, so a view showing the device name doesn't also
    /// re-render on every stats update.
    var currentOutput: OutputDevice? {
        if let o = displayOverride { return o.currentOutput }
        return engine.currentOutput
    }

    /// The running rate, copied here only when it changes, so the graph can use
    /// the real rate without depending on the 4 Hz `stats`.
    private(set) var runningSampleRate: Double = 0

    /// Sample rate for every curve calculation (§7.1).
    var graphSampleRate: Double {
        if let o = displayOverride { return o.graphSampleRate }
        return displayIsProcessing ? ResponseMath.displaySampleRate(runningSampleRate)
                                   : ResponseMath.fallbackSampleRate
    }

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

    var compareLatched = false {
        didSet { if compareLatched != oldValue { refreshOutputBypass(); sendParameters() } }
    }
    var compareHeld = false {
        didSet { if compareHeld != oldValue { refreshOutputBypass(); sendParameters() } }
    }
    /// Derived and stored, so views showing it don't depend on `dual`, which
    /// changes on every frame of a drag.
    private(set) var outputBypass = OutputBypass.none
    var isComparing: Bool { compareLatched || compareHeld }

    // MARK: Selection / UI state

    /// Last band selected per layer; the editor always shows it (never empty).
    var lastBand: [EQLayer: Int] = [.target: 0, .fineTune: 0]
    /// Whether that band is highlighted on the graph (a tap on the empty plot clears it).
    var bandHighlighted = false
    var isDraggingGraph = false
    /// Y scale held still while a graph drag is in progress (re-scales on release).
    var graphFrozenYMax: Double?
    var graphScale: GraphScale = .auto { didSet { defaults.set(graphScale.rawValue, forKey: Keys.graphScale) } }
    var showCorrectionCurve = true
    var showTuningCurve = true

    var toast: Toast?
    var importPreview: ImportPreview? {
        didSet { if importPreview == nil, oldValue != nil { importGeneration &+= 1 } }
    }
    @ObservationIgnored var importGeneration = 0
    /// A Correction bound to this output that wasn't loaded, because that would
    /// have replaced unsaved work. Offered on the Output card until resolved.
    var skippedCorrection: SkippedCorrection?
    var skippedTuning: SkippedCorrection?
    @ObservationIgnored private var outputAwaitingGesture: OutputDevice?
    var showFileImporter = false
    var showSettings = false
    var namePrompt: NamePrompt?
    var pendingDelete: PendingDelete?

    // MARK: Settings

    var turnOnAtLaunch: Bool { didSet { defaults.set(turnOnAtLaunch, forKey: Keys.turnOnAtLaunch) } }

    // MARK: Undo

    @ObservationIgnored let undoManager: UndoManager = {
        let manager = UndoManager()
        manager.groupsByEvent = false
        manager.levelsOfUndo = 200
        return manager
    }()
    private(set) var canUndo = false
    private(set) var canRedo = false
    private(set) var undoActionName = ""
    private(set) var redoActionName = ""

    // MARK: Plumbing

    @ObservationIgnored var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    @ObservationIgnored private var gate = ThrottleGate(interval: 1.0 / 60)
    @ObservationIgnored private var trailingPush: Task<Void, Never>?
    @ObservationIgnored private(set) var lastPushed: ChainParameters?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var gestureStart: EditSnapshot?
    @ObservationIgnored private var gestureOwner = ""
    @ObservationIgnored private var gestureName = ""
    @ObservationIgnored private var fieldFlush: (owner: UUID, action: () -> Void)?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var sceneHasReported = false
    @ObservationIgnored private var sceneIsActive = false

    /// How the Control Center tiles get updated. Set at launch.
    @ObservationIgnored var controlOutput: EQControlOutput?
    @ObservationIgnored var controlLeaseRenewSeconds = EQControlState.leaseRenewSeconds
    /// Real time: `clock` stops while the phone sleeps.
    @ObservationIgnored var wallClock: () -> Date = { Date() }
    @ObservationIgnored private var lastControlState: EQControlState?
    @ObservationIgnored private var controlLeaseTask: Task<Void, Never>?
    @ObservationIgnored private var controlLeaseEnd: Date?
    /// A tile's On or Off, which a window opening soon after has to respect.
    @ObservationIgnored private var controlPowerChoice: (on: Bool, at: Date)?
    private static let controlChoiceSeconds: TimeInterval = 300

    // MARK: Init

    init(engine: any EngineDriving, defaults: UserDefaults, mode: Mode) {
        self.engine = engine
        self.defaults = defaults
        self.mode = mode
        self.presets = PresetStore(defaults: defaults, persist: mode == .live)
        self.tuningBindings = TuningBindingStore(defaults: defaults, persist: mode == .live)
        self.meters = MeterHub()
        turnOnAtLaunch = defaults.object(forKey: Keys.turnOnAtLaunch) as? Bool ?? true
        outputProtection = defaults.object(forKey: Keys.protection) as? Bool ?? true
        graphScale = GraphScale(rawValue: defaults.string(forKey: Keys.graphScale) ?? "") ?? .auto
        loadState()
        refreshOutputBypass()

        meters.read = { [weak self] in self?.engine.meters() ?? ChainMeters() }
        meters.readUnderruns = { [weak self] in self?.engine.stats.underruns ?? 0 }
        meters.protectionOn = { [weak self] in self?.outputProtection ?? true }
        trackRunningSampleRate()
        trackEngineStatus()
    }

    /// Live launch: wire the engine, push the first parameters, restore power.
    /// Never runs in preview mode.
    func start() {
        guard mode == .live, !started else { return }
        started = true
        engine.onOutputChanged = { [weak self] device in self?.outputDidChange(device) }
        sendParameters()
        engine.setPowered(recentControlPower ?? turnOnAtLaunch)
        // The engine read the route in its init, before this callback existed,
        // so a device bound to a Correction would otherwise not load at launch.
        outputDidChange(engine.currentOutput)
        publishControlState()
    }

    /// Re-arms itself after every change. `stats` is reassigned often, but the
    /// observable property only moves when the rate really does.
    private func trackRunningSampleRate() {
        let rate = withObservationTracking {
            engine.stats.sampleRate
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.trackRunningSampleRate() }
        }
        if rate != runningSampleRate { runningSampleRate = rate }
    }

    // MARK: Scene

    /// `scenePhase` moved. Control Center, a call or the app switcher can take
    /// the touch away mid-gesture, and no "ended" callback follows.
    func sceneDidChange(isActive: Bool, isBackground: Bool) {
        sceneHasReported = true
        sceneIsActive = isActive
        // Control Center over the app is only inactive, and EQtargets can be picked
        // from it: the engine has to keep looking for the connection.
        engine.setForeground(!isBackground)
        guard !isActive else { return }
        compareHeld = false
        finishOpenGesture()
        if isBackground { flushState() }
    }

    /// Closes a gesture whose end will never be reported. Without this, every
    /// later edit would fold into it and undo would stop registering.
    func finishOpenGesture(name: String = "Change EQ") {
        closeGesture(name: name)
        retryOutputAfterGesture()
        isDraggingGraph = false
        graphFrozenYMax = nil
    }

    /// iOS can end a suspended app without warning, so state is written on the
    /// way to the background instead of waiting for the debounce.
    func flushState() {
        saveTask?.cancel()
        saveNow()
    }

    // MARK: Engine parameters

    var chainParameters: ChainParameters {
        var d = dual
        d.target.sanitizeForDSP()
        d.fineTune.sanitizeForDSP()
        d.editingLayer = .fineTune     // UI state, not DSP state
        return ChainParameters(dual: d, bass: bass.sanitized(), outputProtection: outputProtection,
                               masterBypass: isComparing)
    }

    /// A layer that changes nothing: off, or flat across the bands that are on.
    private func isNeutral(_ l: EQLayerState) -> Bool {
        l.isBypassed || (abs(l.preamp) < 0.001 && l.bands.allSatisfy { !$0.isEnabled || abs($0.gain) < 0.001 })
    }

    private func refreshOutputBypass() {
        let next: OutputBypass
        if isComparing {
            next = .comparing
        } else if isNeutral(dual.target), isNeutral(dual.fineTune), bass.style == .none {
            next = .allStagesOff
        } else {
            next = .none
        }
        if next != outputBypass { outputBypass = next }
    }

    private func soundDidChange() {
        refreshOutputBypass()
        pushParameters()
        scheduleSave()
        publishControlState()
    }

    /// Throttled (at most 60 Hz) with a guaranteed trailing update.
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
        engine.setPowered(on)
        publishControlState()
    }

    /// "Try Again" after an error.
    func retryEngine() {
        compareHeld = false
        engine.retry()
    }

    // MARK: Control Center

    /// On means audio is really being processed.
    var controlState: EQControlState {
        EQControlState(isOn: engine.isPowered && !engineHasFailed,
                       bassName: bass.style.compactTitle, bassSymbol: bass.style.systemImage)
    }

    /// Nothing reaches the output in these states.
    private var engineHasFailed: Bool {
        switch engine.status {
        case .error, .feedbackGuard: return true
        default: return false
        }
    }

    private var recentControlPower: Bool? {
        guard let choice = controlPowerChoice,
              wallClock().timeIntervalSince(choice.at) < Self.controlChoiceSeconds else { return nil }
        return choice.on
    }

    /// Only when a tile would look different: a drag changes the EQ on every frame.
    /// A save that fails is tried again on the next report.
    private func publishControlState() {
        guard let output = controlOutput else { return }
        let state = controlState
        guard state != lastControlState, saveLeased(state, to: output) else { return }
        lastControlState = state
        output.redraw()
        renewControlLease(while: state.isOn)
    }

    private func saveLeased(_ state: EQControlState, to output: EQControlOutput) -> Bool {
        var s = state
        s.onUntil = s.isOn ? wallClock().addingTimeInterval(EQControlState.leaseSeconds) : nil
        guard output.save(s) else { return false }
        controlLeaseEnd = s.onUntil
        return true
    }

    /// If the app is killed the renewals stop, and the tile stops claiming On.
    private func renewControlLease(while isOn: Bool) {
        controlLeaseTask?.cancel()
        controlLeaseTask = nil
        guard isOn else { return }
        controlLeaseTask = Task { @MainActor [weak self] in
            while let seconds = self?.controlLeaseRenewSeconds {
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled, let self, let output = self.controlOutput else { return }
                let state = self.controlState
                guard state.isOn else {     // a report that failed to save
                    self.publishControlState()
                    return
                }
                // A tile that already read as Off has to be told it's On again.
                let hadExpired = (self.controlLeaseEnd ?? .distantPast) <= self.wallClock()
                if self.saveLeased(state, to: output), hadExpired { output.redraw() }
            }
        }
    }

    /// The tiles must not keep saying On after the audio has failed.
    private func trackEngineStatus() {
        _ = withObservationTracking {
            engine.status
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.publishControlState()
                self?.trackEngineStatus()
            }
        }
    }

    /// The EQtargets tile. iOS may have launched the app just to run it, with no
    /// window, so the start a first frame would normally trigger happens here.
    func setPoweredFromControl(_ on: Bool, mayOpenApp: Bool) throws {
        controlPowerChoice = (on, wallClock())
        noteControlTap()
        if !started {
            if on { start() } else { publishControlState() }
        } else if on, engine.isPowered {
            if engineHasFailed { retryEngine() }
        } else {
            setPowered(on)
        }
        // iOS can refuse this audio session in the background. Don't leave a tile
        // saying On over silence: the intent opens the app and tries again.
        guard on, mayOpenApp, !sceneIsActive, engineHasFailed else { return }
        setPowered(false)
        throw EQControlError.audioNeedsForeground
    }

    /// The Bass tile: Off, Punch, Rumble, Clean, then Off again. It never starts
    /// the audio, and it saves at once because iOS may end the app straight after.
    func nextBassStyleFromControl() {
        noteControlTap()
        let styles = BassStyle.allCases
        let index = styles.firstIndex(of: bass.style) ?? 0
        selectBassStyle(styles[(index + 1) % styles.count], keepCustomCutoff: true)
        flushState()
    }

    private func noteControlTap() {
        guard !sceneIsActive else { return }
        if !sceneHasReported { engine.setForeground(false) }
        engine.watchForPeer()
    }

    /// A device bound to a Correction or a Tuning loads it when it becomes the
    /// output, each layer on its own. If that preset is already selected, edited
    /// or not, nothing happens to that layer: the engine reports the same device
    /// at launch and after Off/On, and reloading then would throw away the
    /// user's unsaved edits. Both loads are one undo step.
    func outputDidChange(_ device: OutputDevice?) {
        outputAwaitingGesture = nil
        skippedCorrection = nil
        skippedTuning = nil
        guard let device else { return }
        let correction = boundEntry(presets.boundKey(for: device.uid), .correction)
        let tuning = boundEntry(tuningBindings.boundKey(for: device.uid), .tuning)
        guard correction != nil || tuning != nil else { return }
        // Never swap a layer under a finger: decided when the gesture ends.
        if isInGesture {
            outputAwaitingGesture = device
            return
        }
        // A flapping route must never discard unsaved work. The card offers it.
        var loadCorrection: PresetEntry?
        var loadTuning: PresetEntry?
        if let entry = correction {
            if currentEntry(.correction) == nil || isEdited(.correction) {
                skippedCorrection = SkippedCorrection(key: entry.key, name: entry.displayName,
                                                      deviceUID: device.uid, deviceName: device.name)
            } else {
                loadCorrection = entry
            }
        }
        if let entry = tuning {
            if currentEntry(.tuning) == nil || isEdited(.tuning) {
                skippedTuning = SkippedCorrection(key: entry.key, name: entry.displayName,
                                                  deviceUID: device.uid, deviceName: device.name)
            } else {
                loadTuning = entry
            }
        }
        let loaded = [loadCorrection, loadTuning].compactMap { $0 }
        guard !loaded.isEmpty else { return }
        let step = loaded.count == 2 ? "Load Presets" : (loadCorrection != nil ? "Load Correction" : "Load Tuning")
        perform(step) {
            if let loadCorrection { applyCorrection(loadCorrection, keepEditingLayer: true) }
            if let loadTuning { applyTuning(loadTuning) }
        }
        let names = loaded.map { "\u{201C}\($0.displayName)\u{201D}" }.joined(separator: " and ")
        showToast("Now playing through \(device.name) \u{2014} loaded \(names)")
    }

    /// The preset a binding points at, unless it is the one already selected.
    private func boundEntry(_ key: PresetKey?, _ kind: PresetKind) -> PresetEntry? {
        guard let key, key != presetKey(kind) else { return nil }
        return presets.entry(key, kind)
    }

    /// The offer, for as long as it is still true: this output is bound to that
    /// Correction, and a different one is playing.
    var correctionOffer: SkippedCorrection? {
        guard let skipped = skippedCorrection, skipped.key != correctionKey,
              presets.boundKey(for: skipped.deviceUID) == skipped.key,
              let entry = presets.entry(skipped.key, .correction) else { return nil }
        return SkippedCorrection(key: skipped.key, name: entry.displayName,
                                 deviceUID: skipped.deviceUID, deviceName: skipped.deviceName)
    }

    /// The same offer for a Tuning.
    var tuningOffer: SkippedCorrection? {
        guard let skipped = skippedTuning, skipped.key != tuningKey,
              tuningBindings.boundKey(for: skipped.deviceUID) == skipped.key,
              let entry = presets.entry(skipped.key, .tuning) else { return nil }
        return SkippedCorrection(key: skipped.key, name: entry.displayName,
                                 deviceUID: skipped.deviceUID, deviceName: skipped.deviceName)
    }

    func useSkippedTuning() {
        guard let skipped = tuningOffer, let entry = presets.entry(skipped.key, .tuning) else {
            skippedTuning = nil
            return
        }
        perform("Load Tuning") { applyTuning(entry) }
        skippedTuning = nil
    }

    /// The Output card's "Use It": loads the skipped Correction as one undo step.
    func useSkippedCorrection() {
        guard let skipped = correctionOffer, let entry = presets.entry(skipped.key, .correction) else {
            skippedCorrection = nil
            return
        }
        perform("Load Correction") { applyCorrection(entry, keepEditingLayer: true) }
        skippedCorrection = nil
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

    /// Start of a continuous gesture (drag, slider, pinch). Two fingers can overlap:
    /// a new owner closes the previous step, so each edit keeps its own undo.
    func beginGesture(owner: String = "", name: String = "Change EQ") {
        if gestureStart != nil {
            if owner == gestureOwner { return }
            closeGesture(name: gestureName)
        }
        // A half-typed value is its own undo step, not part of this gesture.
        fieldFlush?.action()
        gestureStart = editSnapshot
        gestureOwner = owner
        gestureName = name
    }

    /// A control still held after another finger's gesture closed its step. Called
    /// only on real movement, so a control whose end was never reported can't pin it.
    func resumeGesture(owner: String, name: String) {
        guard !isInGesture else { return }
        gestureStart = editSnapshot
        gestureOwner = owner
        gestureName = name
    }

    /// Opens a drag or pinch on the graph. A half-typed value lands first, so the
    /// state returned is the one the gesture has to start from.
    func openGraphGesture(band: Int?, owner: String = "",
                          name: String = "Change EQ") -> (layer: EQLayer, state: EQLayerState) {
        if let band { selectBand(band) }
        beginGesture(owner: owner, name: name)
        let layer = dual.editingLayer
        return (layer, layerState(layer))
    }

    /// The focused number field's commit, so a gesture can land it first.
    func setFieldFlush(owner: UUID, _ action: @escaping () -> Void) {
        fieldFlush = (owner, action)
    }

    func clearFieldFlush(owner: UUID) {
        if fieldFlush?.owner == owner { fieldFlush = nil }
    }

    /// End of the gesture: ONE undo step for the whole thing. Only its owner can
    /// end it: a slider torn down by a band change must not close a later drag.
    func endGesture(_ actionName: String, owner: String = "") {
        guard gestureStart != nil, owner == gestureOwner else { return }
        closeGesture(name: actionName)
        retryOutputAfterGesture()
    }

    private func closeGesture(name: String) {
        guard let start = gestureStart else { return }
        gestureStart = nil
        registerUndo(from: start, name: name)
    }

    /// A route change that waited for the finger to lift.
    private func retryOutputAfterGesture() {
        if let device = outputAwaitingGesture { outputDidChange(device) }
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
        guard before != editSnapshot else { return }
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.swapTo(before, name: name) }
        }
        undoManager.setActionName(name)
        undoManager.endUndoGrouping()
        refreshUndoState()
    }

    /// Undo and redo are the same operation: swap to the other snapshot and
    /// register the way back.
    private func swapTo(_ snapshot: EditSnapshot, name: String) {
        let current = editSnapshot
        restore(snapshot)
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.swapTo(current, name: name) }
        }
        undoManager.setActionName(name)
    }

    func undo() {
        guard !isInGesture, undoManager.canUndo else { return }
        undoManager.undo()
        refreshUndoState()
    }

    func redo() {
        guard !isInGesture, undoManager.canRedo else { return }
        undoManager.redo()
        refreshUndoState()
    }

    private func refreshUndoState() {
        canUndo = undoManager.canUndo
        canRedo = undoManager.canRedo
        undoActionName = undoManager.undoActionName
        redoActionName = undoManager.redoActionName
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

/// A bound preset that was not loaded because the layer held unsaved edits.
/// Used for Tunings too.
struct SkippedCorrection: Equatable {
    let key: PresetKey
    let name: String
    let deviceUID: String
    let deviceName: String
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
