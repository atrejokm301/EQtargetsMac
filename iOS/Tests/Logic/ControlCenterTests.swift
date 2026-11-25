//
//  ControlCenterTests.swift
//  EQtargets (iOS)
//
//  The two Control Center tiles. iOS can launch the app just to run one, with no
//  window, so these cover that case as well as the app already being open.
//

import AppIntents
import Security
import XCTest

@MainActor
final class ControlCenterTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let name = "eqt.controls.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    private func makeModel(defaults: UserDefaults? = nil) -> (AppModel, StandInEngine) {
        let engine = StandInEngine()
        return (AppModel(engine: engine, defaults: defaults ?? makeDefaults(), mode: .live), engine)
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return true
    }

    /// Records what the app sends to the tiles.
    private final class TileOutput {
        var saved: [EQControlState] = []
        var redraws = 0
        var saveWorks = true

        var output: EQControlOutput {
            EQControlOutput(
                save: { [self] state in
                    guard saveWorks else { return false }
                    saved.append(state)
                    return true
                },
                redraw: { [self] in redraws += 1 })
        }
    }

    // MARK: On/Off tile

    func test_turningOn_withNoWindow_fullyStartsTheApp() throws {
        let (model, engine) = makeModel()
        try model.setPoweredFromControl(true, mayOpenApp: true)
        XCTAssertEqual(engine.poweredCalls, [true])
        XCTAssertNotNil(engine.onOutputChanged, "it must be started, not just powered")
        XCTAssertEqual(engine.applied.count, 1, "the engine needs the saved EQ")
        XCTAssertEqual(engine.foregroundCalls, [false], "with no window it must not poll at the foreground rate")
        XCTAssertEqual(engine.watchCalls, 1, "a connection arriving now has to be noticed")
    }

    /// "Turn on when EQtargets opens" must not start the audio just to stop it.
    func test_turningOff_onAColdLaunch_neverTurnsOnFirst() throws {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppModel.Keys.turnOnAtLaunch)
        let (model, engine) = makeModel(defaults: defaults)
        try model.setPoweredFromControl(false, mayOpenApp: true)
        XCTAssertFalse(engine.isPowered)
        XCTAssertFalse(engine.poweredCalls.contains(true))
    }

    func test_aWindowOpeningSoonAfter_keepsTheTilesChoice() throws {
        let (model, engine) = makeModel()
        var now = Date()
        model.wallClock = { now }
        try model.setPoweredFromControl(false, mayOpenApp: true)
        now += 299
        model.start()                       // what the first frame does
        XCTAssertFalse(engine.isPowered)
    }

    /// Days later, opening the app must follow the setting whether or not iOS kept
    /// the process alive in between.
    func test_aWindowOpeningMuchLater_followsTheSetting() throws {
        let (model, engine) = makeModel()
        var now = Date()
        model.wallClock = { now }
        try model.setPoweredFromControl(false, mayOpenApp: true)
        now += 301
        model.start()
        XCTAssertTrue(engine.isPowered)
    }

    func test_withTheAppOpen_theTileJustSetsPower() throws {
        let (model, engine) = makeModel()
        model.start()
        model.sceneDidChange(isActive: true, isBackground: false)
        let foregroundCalls = engine.foregroundCalls
        try model.setPoweredFromControl(false, mayOpenApp: true)
        XCTAssertFalse(engine.isPowered)
        try model.setPoweredFromControl(true, mayOpenApp: true)
        XCTAssertTrue(engine.isPowered)
        XCTAssertEqual(engine.foregroundCalls, foregroundCalls, "a visible app keeps its refresh rate")
        XCTAssertEqual(engine.watchCalls, 0, "a visible app's timer is already running")
    }

    /// EQtargets can be picked from Control Center while it covers the app.
    func test_underControlCenter_theEngineKeepsLooking() {
        let (model, engine) = makeModel()
        model.sceneDidChange(isActive: false, isBackground: false)
        XCTAssertEqual(engine.foregroundCalls.last, true)
        model.sceneDidChange(isActive: false, isBackground: true)
        XCTAssertEqual(engine.foregroundCalls.last, false)
    }

    func test_aBackgroundApp_isNotToldTwice() throws {
        let (model, engine) = makeModel()
        model.start()
        model.sceneDidChange(isActive: false, isBackground: true)
        let foregroundCalls = engine.foregroundCalls
        try model.setPoweredFromControl(false, mayOpenApp: true)
        XCTAssertEqual(engine.foregroundCalls, foregroundCalls)
        XCTAssertEqual(engine.watchCalls, 1)
    }

    func test_turningOff_endsCompare() throws {
        let (model, _) = makeModel()
        model.start()
        model.compareLatched = true
        try model.setPoweredFromControl(false, mayOpenApp: true)
        XCTAssertFalse(model.compareLatched)
    }

    func test_onWhenAlreadyOn_leavesTheAudioAlone() throws {
        let (model, engine) = makeModel()
        model.start()
        try model.setPoweredFromControl(true, mayOpenApp: true)
        XCTAssertEqual(engine.poweredCalls, [true])
        XCTAssertEqual(engine.retryCalls, 0, "a retry rebuilds audio that is working")
    }

    func test_onAfterAFailure_triesTheAudioAgain() throws {
        let (model, engine) = makeModel()
        model.start()
        engine.status = .error("failed")
        try model.setPoweredFromControl(true, mayOpenApp: false)
        XCTAssertEqual(engine.retryCalls, 1)
    }

    // MARK: When iOS refuses the audio in the background

    func test_aRefusedBackgroundStart_turnsBackOff_andAsksForTheApp() {
        let (model, engine) = makeModel()
        engine.startFailure = "refused"
        XCTAssertThrowsError(try model.setPoweredFromControl(true, mayOpenApp: true)) { error in
            guard case EQControlError.audioNeedsForeground = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
        XCTAssertFalse(engine.isPowered, "the tile must not be left saying On")
        XCTAssertFalse(model.controlState.isOn)
    }

    func test_onceTheAppIsOpen_aFailureStaysVisibleInIt() throws {
        let (model, engine) = makeModel()
        engine.startFailure = "refused"
        try model.setPoweredFromControl(true, mayOpenApp: false)
        XCTAssertTrue(engine.isPowered, "the app shows the error and its Try Again")
        XCTAssertEqual(engine.status, .error("refused"))
        XCTAssertFalse(model.controlState.isOn, "but the tile doesn't claim On")
    }

    func test_aMutedFeedbackGuard_isNotOn() {
        let (model, engine) = makeModel()
        model.start()
        engine.status = .feedbackGuard
        XCTAssertFalse(model.controlState.isOn)
    }

    func test_aFailureWithTheAppInFront_doesNotAskToOpenIt() throws {
        let (model, engine) = makeModel()
        model.sceneDidChange(isActive: true, isBackground: false)
        engine.startFailure = "refused"
        XCTAssertNoThrow(try model.setPoweredFromControl(true, mayOpenApp: true))
    }

    private final class ScriptedHandler: EQControlHandling {
        var refusals = 0
        var powerCalls: [(on: Bool, mayOpenApp: Bool)] = []
        var bassSteps = 0

        func setPoweredFromControl(_ on: Bool, mayOpenApp: Bool) throws {
            powerCalls.append((on, mayOpenApp))
            if refusals > 0 {
                refusals -= 1
                throw EQControlError.audioNeedsForeground
            }
        }

        func nextBassStyleFromControl() { bassSteps += 1 }
    }

    func test_theFlow_opensTheAppOnlyWhenRefused_thenTriesOnceMore() async throws {
        let handler = ScriptedHandler()
        handler.refusals = 1
        var opened = 0
        try await EQControlFlow.setPower(true, handler: handler) { opened += 1 }
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(handler.powerCalls.map(\.mayOpenApp), [true, false])
    }

    func test_theFlow_staysInTheBackgroundWhenAllowed() async throws {
        let handler = ScriptedHandler()
        var opened = 0
        try await EQControlFlow.setPower(true, handler: handler) { opened += 1 }
        XCTAssertEqual(opened, 0)
        XCTAssertEqual(handler.powerCalls.count, 1)
    }

    // MARK: A reconnect during Off

    func test_offDuringABriefReconnect_keepsTheAudioGoing() {
        var power = LinkPowerState()
        _ = power.setPowered(true, hasPeer: false)
        XCTAssertEqual(power.setPowered(false, hasPeer: false, secondsSincePeer: 1), .updateBypass)
        XCTAssertTrue(power.passThrough)
        XCTAssertEqual(power.observe(hasPeer: false, secondsSincePeer: LinkPowerState.peerGraceSeconds),
                       .stopEngine, "if it never comes back, the engine still stops")
    }

    func test_offLongAfterThePeerLeft_stops() {
        var power = LinkPowerState()
        _ = power.setPowered(true, hasPeer: false)
        XCTAssertEqual(power.setPowered(false, hasPeer: false,
                                        secondsSincePeer: LinkPowerState.peerGraceSeconds), .stopEngine)
    }

    // MARK: Bass tile

    func test_theBassTile_stepsThroughEveryStyle_inOrder() {
        let (model, _) = makeModel()
        XCTAssertEqual(model.bass.style, BassStyle.none)
        var seen: [BassStyle] = []
        for _ in BassStyle.allCases {
            model.nextBassStyleFromControl()
            seen.append(model.bass.style)
        }
        XCTAssertEqual(seen, [.transientPunch, .sustainRumble, .naturalClean, BassStyle.none])
    }

    func test_theBassTile_doesNotStartTheAudio() {
        let (model, engine) = makeModel()
        model.nextBassStyleFromControl()
        XCTAssertTrue(engine.poweredCalls.isEmpty)
        XCTAssertEqual(engine.foregroundCalls, [false], "with no window it must not poll at the foreground rate")
        XCTAssertEqual(engine.watchCalls, 1, "a connection arriving now has to be noticed")
    }

    func test_theBassTile_reachesTheAudio() async {
        let (model, engine) = makeModel()
        model.start()
        model.nextBassStyleFromControl()
        let arrived = await waitUntil { engine.applied.last?.bass.style == .transientPunch }
        XCTAssertTrue(arrived)
    }

    /// iOS can end a background-launched app right after the tile's action.
    func test_theBassTile_isSavedAtOnce() {
        let defaults = makeDefaults()
        let (model, _) = makeModel(defaults: defaults)
        model.nextBassStyleFromControl()
        let (reopened, _) = makeModel(defaults: defaults)
        XCTAssertEqual(reopened.bass.style, .transientPunch)
    }

    func test_theBassTile_canBeUndoneInTheApp() {
        let (model, _) = makeModel()
        model.nextBassStyleFromControl()
        XCTAssertTrue(model.canUndo)
        model.undo()
        XCTAssertEqual(model.bass.style, BassStyle.none)
    }

    func test_theBassTile_usesEachStylesRecommendedCutoff() {
        let (model, _) = makeModel()
        var cutoffs: [Double] = []
        for _ in 1 ... 3 {
            model.nextBassStyleFromControl()
            cutoffs.append(model.bass.cutoff)
        }
        XCTAssertEqual(cutoffs, [85, 55, 120])
        model.nextBassStyleFromControl()    // Off
        model.nextBassStyleFromControl()    // Punch again, from Clean's cutoff
        XCTAssertEqual(model.bass.cutoff, 85)
    }

    /// Going round the styles must not wipe a cutoff set by hand.
    func test_theBassTile_keepsACustomCutoff() {
        let (model, _) = makeModel()
        model.selectBassStyle(.transientPunch)
        model.updateBass { $0.cutoff = 65 }
        for _ in BassStyle.allCases { model.nextBassStyleFromControl() }
        XCTAssertEqual(model.bass.style, .transientPunch)
        XCTAssertEqual(model.bass.cutoff, 65)
    }

    func test_choosingAStyleInTheApp_stillSnapsTheCutoff() {
        let (model, _) = makeModel()
        model.selectBassStyle(.transientPunch)
        model.updateBass { $0.cutoff = 65 }
        model.selectBassStyle(.sustainRumble)
        XCTAssertEqual(model.bass.cutoff, 55)
    }

    // MARK: What the tiles show

    func test_theTilesFollowChangesMadeInTheApp() {
        let (model, _) = makeModel()
        let tiles = TileOutput()
        model.controlOutput = tiles.output
        model.start()
        XCTAssertEqual(tiles.saved.last?.isOn, true)
        model.setPowered(false)
        XCTAssertEqual(tiles.saved.last?.isOn, false)
        model.selectBassStyle(.sustainRumble)
        XCTAssertEqual(tiles.saved.last?.bassName, BassStyle.sustainRumble.compactTitle)
        XCTAssertEqual(tiles.saved.last?.bassSymbol, BassStyle.sustainRumble.systemImage)
        model.undo()
        XCTAssertEqual(tiles.saved.last?.bassName, BassStyle.none.compactTitle)
        XCTAssertEqual(tiles.redraws, tiles.saved.count)
    }

    func test_aBassTileTap_updatesTheTile() {
        let (model, _) = makeModel()
        let tiles = TileOutput()
        model.controlOutput = tiles.output
        model.nextBassStyleFromControl()
        XCTAssertEqual(tiles.saved.last?.bassName, BassStyle.transientPunch.compactTitle)
    }

    func test_aColdOff_updatesATileThatStillSaysOn() throws {
        let (model, _) = makeModel()
        let tiles = TileOutput()
        model.controlOutput = tiles.output
        try model.setPoweredFromControl(false, mayOpenApp: true)
        XCTAssertEqual(tiles.saved.last?.isOn, false)
    }

    /// A tile can still say On from an earlier run, so the first report always goes out.
    func test_theFirstReport_goesOutEvenWithNoChange() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: AppModel.Keys.turnOnAtLaunch)
        // A saved style is applied during init, before anyone is listening.
        makeModel(defaults: defaults).0.nextBassStyleFromControl()
        let (model, _) = makeModel(defaults: defaults)
        let tiles = TileOutput()
        model.controlOutput = tiles.output
        model.start()
        XCTAssertEqual(tiles.saved.count, 1)
        XCTAssertEqual(tiles.saved.last?.isOn, false)
        XCTAssertEqual(tiles.saved.last?.bassName, BassStyle.transientPunch.compactTitle)
    }

    /// A drag changes the EQ on every frame, and none of that shows on a tile.
    func test_anEQDrag_doesNotRedrawTheTiles() {
        let (model, _) = makeModel()
        let tiles = TileOutput()
        model.controlOutput = tiles.output
        model.start()
        let redraws = tiles.redraws
        for i in 1 ... 30 {
            var d = model.dual
            d.fineTune.bands[0].gain = Double(i) / 10
            model.dual = d
        }
        XCTAssertEqual(tiles.redraws, redraws)
    }

    func test_audioFailingLater_turnsTheTileOff() async {
        let (model, engine) = makeModel()
        let tiles = TileOutput()
        model.controlOutput = tiles.output
        model.start()
        XCTAssertEqual(tiles.saved.last?.isOn, true)
        engine.status = .error("the audio stopped")
        let updated = await waitUntil { tiles.saved.last?.isOn == false }
        XCTAssertTrue(updated)
        engine.status = .idle
        let recovered = await waitUntil { tiles.saved.last?.isOn == true }
        XCTAssertTrue(recovered, "it has to keep watching after the first change")
    }

    func test_aFailedSave_isTriedAgain() {
        let (model, _) = makeModel()
        let tiles = TileOutput()
        tiles.saveWorks = false
        model.controlOutput = tiles.output
        model.start()
        XCTAssertEqual(tiles.redraws, 0, "nothing new to draw")
        tiles.saveWorks = true
        model.setPowered(true)              // same state, so only a retry would save it
        XCTAssertEqual(tiles.saved.last?.isOn, true)
        XCTAssertEqual(tiles.redraws, 1)
    }

    // MARK: A tile outliving the app

    func test_onIsOnlyPromisedForAWhile_andKeepsBeingRenewed() async {
        let (model, _) = makeModel()
        let tiles = TileOutput()
        model.controlLeaseRenewSeconds = 0.01
        model.controlOutput = tiles.output
        model.start()
        let first = tiles.saved.last?.onUntil
        XCTAssertNotNil(first)
        XCTAssertGreaterThan(first ?? .distantPast, Date())
        let renewed = await waitUntil { (tiles.saved.last?.onUntil ?? .distantPast) > (first ?? .distantFuture) }
        XCTAssertTrue(renewed)
        XCTAssertEqual(tiles.redraws, 1, "a renewal changes nothing on screen")
        model.setPowered(false)
    }

    /// An Off whose save failed must not be overwritten by the next renewal.
    func test_aRenewal_usesTheRealState() async {
        let (model, _) = makeModel()
        let tiles = TileOutput()
        model.controlLeaseRenewSeconds = 0.01
        model.controlOutput = tiles.output
        model.start()
        tiles.saveWorks = false
        model.setPowered(false)
        tiles.saveWorks = true
        let corrected = await waitUntil { tiles.saved.last?.isOn == false }
        XCTAssertTrue(corrected)
    }

    /// After a long call the tile has read as Off, and a quiet save wouldn't redraw it.
    func test_aRenewalAfterTheLeaseRanOut_redrawsTheTile() async {
        let (model, _) = makeModel()
        let tiles = TileOutput()
        var now = Date()
        model.wallClock = { now }
        model.controlLeaseRenewSeconds = 0.01
        model.controlOutput = tiles.output
        model.start()
        XCTAssertEqual(tiles.redraws, 1)
        now += EQControlState.leaseSeconds
        let redrawn = await waitUntil { tiles.redraws == 2 }
        XCTAssertTrue(redrawn)
        model.setPowered(false)
    }

    func test_turningOff_stopsTheRenewals() async throws {
        let (model, _) = makeModel()
        let tiles = TileOutput()
        model.controlLeaseRenewSeconds = 0.01
        model.controlOutput = tiles.output
        model.start()
        model.setPowered(false)
        XCTAssertNil(tiles.saved.last?.onUntil)
        let saves = tiles.saved.count
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(tiles.saved.count, saves)
    }

    func test_anOnThatWasNotRenewed_readsAsOff() {
        let store = EQControlStore(backing: FakeKeychain().backing)
        let now = Date()
        store.save(EQControlState(isOn: true, bassName: "Punch", bassSymbol: "waveform.path",
                                  onUntil: now.addingTimeInterval(10)))
        XCTAssertTrue(store.load(now: now).isOn)
        XCTAssertFalse(store.load(now: now.addingTimeInterval(10)).isOn, "the app may be gone")
        XCTAssertEqual(store.load(now: now.addingTimeInterval(10)).bassName, "Punch")
        store.save(EQControlState(isOn: true, bassName: "Punch", bassSymbol: "waveform.path"))
        XCTAssertFalse(store.load(now: now).isOn, "no promise at all is not On")
    }

    func test_theLease_outlastsAMissedRenewal() {
        XCTAssertGreaterThan(EQControlState.leaseSeconds, EQControlState.leaseRenewSeconds * 2)
    }

    // MARK: The shared state

    private final class FakeKeychain {
        var stored: Data?
        var updateFailure: OSStatus?
        var adds = 0
        var updates = 0

        var backing: EQControlStore.Backing {
            EQControlStore.Backing(
                read: { [self] in stored },
                update: { [self] data in
                    updates += 1
                    if let updateFailure { return updateFailure }
                    guard stored != nil else { return errSecItemNotFound }
                    stored = data
                    return errSecSuccess
                },
                add: { [self] data in
                    adds += 1
                    stored = data
                    return errSecSuccess
                })
        }
    }

    private let punch = EQControlState(isOn: false, bassName: "Punch", bassSymbol: "waveform.path")
    private let rumble = EQControlState(isOn: false, bassName: "Rumble", bassSymbol: "water.waves")

    func test_theStore_keepsWhatItWasGiven() {
        let store = EQControlStore(backing: FakeKeychain().backing)
        XCTAssertTrue(store.save(rumble))
        XCTAssertEqual(store.load(), rumble)
    }

    func test_theStore_addsOnce_thenUpdates() {
        let keychain = FakeKeychain()
        let store = EQControlStore(backing: keychain.backing)
        store.save(punch)
        store.save(rumble)
        XCTAssertEqual(keychain.adds, 1, "a second add would fail as a duplicate")
        XCTAssertEqual(store.load(), rumble)
    }

    /// A locked phone is not a missing item: adding would fail too, and it must not replace anything.
    func test_aLockedKeychain_isNotTreatedAsMissing() {
        let keychain = FakeKeychain()
        let store = EQControlStore(backing: keychain.backing)
        store.save(punch)
        keychain.updateFailure = errSecInteractionNotAllowed
        XCTAssertFalse(store.save(rumble), "the caller has to know it didn't save")
        XCTAssertEqual(keychain.adds, 1)
        XCTAssertEqual(store.load(), punch)
    }

    func test_aMissingOrDamagedState_showsThePlaceholder() {
        let keychain = FakeKeychain()
        let store = EQControlStore(backing: keychain.backing)
        XCTAssertEqual(store.load(), .placeholder)
        keychain.stored = Data([0xFF, 0x00, 0x12])
        XCTAssertEqual(store.load(), .placeholder)
        XCTAssertFalse(EQControlState.placeholder.isOn, "a tile must not claim On before the app has run")
    }

    /// Without a group the item would land in the app's first one: the link key's.
    func test_theKeychainItem_namesItsOwnGroup() {
        let query = EQControlStore.Backing.itemQuery(group: "the-group")
        XCTAssertEqual(query[kSecAttrAccessGroup as String] as? String, "the-group")
        XCTAssertEqual(query[kSecUseDataProtectionKeychain as String] as? Bool, true)
    }

    // MARK: The intents

    func test_thePowerIntent_reachesTheApp() async throws {
        let handler = ScriptedHandler()
        EQControlBridge.handler = handler
        defer { EQControlBridge.handler = nil }
        var intent = SetEQPowerIntent()
        intent.value = true
        _ = try await intent.perform()
        intent.value = false
        _ = try await intent.perform()
        XCTAssertEqual(handler.powerCalls.map(\.on), [true, false])
    }

    func test_theBassIntent_reachesTheApp() async throws {
        let handler = ScriptedHandler()
        EQControlBridge.handler = handler
        defer { EQControlBridge.handler = nil }
        _ = try await NextBassStyleIntent().perform()
        XCTAssertEqual(handler.bassSteps, 1)
    }

    func test_withNoApp_theIntentsFailInsteadOfDoingNothing() async {
        EQControlBridge.handler = nil
        var power = SetEQPowerIntent()
        power.value = true
        do {
            _ = try await power.perform()
            XCTFail("the power tile must report the failure")
        } catch {}
        do {
            _ = try await NextBassStyleIntent().perform()
            XCTFail("the bass tile must report the failure")
        } catch {}
    }

    /// In the tile extension there is no app to act on.
    func test_bothIntents_runOnlyInTheApp() {
        XCTAssertEqual(SetEQPowerIntent.allowedExecutionTargets, .main)
        XCTAssertEqual(NextBassStyleIntent.allowedExecutionTargets, .main)
        XCTAssertTrue((SetEQPowerIntent.self as Any.Type) is any AudioPlaybackIntent.Type)
        XCTAssertTrue((NextBassStyleIntent.self as Any.Type) is any AudioPlaybackIntent.Type)
    }

    /// Before the first unlock the app would load empty settings and could save them.
    func test_bothIntents_needAnUnlockedPhone() {
        XCTAssertEqual(SetEQPowerIntent.authenticationPolicy, .requiresLocalDeviceAuthentication)
        XCTAssertEqual(NextBassStyleIntent.authenticationPolicy, .requiresLocalDeviceAuthentication)
    }

    private func keychain(status: OSStatus) -> LinkKey.Store {
        LinkKey.Store(read: { (status, nil) }, add: { _ in errSecSuccess },
                      remove: { errSecSuccess }, random: { _ in nil })
    }

    func test_settingsCountAsLocked_onlyBeforeTheFirstUnlock() {
        XCTAssertTrue(LinkKey.settingsAreLocked(using: keychain(status: errSecInteractionNotAllowed)))
        XCTAssertFalse(LinkKey.settingsAreLocked(using: keychain(status: errSecSuccess)))
        XCTAssertFalse(LinkKey.settingsAreLocked(using: keychain(status: errSecItemNotFound)))
    }

    /// A model built from unreadable settings would later save them as empty.
    func test_theAppNeverBuildsAModel_fromLockedSettings() throws {
        let app = try source("App/EQtargetsIOSApp.swift")
        let guardLine = try XCTUnwrap(app.range(of: "if LinkKey.settingsAreLocked() { exit(0) }")).lowerBound
        let firstModel = try XCTUnwrap(app.range(of: "AppModel(engine:")).lowerBound
        XCTAssertLessThan(guardLine, firstModel)
    }

    func test_onlyThePowerTile_mayOpenTheApp() {
        XCTAssertEqual(SetEQPowerIntent.supportedModes, [.background, .foreground(.dynamic)])
        XCTAssertEqual(NextBassStyleIntent.supportedModes, .background)
    }

    // MARK: Build setup

    private var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
    }

    private func plist(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: sourcesRoot.appendingPathComponent(path))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: sourcesRoot.appendingPathComponent(path), encoding: .utf8)
    }

    private let tileGroup = "$(AppIdentifierPrefix)com.eqtargets.ios.controls"
    private let linkGroup = "$(AppIdentifierPrefix)com.eqtargets.ios.link"

    func test_theAppAndTheTilesShareOneGroup() throws {
        let key = "keychain-access-groups"
        XCTAssertEqual(try plist("App/EQtargets.entitlements")[key] as? [String], [linkGroup, tileGroup])
        XCTAssertEqual(try plist("App/Info.plist")["EQTControlsKeychainGroup"] as? String, tileGroup)
        XCTAssertEqual(try plist("Controls/Info.plist")["EQTControlsKeychainGroup"] as? String, tileGroup)
    }

    /// The tile extension has no business holding the key that protects the audio link.
    func test_theTilesCannotReadTheLinkKey() throws {
        XCTAssertEqual(try plist("Controls/Controls.entitlements")["keychain-access-groups"] as? [String], [tileGroup])
    }

    func test_addingTheGroup_leftTheAudioEntitlementsAlone() throws {
        let app = try plist("App/EQtargets.entitlements")
        XCTAssertEqual(app["com.apple.developer.media-device-extension"] as? [String], [],
                       "any value here stops the app opening an audio session")
        XCTAssertEqual(try plist("Extension/Extension.entitlements")["keychain-access-groups"] as? [String], [linkGroup])
    }

    func test_theTileExtension_isAWidgetExtension() throws {
        let info = try XCTUnwrap(plist("Controls/Info.plist")["NSExtension"] as? [String: Any])
        XCTAssertEqual(info["NSExtensionPointIdentifier"] as? String, "com.apple.widgetkit-extension")
    }

    /// These live in files the test target can't compile: the app's entry point and the widget.
    func test_theAppConnectsTheTiles_beforeAnyWindow() throws {
        let app = try source("App/EQtargetsIOSApp.swift")
        let initBody = try XCTUnwrap(app.range(of: "init() {")).upperBound
        let bodyStart = try XCTUnwrap(app.range(of: "var body: some Scene")).lowerBound
        XCTAssertTrue(app[initBody ..< bodyStart].contains("Self.connectControls(to: model)"))
        XCTAssertTrue(app.contains("EQControlBridge.handler = model"))
        XCTAssertTrue(app.contains("model.controlOutput = "))
    }

    func test_eachTile_usesItsOwnKindAndIntent() throws {
        let tiles = try source("Controls/EQControls.swift")
        let power = try XCTUnwrap(tiles.range(of: "struct EQPowerControl")).lowerBound
        let bass = try XCTUnwrap(tiles.range(of: "struct EQBassControl")).lowerBound
        XCTAssertLessThan(power, bass)
        let powerTile = tiles[power ..< bass], bassTile = tiles[bass...]
        XCTAssertTrue(powerTile.contains("EQControlID.powerKind"))
        XCTAssertTrue(powerTile.contains("SetEQPowerIntent()"))
        XCTAssertTrue(bassTile.contains("EQControlID.bassKind"))
        XCTAssertTrue(bassTile.contains("NextBassStyleIntent()"))
    }

    /// iOS can connect the scene in the background during a tile's launch.
    func test_onlyARealOpening_startsTheEngine() throws {
        let app = try source("App/EQtargetsIOSApp.swift")
        XCTAssertTrue(app.contains("guard phase != .background, !didStart else { return }"))
        XCTAssertFalse(app.contains(".task {"), "a task would also run in a background-connected scene")
    }
}
