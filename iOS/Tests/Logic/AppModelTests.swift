//
//  AppModelTests.swift
//  EQtargets (iOS)
//
//  The Mac model's behaviours that can silently break in a port, and the rules
//  that exist only on iOS. Everything runs against `StandInEngine`, so no test
//  opens an audio session.
//

import XCTest

@MainActor
final class AppModelTests: XCTestCase {

    // MARK: Helpers

    private let airpods = OutputDevice(uid: "airpods-uid", name: "AirPods Max", transport: .bluetooth)

    private func makeDefaults() -> UserDefaults {
        let name = "eqtargets.tests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    private func makeModel(defaults: UserDefaults? = nil) -> (AppModel, StandInEngine) {
        let engine = StandInEngine()
        return (AppModel(engine: engine, defaults: defaults ?? makeDefaults(), mode: .live), engine)
    }

    private func layer(gain: Double) -> EQLayerState {
        var l = EQLayerState.flat
        l.bands[0].gain = gain
        return l
    }

    /// The trailing push waits on a real `Task.sleep`, so poll with a timeout.
    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return true
    }

    // MARK: Throttle

    func test_throttle_firstEditGoesNow_burstCoalesces_lastValueLands() async {
        let (model, engine) = makeModel()
        var now = 100.0
        model.clock = { now }

        model.updateBand(0) { $0.gain = 1 }
        XCTAssertEqual(engine.applied.count, 1, "the first change must not wait")

        now += 0.002
        model.updateBand(0) { $0.gain = 2 }
        now += 0.002
        model.updateBand(0) { $0.gain = 3 }
        XCTAssertEqual(engine.applied.count, 1, "edits inside the 60 Hz window must not be sent")

        let landed = await waitUntil { engine.applied.count >= 2 }
        XCTAssertTrue(landed, "the trailing update never arrived")
        XCTAssertEqual(engine.applied.count, 2, "the burst must collapse into one trailing send")
        XCTAssertEqual(engine.applied.last?.dual.fineTune.bands[0].gain, 3, "the resting value must land")
    }

    func test_throttle_anEditAfterTheWindowIsSentImmediately() {
        let (model, engine) = makeModel()
        var now = 100.0
        model.clock = { now }
        model.updateBand(0) { $0.gain = 1 }
        now += 1.0 / 30
        model.updateBand(0) { $0.gain = 2 }
        XCTAssertEqual(engine.applied.count, 2)
        XCTAssertEqual(engine.applied.last?.dual.fineTune.bands[0].gain, 2)
    }

    func test_compare_skipsTheThrottle() {
        let (model, engine) = makeModel()
        var now = 100.0
        model.clock = { now }
        model.updateBand(0) { $0.gain = 1 }
        now += 0.001
        model.compareHeld = true
        XCTAssertEqual(engine.applied.count, 2, "bypass must engage at press-down")
        XCTAssertEqual(engine.applied.last?.masterBypass, true)
    }

    // MARK: No duplicate apply

    func test_identicalParameters_areNotSentAgain() {
        let (model, engine) = makeModel()
        var now = 100.0
        model.clock = { now }
        model.updateBand(0) { $0.gain = 2 }
        XCTAssertEqual(engine.applied.count, 1)

        now += 1
        model.pushParameters()
        XCTAssertEqual(engine.applied.count, 1, "the same parameters were applied twice")
    }

    func test_switchingTheEditedLayer_isNotASoundChange() {
        let (model, engine) = makeModel()
        var now = 100.0
        model.clock = { now }
        model.updateBand(0) { $0.gain = 2 }
        now += 1
        model.selectLayer(.target)
        XCTAssertEqual(model.dual.editingLayer, .target)
        XCTAssertEqual(engine.applied.count, 1, "which layer you edit is UI state, not DSP state")
    }

    // MARK: Undo

    func test_undo_aWholeDragIsOneStep() {
        let (model, _) = makeModel()
        model.beginGesture()
        for gain in stride(from: 0.5, through: 6, by: 0.5) {
            model.updateBand(2) { $0.gain = gain }
        }
        model.endGesture("Move Band 3")

        XCTAssertTrue(model.canUndo)
        XCTAssertEqual(model.undoActionName, "Move Band 3")
        model.undo()
        XCTAssertEqual(model.band(2).gain, 0, "one undo must take back the whole drag")
        XCTAssertFalse(model.canUndo)
        XCTAssertTrue(model.canRedo)

        model.redo()
        XCTAssertEqual(model.band(2).gain, 6)
        XCTAssertTrue(model.canUndo)
        XCTAssertFalse(model.canRedo)
    }

    func test_undo_twoGesturesInOneRunLoopTurnStayTwoSteps() {
        let (model, _) = makeModel()
        model.beginGesture()
        model.updateBand(0) { $0.gain = 1 }
        model.endGesture("Move Band 1")
        model.beginGesture()
        model.updateBand(1) { $0.gain = 2 }
        model.endGesture("Move Band 2")

        model.undo()
        XCTAssertEqual(model.band(1).gain, 0)
        XCTAssertEqual(model.band(0).gain, 1, "the first gesture was merged into the second")
        model.undo()
        XCTAssertEqual(model.band(0).gain, 0)
    }

    func test_undo_aGestureThatChangedNothingLeavesNoStep() {
        let (model, _) = makeModel()
        model.beginGesture()
        model.endGesture("Move Band 1")
        XCTAssertFalse(model.canUndo)
    }

    func test_undo_isIgnoredDuringAGesture() {
        let (model, _) = makeModel()
        model.perform("Reset Band") { model.updateBand(0) { $0.gain = 4 } }
        model.beginGesture()
        model.updateBand(0) { $0.gain = 5 }
        model.undo()
        XCTAssertEqual(model.band(0).gain, 5, "undo must not pull state out from under a finger")
        model.endGesture("Move Band 1")
    }

    // MARK: Persistence

    func test_persistence_roundTripRestoresTheWholeSound() {
        let defaults = makeDefaults()
        let (first, _) = makeModel(defaults: defaults)
        first.selectLayer(.target)
        first.updateBand(3) {
            $0.frequency = 777
            $0.gain = -4.5
            $0.q = 3.2
            $0.filterType = .highShelf
            $0.isEnabled = false
        }
        first.setPreamp(-2.5, layer: .target)
        first.setPreamp(1.5, layer: .fineTune)
        first.setLayerOn(.fineTune, false)
        first.selectBassStyle(.sustainRumble)
        first.updateBass { $0.strength = 0.8; $0.postGain = -3; $0.rumbleSoften = 0.25 }
        let saved = first.presets.add(.correction, name: "HD 600", layer: first.dual.target)
        first.correctionKey = saved.key
        first.tuningKey = nil
        first.outputProtection = false
        first.turnOnAtLaunch = false
        first.graphScale = .twentyFour
        first.flushState()

        let (second, _) = makeModel(defaults: defaults)
        XCTAssertEqual(second.dual, first.dual)
        XCTAssertEqual(second.bass, first.bass)
        XCTAssertEqual(second.correctionKey, saved.key)
        XCTAssertNil(second.tuningKey)
        XCTAssertFalse(second.outputProtection)
        XCTAssertFalse(second.turnOnAtLaunch)
        XCTAssertEqual(second.graphScale, .twentyFour)
        XCTAssertEqual(second.presets.user(.correction).map(\.name), ["HD 600"])
    }

    func test_persistence_usesIOSKeys() {
        let defaults = makeDefaults()
        let (model, _) = makeModel(defaults: defaults)
        model.updateBand(0) { $0.gain = 3 }
        model.outputProtection = false
        model.flushState()
        XCTAssertNotNil(defaults.data(forKey: "eqtargets.ios.state"))
        XCTAssertNotNil(defaults.object(forKey: "eqtargets.ios.outputProtection"))
        XCTAssertNil(defaults.data(forKey: "eqtargets.mac.state"))
    }

    func test_goingToTheBackground_savesWithoutWaitingForTheDebounce() {
        let defaults = makeDefaults()
        let (model, _) = makeModel(defaults: defaults)
        model.updateBand(0) { $0.gain = 3 }
        XCTAssertNil(defaults.data(forKey: AppModel.Keys.state), "precondition: the debounce hasn't fired")

        model.sceneDidChange(isActive: false, isBackground: true)

        let (restored, _) = makeModel(defaults: defaults)
        XCTAssertEqual(restored.band(0).gain, 3, "iOS can end a suspended app without warning")
    }

    // MARK: Device-bound corrections

    func test_boundDevice_reportedAgain_keepsUnsavedEdits() {
        let (model, _) = makeModel()
        let saved = model.presets.add(.correction, name: "HD 600", layer: layer(gain: 3))
        model.loadPreset(saved, .correction)
        model.presets.bind(deviceUID: airpods.uid, deviceName: airpods.name, to: saved.key)
        model.selectLayer(.target)
        model.updateBand(0) { $0.gain = 9 }

        model.outputDidChange(airpods)

        XCTAssertEqual(model.dual.target.bands[0].gain, 9, "reloading threw away the user's edits")
        XCTAssertTrue(model.isEdited(.correction))
    }

    func test_boundDevice_atLaunch_keepsPersistedEdits() {
        let defaults = makeDefaults()
        let (first, _) = makeModel(defaults: defaults)
        let saved = first.presets.add(.correction, name: "HD 600", layer: layer(gain: 3))
        first.loadPreset(saved, .correction)
        first.presets.bind(deviceUID: airpods.uid, deviceName: airpods.name, to: saved.key)
        first.selectLayer(.target)
        first.updateBand(0) { $0.gain = 9 }
        first.flushState()

        let engine = StandInEngine()
        engine.currentOutput = airpods
        let second = AppModel(engine: engine, defaults: defaults, mode: .live)
        second.start()

        XCTAssertEqual(second.dual.target.bands[0].gain, 9, "a relaunch must not reload over persisted edits")
    }

    func test_boundDevice_withAnotherCorrectionSelected_loadsItAsOneUndoStep() {
        let (model, _) = makeModel()
        let saved = model.presets.add(.correction, name: "HD 600", layer: layer(gain: 3))
        model.presets.bind(deviceUID: airpods.uid, deviceName: airpods.name, to: saved.key)
        model.updateBand(4) { $0.gain = 2 }     // Your tuning must survive this

        model.outputDidChange(airpods)

        XCTAssertEqual(model.correctionKey, saved.key)
        XCTAssertEqual(model.dual.target.bands[0].gain, 3)
        XCTAssertEqual(model.dual.fineTune.bands[4].gain, 2)
        XCTAssertNotNil(model.toast)
        model.undo()
        XCTAssertEqual(model.correctionKey, PresetStore.flatCorrectionKey)
        XCTAssertEqual(model.dual.target.bands[0].gain, 0)
    }

    func test_unboundDevice_changesNothing() {
        let (model, _) = makeModel()
        let before = model.editSnapshot
        model.outputDidChange(airpods)
        XCTAssertEqual(model.editSnapshot, before)
        XCTAssertNil(model.toast)
    }

    func test_start_loadsTheCorrectionBoundToTheCurrentOutput() {
        let defaults = makeDefaults()
        let (first, _) = makeModel(defaults: defaults)
        let saved = first.presets.add(.correction, name: "HD 600", layer: layer(gain: 3))
        first.presets.bind(deviceUID: airpods.uid, deviceName: airpods.name, to: saved.key)
        first.flushState()

        // LinkEngine reads the route in its init, before the callback is set.
        let engine = StandInEngine()
        engine.currentOutput = airpods
        let second = AppModel(engine: engine, defaults: defaults, mode: .live)
        second.start()

        XCTAssertEqual(second.correctionKey, saved.key)
    }

    // MARK: Power

    func test_start_powersOnByDefault() {
        let (model, engine) = makeModel()
        model.start()
        XCTAssertEqual(engine.poweredCalls, [true])
    }

    func test_start_respectsTheTurnOnSetting() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: AppModel.Keys.turnOnAtLaunch)
        let (model, engine) = makeModel(defaults: defaults)
        model.start()
        XCTAssertEqual(engine.poweredCalls, [false])
    }

    func test_start_runsOnce() {
        let (model, engine) = makeModel()
        model.start()
        model.start()
        XCTAssertEqual(engine.poweredCalls.count, 1)
    }

    func test_start_sendsTheRestoredSoundBeforePoweringOn() {
        let defaults = makeDefaults()
        let (first, _) = makeModel(defaults: defaults)
        first.updateBand(0) { $0.gain = 5 }
        first.flushState()

        let (second, engine) = makeModel(defaults: defaults)
        second.start()
        XCTAssertEqual(engine.applied.last?.dual.fineTune.bands[0].gain, 5)
    }

    func test_tryAgain_retriesWithoutTouchingPower() {
        let (model, engine) = makeModel()
        engine.setPowered(true)
        model.retryEngine()
        XCTAssertEqual(engine.retryCalls, 1)
        XCTAssertEqual(engine.poweredCalls, [true], "Off then On would drop into pass-through")
    }

    // MARK: Review regressions

    func test_routeChange_neverDiscardsAnEditedCorrection_andOffersTheBoundOne() {
        let (model, _) = makeModel()
        let a = model.presets.add(.correction, name: "A", layer: layer(gain: 3))
        let b = model.presets.add(.correction, name: "B", layer: layer(gain: -3))
        model.presets.bind(deviceUID: airpods.uid, deviceName: airpods.name, to: b.key)
        model.loadPreset(a, .correction)
        model.selectLayer(.target)
        model.updateBand(0) { $0.gain = 9 }

        model.outputDidChange(airpods)

        XCTAssertEqual(model.correctionKey, a.key)
        XCTAssertEqual(model.dual.target.bands[0].gain, 9)
        XCTAssertEqual(model.skippedCorrection?.key, b.key, "the offer must outlast a toast")

        model.useSkippedCorrection()
        XCTAssertEqual(model.correctionKey, b.key)
        XCTAssertNil(model.skippedCorrection)
        model.undo()
        XCTAssertEqual(model.dual.target.bands[0].gain, 9, "one undo brings the edits back")
    }

    func test_routeChange_duringAGesture_waitsForTheFinger() {
        let (model, _) = makeModel()
        let b = model.presets.add(.correction, name: "B", layer: layer(gain: -3))
        model.presets.bind(deviceUID: airpods.uid, deviceName: airpods.name, to: b.key)
        model.beginGesture()
        model.outputDidChange(airpods)
        XCTAssertEqual(model.correctionKey, PresetStore.flatCorrectionKey, "not under the finger")
        XCTAssertNil(model.skippedCorrection)
        model.endGesture("Move Band")
        XCTAssertEqual(model.correctionKey, b.key, "retried when the finger lifts")
    }

    func test_routeChange_toAnUnboundOutput_clearsTheOffer() {
        let (model, _) = makeModel()
        let a = model.presets.add(.correction, name: "A", layer: layer(gain: 3))
        let b = model.presets.add(.correction, name: "B", layer: layer(gain: -3))
        model.presets.bind(deviceUID: airpods.uid, deviceName: airpods.name, to: b.key)
        model.loadPreset(a, .correction)
        model.selectLayer(.target)
        model.updateBand(0) { $0.gain = 9 }
        model.outputDidChange(airpods)
        XCTAssertNotNil(model.skippedCorrection)
        model.outputDidChange(OutputDevice(uid: "speaker", name: "Speaker", transport: .builtIn))
        XCTAssertNil(model.skippedCorrection)
    }

    func test_choosingTheBoundCorrectionFromTheMenu_clearsTheOffer() {
        let (model, _) = makeModel()
        let a = model.presets.add(.correction, name: "A", layer: layer(gain: 3))
        let b = model.presets.add(.correction, name: "B", layer: layer(gain: -3))
        model.presets.bind(deviceUID: airpods.uid, deviceName: airpods.name, to: b.key)
        model.loadPreset(a, .correction)
        model.selectLayer(.target)
        model.updateBand(0) { $0.gain = 9 }
        model.outputDidChange(airpods)
        model.loadPreset(b, .correction)
        XCTAssertNil(model.skippedCorrection)
    }

    func test_numberEntry_commaIsAlwaysADecimal_forQAndGain() {
        XCTAssertEqual(NumberEntry.parseQ("0,707"), 0.707)
        XCTAssertEqual(NumberEntry.parseQ("1,414"), 1.414)
        XCTAssertEqual(NumberEntry.parseGain("-1,250"), -1.25)
        XCTAssertEqual(NumberEntry.parseGain("+3,5 dB"), 3.5)
        XCTAssertNil(NumberEntry.parseQ("1,5,3"))
        XCTAssertEqual(EQFormat.parseFrequency("1,000"), 1_000, "hertz keeps its thousands separator")
    }

    func test_import_longWhitespaceRun_cannotHangTheParser() {
        let hostile = "Filter" + String(repeating: " ", count: 30_000) + "x"
        let started = Date()
        _ = ImportFileReader.parse(text: hostile, sourceName: "Clipboard")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func test_import_collapsingWhitespace_keepsFiltersAndLines() {
        let messy = "Preamp:   -6.2   dB\r\n\r\nFilter  1:  ON   PK   Fc  105  Hz  Gain\t6.5  dB  Q  0.70\n"
        XCTAssertEqual(ImportFileReader.collapsingWhitespace(messy),
                       "Preamp:\t-6.2\tdB\nFilter\t1:\tON\tPK\tFc\t105\tHz\tGain\t6.5\tdB\tQ\t0.70\n")
        guard case .success(let c) = ImportFileReader.parse(text: messy, sourceName: "x") else {
            return XCTFail("a normal file must still parse")
        }
        XCTAssertEqual(c.filtersInFile, 1)
        XCTAssertEqual(c.filePreampDB, -6.2)
    }

    func test_import_stackedFiltersBeyondThePreamp_areRefused() {
        let stacked = (1 ... 10).map { "Filter \($0): ON PK Fc 1000 Hz Gain 20 dB Q 1.0" }.joined(separator: "\n")
        guard case .failure(.unreadable(_, let reason)) = ImportFileReader.parse(text: stacked, sourceName: "x") else {
            return XCTFail("+180 dB must not import")
        }
        XCTAssertTrue(reason.contains("20 dB"))
    }

    func test_import_aStrongButLegalCorrection_isAccepted() {
        let strong = "Filter 1: ON PK Fc 1000 Hz Gain 18 dB Q 1.0"
        guard case .success = ImportFileReader.parse(text: strong, sourceName: "x") else {
            return XCTFail("the preamp can take this back")
        }
    }

    func test_import_marksOnSpaces_cannotHideAWhitespaceRun() {
        // The parser's \s matches a whole character, so a space carrying a
        // combining mark is still whitespace to it.
        let run = String(repeating: " \u{0301}", count: 5)
        XCTAssertEqual(ImportFileReader.collapsingWhitespace("Filter\(run)1:"), "Filter\t1:")
    }

    func test_import_tabsCarryingMarks_cannotRebuildAWhitespaceRun() {
        let hostile = "Filter" + String(repeating: "\t\u{0301}", count: 30_000) + "x"
        let clean = ImportFileReader.collapsingWhitespace(hostile)
        XCTAssertFalse(clean.contains { $0.isWhitespace && $0.unicodeScalars.count > 1 },
                       "the collapse must not attach a mark to its own whitespace")
        let started = Date()
        _ = ImportFileReader.parse(text: hostile, sourceName: "Clipboard")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func test_numberEntry_frequency_commaWithKilohertzIsADecimal() {
        XCTAssertEqual(NumberEntry.parseFrequency("1,250 kHz"), 1_250)
        XCTAssertEqual(NumberEntry.parseFrequency("2,500k"), 2_500)
        XCTAssertEqual(NumberEntry.parseFrequency("1,5 KHZ"), 1_500)
        XCTAssertEqual(NumberEntry.parseFrequency("1,000 Hz"), 1_000)
        XCTAssertEqual(NumberEntry.parseFrequency("1,000"), 1_000)
    }

    func test_offer_disappearsOnceItIsNoLongerTrue() {
        let (model, _) = makeModel()
        let a = model.presets.add(.correction, name: "A", layer: layer(gain: 3))
        let b = model.presets.add(.correction, name: "B", layer: layer(gain: -3))
        model.presets.bind(deviceUID: airpods.uid, deviceName: airpods.name, to: b.key)
        model.loadPreset(a, .correction)
        model.selectLayer(.target)
        model.updateBand(0) { $0.gain = 9 }
        model.outputDidChange(airpods)
        XCTAssertEqual(model.correctionOffer?.key, b.key)

        // This output now belongs to A, so B is no longer "saved for it".
        model.presets.bind(deviceUID: airpods.uid, deviceName: airpods.name, to: a.key)
        XCTAssertNil(model.correctionOffer)
        model.useSkippedCorrection()
        XCTAssertEqual(model.correctionKey, a.key, "a stale offer must not load anything")
    }

    func test_offer_followsARename() {
        let (model, _) = makeModel()
        let a = model.presets.add(.correction, name: "A", layer: layer(gain: 3))
        let b = model.presets.add(.correction, name: "B", layer: layer(gain: -3))
        model.presets.bind(deviceUID: airpods.uid, deviceName: airpods.name, to: b.key)
        model.loadPreset(a, .correction)
        model.selectLayer(.target)
        model.updateBand(0) { $0.gain = 9 }
        model.outputDidChange(airpods)
        model.presets.rename(b.key, .correction, to: "Renamed")
        XCTAssertEqual(model.correctionOffer?.name, "Renamed")
    }

    func test_aControlStillHeld_resumesWithItsOwnUndoStep() {
        let (model, _) = makeModel()
        let edited = model.dual.editingLayer
        model.beginGesture(owner: "slider", name: "Change Gain")
        model.updateBand(2) { $0.gain = 3 }
        model.beginGesture(owner: "drag", name: "Move Band 6")
        model.updateBand(5) { $0.gain = 6 }
        model.endGesture("Move Band 6", owner: "drag")
        XCTAssertFalse(model.isInGesture)

        // The slider's finger never lifted, and it moves again.
        model.resumeGesture(owner: "slider", name: "Change Gain")
        XCTAssertTrue(model.isInGesture)
        model.updateBand(2) { $0.gain = 4 }
        model.endGesture("Change Gain", owner: "slider")
        XCTAssertFalse(model.isInGesture)

        model.undo()
        XCTAssertEqual(model.layerState(edited).bands[2].gain, 3, "its last movement is its own step")
        XCTAssertEqual(model.layerState(edited).bands[5].gain, 6)
    }

    func test_resumingAGesture_neverInterruptsAnOpenOne() {
        let (model, _) = makeModel()
        let edited = model.dual.editingLayer
        model.beginGesture(owner: "drag", name: "Move Band 6")
        model.updateBand(5) { $0.gain = 6 }
        model.resumeGesture(owner: "slider", name: "Change Gain")
        model.endGesture("Change Gain", owner: "slider")
        XCTAssertTrue(model.isInGesture, "the drag still owns the step")
        model.endGesture("Move Band 6", owner: "drag")
        model.undo()
        XCTAssertEqual(model.layerState(edited).bands[5].gain, 0)
    }

    func test_overlappingGestures_keepTheirOwnUndoSteps() {
        let (model, _) = makeModel()
        let edited = model.dual.editingLayer
        model.beginGesture(owner: "slider", name: "Move Band 3")
        model.updateBand(2) { $0.gain = 3 }
        model.beginGesture(owner: "drag", name: "Move Band 6")
        model.updateBand(5) { $0.gain = 6 }
        model.endGesture("Move Band 3", owner: "slider")    // the slider's row went away
        XCTAssertTrue(model.isInGesture, "the drag is still open")
        model.endGesture("Move Band 6", owner: "drag")
        XCTAssertFalse(model.isInGesture)

        model.undo()
        XCTAssertEqual(model.layerState(edited).bands[5].gain, 0, "the drag is one step")
        XCTAssertEqual(model.layerState(edited).bands[2].gain, 3, "the slider is another")
        model.undo()
        XCTAssertEqual(model.layerState(edited).bands[2].gain, 0)
    }

    func test_aBandThatIsOff_doesNotCountAsShaping() {
        let (model, _) = makeModel()
        model.updateBand(0) { $0.gain = 6 }
        XCTAssertEqual(model.outputBypass, .none)
        model.updateBand(0) { $0.isEnabled = false }
        XCTAssertEqual(model.outputBypass, .allStagesOff)
    }

    func test_graphGesture_startsFromAHalfTypedValue() {
        let (model, _) = makeModel()
        let layer = model.dual.editingLayer
        let owner = UUID()
        model.setFieldFlush(owner: owner) {
            model.commitBandField(2, layer: layer, name: "Move Band 3") { $0.gain = 9 }
        }
        let started = model.openGraphGesture(band: 2)
        XCTAssertEqual(started.state.bands[2].gain, 9, "the drag must start from the typed value")
        model.clearFieldFlush(owner: owner)
        model.endGesture("Move Band 3")
    }

    func test_olderImport_landingLate_cannotReplaceANewerOne() async throws {
        let (model, _) = makeModel()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        try autoEQ.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        model.importFile(url)
        model.importText("Filter 1: ON PK Fc 500 Hz Gain 3 dB Q 1.0", sourceName: "Clipboard")
        let newest = model.importPreview?.id
        XCTAssertNotNil(newest)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(model.importPreview?.id, newest)
    }

    func test_importFinishingAfterItsSheetClosed_doesNotReopenIt() async throws {
        let (model, _) = makeModel()
        model.importText("Filter 1: ON PK Fc 500 Hz Gain 3 dB Q 1.0", sourceName: "Clipboard")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        try autoEQ.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        model.importFile(url)
        model.importPreview = nil       // the user closed the sheet
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(model.importPreview)
    }

    func test_card_neverSaysEqualizingWhileBypassed() {
        let (model, engine) = makeModel()
        engine.status = .running
        XCTAssertEqual(model.outputBypass, .allStagesOff, "a flat EQ is not shaping anything")
        model.updateBand(0) { $0.gain = 2 }
        XCTAssertEqual(model.outputBypass, .none)

        model.toggleCompareLatch()
        XCTAssertEqual(model.outputBypass, .comparing)
        var c = OutputCardContent.make(status: .running, output: airpods, bypass: model.outputBypass)
        XCTAssertFalse(c.title.contains("Equalizing"))
        XCTAssertEqual(c.pill, "Comparing")
        model.toggleCompareLatch()

        model.setLayerOn(.fineTune, false)
        XCTAssertEqual(model.outputBypass, .allStagesOff, "the only shaped layer is off")
        c = OutputCardContent.make(status: .idle, output: airpods, bypass: model.outputBypass)
        XCTAssertFalse(c.title.contains("Equalizing"))

        model.selectBassStyle(.transientPunch)
        XCTAssertEqual(model.outputBypass, .none, "Bass Style is still shaping the sound")
    }

    func test_bypassWording_doesNotReplaceAFailure() {
        let c = OutputCardContent.make(status: .error("It broke."), output: nil, bypass: .comparing)
        XCTAssertEqual(c.message, "It broke.")
    }

    func test_preampFix_isNotOfferedWhileYourTuningIsOff() {
        let (model, _) = makeModel()
        XCTAssertNotNil(model.preampFixDB(overDB: 2))
        model.setLayerOn(.fineTune, false)
        XCTAssertNil(model.preampFixDB(overDB: 2), "it would change nothing you can hear")
    }

    func test_binding_afterTheSelectedPresetWasDeleted_savesItFirst() {
        let (model, _) = makeModel()
        let saved = model.presets.add(.correction, name: "HD 600", layer: layer(gain: 3))
        model.loadPreset(saved, .correction)
        model.presets.delete(saved.key, .correction)    // the key is left dangling, as undo can do

        model.bindCurrentCorrection(to: airpods)

        let bound = model.presets.boundKey(for: airpods.uid)
        XCTAssertNotNil(model.presets.entry(bound, .correction), "the binding must point at something real")
    }

    func test_halfTypedValue_landsBeforeTheGesture_asItsOwnUndoStep() {
        let (model, _) = makeModel()
        let owner = UUID()
        model.setFieldFlush(owner: owner) {
            model.commitBandField(2, name: "Change Gain") { $0.gain = 4 }
        }
        model.beginGesture()
        model.updateBand(5) { $0.gain = -2 }
        model.endGesture("Move Band")

        model.undo()
        XCTAssertEqual(model.band(5).gain, 0)
        XCTAssertEqual(model.band(2).gain, 4, "undoing the drag must leave the typed value")
    }

    func test_fieldFlush_isOnlyClearedByItsOwner() {
        let (model, _) = makeModel()
        let a = UUID(), b = UUID()
        var hits = 0
        model.setFieldFlush(owner: b) { hits += 1 }
        model.clearFieldFlush(owner: a)     // focus moved from A to B, in either order
        model.beginGesture()
        model.endGesture("x")
        XCTAssertEqual(hits, 1)
    }

    func test_droppedFilters_previewIsCapped() {
        var c = ImportedCorrection(layer: .flat, filtersInFile: 25_010, dropped: [], filePreampDB: nil,
                                   suggestedName: "x", sourceName: "x")
        c.dropped = Array(repeating: EQBand(frequency: 100, gain: 1, q: 1), count: 25_000)
        XCTAssertLessThan(c.droppedPreview.count, 200)
        XCTAssertTrue(c.droppedPreview.hasSuffix("and 24995 more"))
    }

    func test_turningOff_releasesCompare() {
        let (model, engine) = makeModel()
        engine.status = .running
        model.toggleCompareLatch()
        model.compareHeld = true
        model.setPowered(false)
        XCTAssertFalse(model.isComparing)
    }

    // MARK: Scene

    func test_scene_reportsForegroundToTheEngine() {
        let (model, engine) = makeModel()
        model.sceneDidChange(isActive: true, isBackground: false)
        model.sceneDidChange(isActive: false, isBackground: true)
        XCTAssertEqual(engine.foregroundCalls, [true, false])
    }

    func test_scene_leavingActive_releasesAHeldCompare() {
        let (model, engine) = makeModel()
        engine.status = .running
        model.compareHeld = true
        model.sceneDidChange(isActive: false, isBackground: false)
        XCTAssertFalse(model.compareHeld, "a stuck hold leaves the EQ silently bypassed")
        XCTAssertEqual(engine.applied.last?.masterBypass, false)
    }

    func test_scene_leavingActive_keepsALatchedCompare() {
        let (model, engine) = makeModel()
        engine.status = .running
        model.toggleCompareLatch()
        model.sceneDidChange(isActive: false, isBackground: false)
        XCTAssertTrue(model.compareLatched)
    }

    func test_scene_leavingActive_closesAGestureAsOneUndoStep() {
        let (model, _) = makeModel()
        model.beginGesture()
        model.graphFrozenYMax = 12
        model.isDraggingGraph = true
        model.updateBand(0) { $0.gain = 4 }

        model.sceneDidChange(isActive: false, isBackground: false)

        XCTAssertFalse(model.isInGesture)
        XCTAssertNil(model.graphFrozenYMax)
        XCTAssertFalse(model.isDraggingGraph)
        XCTAssertTrue(model.canUndo)

        // The next edit must get its own step instead of folding into a dead gesture.
        model.perform("Reset Band") { model.updateBand(1) { $0.gain = 2 } }
        model.undo()
        XCTAssertEqual(model.band(1).gain, 0)
        XCTAssertEqual(model.band(0).gain, 4)
    }

    // MARK: Compare

    func test_compareLatch_needsTheEQInThePath() {
        let (model, engine) = makeModel()
        for status: EngineStatus in [.off, .starting, .waiting, .interrupted, .feedbackGuard, .passThrough, .error("x")] {
            engine.status = status
            model.toggleCompareLatch()
            XCTAssertFalse(model.compareLatched, "latched in \(status)")
        }
        engine.status = .idle
        model.toggleCompareLatch()
        XCTAssertTrue(model.compareLatched)
    }

    func test_compareLatch_canAlwaysBeReleased() {
        let (model, engine) = makeModel()
        engine.status = .running
        model.toggleCompareLatch()
        engine.status = .waiting      // the extension dropped while it was on
        model.toggleCompareLatch()
        XCTAssertFalse(model.compareLatched, "Compare got stuck on")
    }

    // MARK: Pass-through

    func test_passThrough_isNotProcessing() {
        let (model, engine) = makeModel()
        engine.status = .passThrough
        XCTAssertFalse(model.displayIsProcessing, "the EQ is not in the audio path")
    }

    func test_passThrough_cardExplainsHowToDisconnect() {
        let c = OutputCardContent.make(status: .passThrough, output: airpods)
        XCTAssertEqual(c.title, "EQ is off")
        XCTAssertTrue(c.message.contains("still passing through EQtargets"))
        XCTAssertTrue(c.message.contains("Control Center"))
        XCTAssertEqual(c.action, .turnOn)
    }

    // MARK: Output card

    func test_card_waitingGivesTheControlCenterInstruction() {
        let c = OutputCardContent.make(status: .waiting, output: airpods)
        XCTAssertEqual(c.message, "Open Control Center, tap the audio output, and choose EQtargets.")
    }

    func test_card_runningAndIdleNameTheRealOutput() {
        for status: EngineStatus in [.running, .idle] {
            XCTAssertEqual(OutputCardContent.make(status: status, output: airpods).title,
                           "Equalizing through AirPods Max")
            XCTAssertEqual(OutputCardContent.make(status: status, output: nil).title, "Equalizing your audio")
        }
    }

    func test_card_errorShowsTheMessageAndARetry() {
        let c = OutputCardContent.make(status: .error("It broke."), output: nil)
        XCTAssertEqual(c.message, "It broke.")
        XCTAssertEqual(c.action, .tryAgain)
    }

    // MARK: Sample rate mirror

    func test_graphRate_followsTheEngineWhileProcessing() async {
        let (model, engine) = makeModel()
        engine.status = .running
        engine.stats.sampleRate = 44_100
        let followed = await waitUntil { model.graphSampleRate == 44_100 }
        XCTAssertTrue(followed)

        engine.stats.sampleRate = 96_000      // the mirror must keep re-arming
        let followedAgain = await waitUntil { model.graphSampleRate == 96_000 }
        XCTAssertTrue(followedAgain)

        engine.status = .waiting
        XCTAssertEqual(model.graphSampleRate, ResponseMath.fallbackSampleRate)
    }

    // MARK: Import

    private let autoEQ = """
    Preamp: -3.0 dB
    Filter 1: ON PK Fc 100 Hz Gain 3.0 dB Q 1.00
    Filter 2: ON PK Fc 1000 Hz Gain -2.0 dB Q 2.00
    """

    func test_paste_withoutFilters_opensNothingAndSaysSo() {
        let (model, _) = makeModel()
        XCTAssertFalse(model.pasteAutoEQ(text: "hello"))
        XCTAssertFalse(model.pasteAutoEQ(text: nil))
        XCTAssertNil(model.importPreview)
        XCTAssertNotNil(model.toast)
    }

    func test_import_changesNothingUntilApplied_thenKeepsYourTuning() {
        let (model, _) = makeModel()
        model.updateBand(5) { $0.gain = 2 }
        let tuning = model.dual.fineTune

        XCTAssertTrue(model.pasteAutoEQ(text: autoEQ))
        XCTAssertTrue(model.dual.target.isFlat, "a preview must not touch the sound")

        model.applyImport(model.importPreview!)
        XCTAssertEqual(model.dual.target.bands[0].gain, 3)
        XCTAssertEqual(model.dual.fineTune, tuning)
        XCTAssertEqual(model.presets.user(.correction).count, 1)
        XCTAssertNil(model.importPreview)
    }

    func test_import_bindsToTheCurrentOutputWhenAsked() {
        let (model, engine) = makeModel()
        engine.currentOutput = airpods
        model.pasteAutoEQ(text: autoEQ)
        model.applyImport(model.importPreview!)
        XCTAssertEqual(model.presets.boundKey(for: airpods.uid), model.correctionKey)
    }

    func test_importFile_oversizedFile_isRefusedWithoutReadingItAll() async throws {
        let (model, _) = makeModel()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        try Data(repeating: 0x41, count: AutoEQImport.maxBytes + 1).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        model.importFile(url)
        let done = await waitUntil(timeout: 5) { model.importPreview != nil }
        XCTAssertTrue(done)
        guard case .failure(.tooLarge)? = model.importPreview?.result else {
            return XCTFail("expected tooLarge")
        }
    }

    func test_importFile_readsARealFileAndNamesItFromTheFile() async throws {
        let (model, _) = makeModel()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Sennheiser HD 600 ParametricEQ.txt")
        try autoEQ.write(to: url, atomically: true, encoding: .utf8)

        model.importFile(url)
        let loaded = await waitUntil(timeout: 5) { model.importPreview != nil }
        XCTAssertTrue(loaded)

        guard case .success(let correction)? = model.importPreview?.result else {
            return XCTFail("the file did not parse")
        }
        XCTAssertEqual(correction.filtersInFile, 2)
        XCTAssertEqual(model.importPreview?.name, "Sennheiser HD 600")
        XCTAssertTrue(model.dual.target.isFlat, "a preview must not touch the sound")
    }

    func test_importFile_aMissingFileExplainsItselfAndChangesNothing() async {
        let (model, _) = makeModel()
        model.importFile(URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/x.txt"))
        let shown = await waitUntil(timeout: 5) { model.importPreview != nil }
        XCTAssertTrue(shown)
        guard case .failure(let failure)? = model.importPreview?.result else {
            return XCTFail("expected a failure preview")
        }
        XCTAssertTrue(failure.title.contains("x.txt"))
        XCTAssertTrue(model.dual.target.isFlat)
        XCTAssertTrue(model.presets.user(.correction).isEmpty)
    }

    // MARK: Graph touch

    private let geo = GraphGeometry(size: CGSize(width: 358, height: 330), yMax: 12)

    private func nodes(_ l: EQLayerState = .flat) -> [CGPoint] {
        l.bands.map { geo.nodePoint(frequency: $0.frequency, db: $0.gain + l.preamp) }
    }

    func test_hitTest_preampHandleIsReachableBesideBandOne() {
        let tab = geo.preampTabRect(preamp: 0)
        let points = nodes()
        XCTAssertLessThan(hypot(points[0].x - tab.midX, points[0].y - tab.midY), GraphGeometry.hitRadius,
                          "precondition: band 1's touch target covers the handle")
        XCTAssertEqual(GraphHitTest.target(at: CGPoint(x: tab.midX, y: tab.midY), nodes: points,
                                           selected: nil, preampTab: tab), .preamp)
        XCTAssertEqual(GraphHitTest.target(at: points[0], nodes: points, selected: nil, preampTab: tab), .band(0))
    }

    func test_hitTest_aTouchOnANeighbourIsNotStolenByTheSelection() {
        let points = nodes()
        let tab = geo.preampTabRect(preamp: 0)
        XCTAssertEqual(GraphHitTest.target(at: points[4], nodes: points, selected: 3, preampTab: tab), .band(4))
    }

    func test_hitTest_aStackKeepsTheSelectedBand() {
        var l = EQLayerState.flat
        l.bands[4].frequency = l.bands[5].frequency
        let points = nodes(l)
        let tab = geo.preampTabRect(preamp: 0)
        XCTAssertEqual(GraphHitTest.target(at: points[5], nodes: points, selected: 4, preampTab: tab), .band(4))
        XCTAssertEqual(GraphHitTest.target(at: points[5], nodes: points, selected: 5, preampTab: tab), .band(5))
    }

    func test_hitTest_emptyPlotIsNoTarget() {
        let points = nodes()
        let tab = geo.preampTabRect(preamp: 0)
        let empty = CGPoint(x: points[5].x, y: geo.plot.minY + 4)
        XCTAssertNil(GraphHitTest.target(at: empty, nodes: points, selected: nil, preampTab: tab),
                     "a touch here must fall through so the page can scroll")
    }

    func test_dragMapping_roundTripsThroughThePlot() {
        let p = CGPoint(x: geo.x(1_000), y: geo.y(6 + (-2)))
        let v = geo.bandValues(at: p, preamp: -2)
        XCTAssertEqual(v.frequency, 1_000, accuracy: 0.01)
        XCTAssertEqual(v.gain, 6, accuracy: 0.01, "a node rides its curve: gain excludes the preamp")
        XCTAssertFalse(v.snapped)
    }

    func test_dragMapping_snapsNearZeroAndClampsToTheModelRange() {
        XCTAssertEqual(geo.bandValues(at: CGPoint(x: geo.x(100), y: geo.y(0.2)), preamp: 0).gain, 0)
        XCTAssertTrue(geo.bandValues(at: CGPoint(x: geo.x(100), y: geo.y(0.2)), preamp: 0).snapped)
        XCTAssertEqual(geo.bandValues(at: CGPoint(x: geo.x(100), y: geo.y(0.5)), preamp: 0).gain, 0.5, accuracy: 0.01)
        let far = geo.bandValues(at: CGPoint(x: -500, y: -5_000), preamp: 0)
        XCTAssertEqual(far.frequency, EQBand.frequencyRange.lowerBound)
        XCTAssertEqual(far.gain, EQBand.gainRange.upperBound)
    }

    func test_pinch_spreadingWidensTheBellAndClamps() {
        XCTAssertEqual(GraphGeometry.pinchedQ(start: 2, scale: 2), 1, accuracy: 0.001)
        XCTAssertEqual(GraphGeometry.pinchedQ(start: 2, scale: 0.5), 4, accuracy: 0.001)
        XCTAssertEqual(GraphGeometry.pinchedQ(start: 2, scale: 1_000), EQBand.qRange.lowerBound)
        XCTAssertEqual(GraphGeometry.pinchedQ(start: 8, scale: 0.01), EQBand.qRange.upperBound)
    }

    func test_logScale_isTheInverseOfItself_andEqualRatiosGetEqualTravel() {
        let range = EQBand.frequencyRange
        XCTAssertEqual(LogScale.unit(20, in: range), 0, accuracy: 1e-9)
        XCTAssertEqual(LogScale.unit(20_000, in: range), 1, accuracy: 1e-9)
        XCTAssertEqual(LogScale.value(LogScale.unit(1_234, in: range), in: range), 1_234, accuracy: 1e-6)
        let octaveLow = LogScale.unit(200, in: range) - LogScale.unit(100, in: range)
        let octaveHigh = LogScale.unit(8_000, in: range) - LogScale.unit(4_000, in: range)
        XCTAssertEqual(octaveLow, octaveHigh, accuracy: 1e-9)
    }

    // MARK: Tunings per output (the speaker gets taste, not a measurement)

    private let speakerOut = OutputDevice(uid: "Speaker", name: "Speaker", transport: .builtIn)

    func test_tuning_boundToAnOutput_loadsWhenItBecomesTheOutput_asOneUndoStep() {
        let (model, _) = makeModel()
        let soft = model.presets.add(.tuning, name: "Speaker Soft", layer: layer(gain: -2))
        model.tuningBindings.bind(deviceUID: speakerOut.uid, deviceName: speakerOut.name, to: soft.key)
        model.outputDidChange(speakerOut)
        XCTAssertEqual(model.tuningKey, soft.key)
        XCTAssertEqual(model.dual.fineTune.bands[0].gain, -2)
        XCTAssertFalse(model.dual.fineTune.isBypassed, "loading turns the layer on, as a Correction load does")
        XCTAssertEqual(model.toast?.text.contains("\u{201C}Speaker Soft\u{201D}"), true)
        model.undo()
        XCTAssertNotEqual(model.tuningKey, soft.key)
        XCTAssertEqual(model.dual.fineTune.bands[0].gain, 0)
    }

    func test_tuningAndCorrection_bothBound_loadTogether_andOneUndoRestoresBoth() {
        let (model, _) = makeModel()
        let c = model.presets.add(.correction, name: "C", layer: layer(gain: 3))
        let t = model.presets.add(.tuning, name: "T", layer: layer(gain: -4))
        model.presets.bind(deviceUID: airpods.uid, deviceName: airpods.name, to: c.key)
        model.tuningBindings.bind(deviceUID: airpods.uid, deviceName: airpods.name, to: t.key)
        let before = model.editSnapshot
        model.outputDidChange(airpods)
        XCTAssertEqual(model.correctionKey, c.key)
        XCTAssertEqual(model.tuningKey, t.key)
        XCTAssertEqual(model.toast?.text.contains("\u{201C}C\u{201D} and \u{201C}T\u{201D}"), true)
        model.undo()
        XCTAssertEqual(model.editSnapshot, before, "one step, not two")
    }

    func test_tuning_onlyTheCorrectionBound_leavesTheTuningAlone() {
        let (model, _) = makeModel()
        let c = model.presets.add(.correction, name: "C", layer: layer(gain: 3))
        model.presets.bind(deviceUID: airpods.uid, deviceName: airpods.name, to: c.key)
        let tuning = model.dual.fineTune
        let key = model.tuningKey
        model.outputDidChange(airpods)
        XCTAssertEqual(model.dual.fineTune, tuning)
        XCTAssertEqual(model.tuningKey, key)
    }

    func test_tuning_editedTuningIsNeverDiscarded_andTheBoundOneIsOffered() {
        let (model, _) = makeModel()
        let a = model.presets.add(.tuning, name: "A", layer: layer(gain: 3))
        let b = model.presets.add(.tuning, name: "B", layer: layer(gain: -3))
        model.tuningBindings.bind(deviceUID: speakerOut.uid, deviceName: speakerOut.name, to: b.key)
        model.loadPreset(a, .tuning)
        model.selectLayer(.fineTune)
        model.updateBand(0) { $0.gain = 9 }

        model.outputDidChange(speakerOut)

        XCTAssertEqual(model.tuningKey, a.key)
        XCTAssertEqual(model.dual.fineTune.bands[0].gain, 9)
        XCTAssertEqual(model.tuningOffer?.key, b.key)
        model.useSkippedTuning()
        XCTAssertEqual(model.tuningKey, b.key)
        XCTAssertNil(model.tuningOffer)
        model.undo()
        XCTAssertEqual(model.dual.fineTune.bands[0].gain, 9, "one undo brings the edits back")
    }

    func test_tuning_duringAGesture_waitsForTheFinger() {
        let (model, _) = makeModel()
        let t = model.presets.add(.tuning, name: "T", layer: layer(gain: -3))
        model.tuningBindings.bind(deviceUID: speakerOut.uid, deviceName: speakerOut.name, to: t.key)
        model.beginGesture()
        model.outputDidChange(speakerOut)
        XCTAssertNotEqual(model.tuningKey, t.key, "not under the finger")
        model.endGesture("Move Band")
        XCTAssertEqual(model.tuningKey, t.key, "retried when the finger lifts")
    }

    func test_tuning_routeChangeToAnUnboundOutput_clearsTheOffer_andChangesNothing() {
        let (model, _) = makeModel()
        let a = model.presets.add(.tuning, name: "A", layer: layer(gain: 3))
        let b = model.presets.add(.tuning, name: "B", layer: layer(gain: -3))
        model.tuningBindings.bind(deviceUID: speakerOut.uid, deviceName: speakerOut.name, to: b.key)
        model.loadPreset(a, .tuning)
        model.selectLayer(.fineTune)
        model.updateBand(0) { $0.gain = 9 }
        model.outputDidChange(speakerOut)
        XCTAssertNotNil(model.tuningOffer)
        let before = model.editSnapshot
        model.outputDidChange(airpods)
        XCTAssertNil(model.tuningOffer)
        XCTAssertEqual(model.editSnapshot, before)
    }

    func test_tuning_alreadySelected_isNotReloaded_soEditsSurviveARouteFlap() {
        let (model, _) = makeModel()
        let t = model.presets.add(.tuning, name: "T", layer: layer(gain: -3))
        model.tuningBindings.bind(deviceUID: speakerOut.uid, deviceName: speakerOut.name, to: t.key)
        model.loadPreset(t, .tuning)
        model.selectLayer(.fineTune)
        model.updateBand(0) { $0.gain = 7 }
        model.outputDidChange(speakerOut)
        XCTAssertEqual(model.dual.fineTune.bands[0].gain, 7)
        XCTAssertNil(model.tuningOffer)
    }

    func test_tuning_alreadySelectedAndUnedited_isNotReloaded_soTheLayerStaysOff() {
        let (model, _) = makeModel()
        let t = model.presets.add(.tuning, name: "T", layer: layer(gain: -3))
        model.tuningBindings.bind(deviceUID: speakerOut.uid, deviceName: speakerOut.name, to: t.key)
        model.loadPreset(t, .tuning)
        model.setLayerOn(.fineTune, false)            // the user switched the layer off
        let before = model.editSnapshot
        let toast = model.toast
        model.outputDidChange(speakerOut)             // the same output, reported again
        XCTAssertTrue(model.dual.fineTune.isBypassed, "a reload would turn the layer back on")
        XCTAssertEqual(model.editSnapshot, before)
        XCTAssertEqual(model.toast, toast, "no toast for a preset that is already loaded")
    }

    func test_bindCurrentTuning_savesAnEditedTuningFirst_thenBinds() {
        let (model, _) = makeModel()
        model.selectLayer(.fineTune)
        model.updateBand(0) { $0.gain = 4 }            // the built-in flat tuning, edited
        model.bindCurrentTuning(to: speakerOut)
        let key = model.tuningKey
        XCTAssertNotNil(key)
        XCTAssertFalse(key?.isBuiltin ?? true, "a binding must point at something saved")
        XCTAssertEqual(model.presets.entry(key!, .tuning)?.layer.bands[0].gain, 4)
        XCTAssertEqual(model.tuningBindings.boundKey(for: speakerOut.uid), key)
        XCTAssertTrue(model.isCurrentTuningBound(to: speakerOut))
        XCTAssertEqual(model.boundDeviceNames(for: key, .tuning), ["Speaker"])
        XCTAssertTrue(model.boundDeviceNames(for: key, .correction).isEmpty, "the two kinds stay apart")
    }

    func test_bindCurrentTuning_aSavedTuning_bindsItAsIs() {
        let (model, _) = makeModel()
        let t = model.presets.add(.tuning, name: "T", layer: layer(gain: -3))
        model.loadPreset(t, .tuning)
        let count = model.presets.user(.tuning).count
        model.bindCurrentTuning(to: speakerOut)
        XCTAssertEqual(model.tuningBindings.boundKey(for: speakerOut.uid), t.key)
        XCTAssertEqual(model.presets.user(.tuning).count, count, "nothing new saved")
    }

    func test_unbindTuning_stopsTheAutomaticLoad_andLeavesCorrectionBindings() {
        let (model, _) = makeModel()
        let c = model.presets.add(.correction, name: "C", layer: layer(gain: 3))
        let t = model.presets.add(.tuning, name: "T", layer: layer(gain: -3))
        model.presets.bind(deviceUID: speakerOut.uid, deviceName: speakerOut.name, to: c.key)
        model.tuningBindings.bind(deviceUID: speakerOut.uid, deviceName: speakerOut.name, to: t.key)
        model.unbind(.tuning, speakerOut.uid)
        XCTAssertNil(model.tuningBindings.boundKey(for: speakerOut.uid))
        XCTAssertEqual(model.presets.boundKey(for: speakerOut.uid), c.key)
    }

    func test_deletingATuning_removesItsBindings_soNoOutputPointsAtNothing() throws {
        let (model, _) = makeModel()
        let t = model.presets.add(.tuning, name: "T", layer: layer(gain: -3))
        model.tuningBindings.bind(deviceUID: speakerOut.uid, deviceName: speakerOut.name, to: t.key)
        model.loadPreset(t, .tuning)
        model.requestDelete(.tuning)
        model.confirmDelete(try XCTUnwrap(model.pendingDelete))
        XCTAssertNil(model.tuningBindings.boundKey(for: speakerOut.uid))
    }

    func test_tuningBindings_surviveARelaunch_underTheirOwnKey() {
        let defaults = makeDefaults()
        let (first, _) = makeModel(defaults: defaults)
        let t = first.presets.add(.tuning, name: "T", layer: layer(gain: -3))
        first.tuningBindings.bind(deviceUID: speakerOut.uid, deviceName: speakerOut.name, to: t.key)
        XCTAssertNotNil(defaults.data(forKey: TuningBindingStore.key))
        XCTAssertNil(defaults.data(forKey: PresetStore.Keys.bindings), "the Mac's Correction bindings are untouched")
        let (second, _) = makeModel(defaults: defaults)
        XCTAssertEqual(second.tuningBindings.boundKey(for: speakerOut.uid), t.key)
        second.outputDidChange(speakerOut)
        XCTAssertEqual(second.tuningKey, t.key)
    }
}
