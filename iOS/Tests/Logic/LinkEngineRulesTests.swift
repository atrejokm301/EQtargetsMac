//
//  LinkEngineRulesTests.swift
//  EQtargets (iOS)
//

import XCTest

final class LinkEngineRulesTests: XCTestCase {

    private func status(powered: Bool = true, passThrough: Bool = false, running: Bool = true,
                        failure: String? = nil, interrupted: Bool = false, feedback: Bool = false,
                        peer: Bool = true, sinceAudio: TimeInterval = 0) -> EngineStatus {
        LinkStatusRule.status(isPowered: powered, passThrough: passThrough, engineRunning: running,
                              failure: failure, interrupted: interrupted, feedback: feedback,
                              hasPeer: peer, secondsSinceAudio: sinceAudio)
    }

    func test_status_passThroughNeverHidesAFailure() {
        XCTAssertEqual(status(powered: false, passThrough: true, failure: "x"), .error("x"))
        XCTAssertEqual(status(powered: false, passThrough: true, interrupted: true), .interrupted)
        XCTAssertEqual(status(powered: false, passThrough: true, running: false), .starting)
        XCTAssertEqual(status(powered: false, passThrough: true, feedback: true), .feedbackGuard)
    }

    func test_status_turnedOffWhileSelected_reportsPassThrough_notOff() {
        XCTAssertEqual(status(powered: false, passThrough: true), .passThrough)
        XCTAssertEqual(status(powered: false, passThrough: false), .off)
        XCTAssertEqual(status(powered: true, passThrough: true, sinceAudio: 0.1), .running,
                       "powering back on returns to normal")
    }

    // MARK: Power: the phone must never go silent because of this app

    func test_power_offWithNoPeer_stopsTheEngine() {
        var p = LinkPowerState()
        XCTAssertEqual(p.setPowered(true, hasPeer: false), .startEngine)
        XCTAssertEqual(p.setPowered(false, hasPeer: false), .stopEngine)
        XCTAssertFalse(p.isLive)
    }

    func test_power_offWhileSelected_bypassesInsteadOfSilencingThePhone() {
        var p = LinkPowerState()
        _ = p.setPowered(true, hasPeer: true)
        XCTAssertEqual(p.setPowered(false, hasPeer: true), .updateBypass)
        XCTAssertTrue(p.passThrough)
        XCTAssertTrue(p.isLive, "the engine must keep playing")
    }

    func test_power_onFromPassThrough_restoresTheEQWithoutRestartingAudio() {
        var p = LinkPowerState()
        _ = p.setPowered(true, hasPeer: true)
        _ = p.setPowered(false, hasPeer: true)
        XCTAssertEqual(p.setPowered(true, hasPeer: true), .updateBypass)
        XCTAssertFalse(p.passThrough)
        XCTAssertTrue(p.isPowered)
    }

    func test_power_passThroughStops_onlyAfterThePeerStaysGone() {
        var p = LinkPowerState()
        _ = p.setPowered(true, hasPeer: true)
        _ = p.setPowered(false, hasPeer: true)
        XCTAssertEqual(p.observe(hasPeer: true, secondsSincePeer: 0), .none)
        XCTAssertEqual(p.observe(hasPeer: false, secondsSincePeer: 1), .none, "a brief reconnect")
        XCTAssertEqual(p.observe(hasPeer: false, secondsSincePeer: 2), .stopEngine)
        XCTAssertFalse(p.isLive)
    }

    func test_power_pickingEQtargetsWhileOff_startsAudioInPassThrough() {
        var p = LinkPowerState()
        XCTAssertEqual(p.observe(hasPeer: false, secondsSincePeer: .infinity), .none)
        XCTAssertEqual(p.observe(hasPeer: true, secondsSincePeer: 0), .startEngine)
        XCTAssertTrue(p.passThrough)
        XCTAssertFalse(p.isPowered, "Off stays Off: the EQ is bypassed")
    }

    func test_power_whileOn_aPeerComingAndGoingChangesNothing() {
        var p = LinkPowerState()
        _ = p.setPowered(true, hasPeer: false)
        XCTAssertEqual(p.observe(hasPeer: true, secondsSincePeer: 0), .none)
        XCTAssertEqual(p.observe(hasPeer: false, secondsSincePeer: 60), .none)
        XCTAssertTrue(p.isPowered)
    }

    func test_power_repeatingTheSameValue_isANoOp() {
        var p = LinkPowerState()
        XCTAssertEqual(p.setPowered(false, hasPeer: true), .none)
        _ = p.setPowered(true, hasPeer: false)
        XCTAssertEqual(p.setPowered(true, hasPeer: false), .none)
    }

    func test_status_followsTheLifecycle() {
        XCTAssertEqual(status(powered: false), .off)
        XCTAssertEqual(status(running: false), .starting)
        XCTAssertEqual(status(peer: false), .waiting)
        XCTAssertEqual(status(sinceAudio: 10), .idle)
        XCTAssertEqual(status(sinceAudio: 0.1), .running)
    }

    func test_status_failureAndSafetyStates_areNeverHiddenByRunning() {
        XCTAssertEqual(status(failure: "x"), .error("x"))
        XCTAssertEqual(status(interrupted: true), .interrupted)
        XCTAssertEqual(status(feedback: true), .feedbackGuard)
        XCTAssertEqual(status(failure: "x", interrupted: true, feedback: true), .error("x"))
    }

    func test_status_offWins_evenWithAStaleFailure() {
        XCTAssertEqual(status(powered: false, failure: "x"), .off)
    }

    func test_ownRoute_matchesOurName_only() {
        XCTAssertTrue(LinkRoute.isOwnRoute(portName: "EQtargets"))
        XCTAssertTrue(LinkRoute.isOwnRoute(portName: "eqtargets audio"))
        XCTAssertFalse(LinkRoute.isOwnRoute(portName: "AirPods Max"))
        XCTAssertFalse(LinkRoute.isOwnRoute(portName: "Speaker"))
    }

    func test_realOutput_skipsOurOwnDevice() {
        XCTAssertEqual(LinkRoute.realOutput(names: ["EQtargets", "Speaker"]), 1)
        XCTAssertEqual(LinkRoute.realOutput(names: ["AirPods Max"]), 0)
        XCTAssertNil(LinkRoute.realOutput(names: ["EQtargets"]))
        XCTAssertNil(LinkRoute.realOutput(names: []))
    }

    func test_rateWatch_needsThreeTicksAndASettledStart() {
        var w = RateChangeWatch()
        XCTAssertFalse(w.observe(builtRate: 48_000, hardwareRate: 44_100, now: 10, lastStart: 0))
        XCTAssertFalse(w.observe(builtRate: 48_000, hardwareRate: 44_100, now: 10.25, lastStart: 0))
        XCTAssertTrue(w.observe(builtRate: 48_000, hardwareRate: 44_100, now: 10.5, lastStart: 0))
        XCTAssertEqual(w.mismatchTicks, 0)
    }

    func test_rateWatch_oneGoodReadingResetsTheCount() {
        var w = RateChangeWatch()
        _ = w.observe(builtRate: 48_000, hardwareRate: 44_100, now: 10, lastStart: 0)
        _ = w.observe(builtRate: 48_000, hardwareRate: 44_100, now: 10.2, lastStart: 0)
        _ = w.observe(builtRate: 48_000, hardwareRate: 48_000, now: 10.4, lastStart: 0)
        XCTAssertFalse(w.observe(builtRate: 48_000, hardwareRate: 44_100, now: 10.6, lastStart: 0))
    }

    func test_rateWatch_waitsForTheRateToSettleAfterAStart() {
        var w = RateChangeWatch()
        for i in 0 ..< 3 {
            XCTAssertFalse(w.observe(builtRate: 48_000, hardwareRate: 44_100, now: 10 + Double(i) * 0.1, lastStart: 10))
        }
        XCTAssertTrue(w.observe(builtRate: 48_000, hardwareRate: 44_100, now: 11.1, lastStart: 10))
    }

    func test_rateWatch_ignoresAnUnknownHardwareRate() {
        var w = RateChangeWatch()
        for i in 0 ..< 6 {
            XCTAssertFalse(w.observe(builtRate: 48_000, hardwareRate: 0, now: 10 + Double(i), lastStart: 0))
        }
    }

    func test_escape_retriesThenGivesUp() {
        var e = FeedbackEscape()
        XCTAssertEqual(e.decide(onOwnRoute: true, onSpeaker: false, now: 0), .overrideToSpeaker)
        XCTAssertNil(e.decide(onOwnRoute: true, onSpeaker: false, now: 1), "too soon to retry")
        XCTAssertEqual(e.decide(onOwnRoute: true, onSpeaker: false, now: 3), .overrideToSpeaker)
        XCTAssertEqual(e.decide(onOwnRoute: true, onSpeaker: false, now: 6), .overrideToSpeaker)
        XCTAssertNil(e.decide(onOwnRoute: true, onSpeaker: false, now: 60), "repeating breaks the media session")
    }

    func test_escape_keepsTheOverrideWhileOnTheSpeaker_thenClearsIt() {
        var e = FeedbackEscape()
        _ = e.decide(onOwnRoute: true, onSpeaker: false, now: 0)
        XCTAssertNil(e.decide(onOwnRoute: false, onSpeaker: true, now: 1))
        XCTAssertEqual(e.decide(onOwnRoute: false, onSpeaker: false, now: 2), .clearOverride)
        XCTAssertFalse(e.overriding)
        XCTAssertEqual(e.attempts, 0)
    }

    func test_escape_doesNothingOnANormalRoute() {
        var e = FeedbackEscape()
        XCTAssertNil(e.decide(onOwnRoute: false, onSpeaker: true, now: 0))
        XCTAssertNil(e.decide(onOwnRoute: false, onSpeaker: false, now: 1))
    }

    // MARK: Keep awake: a headphone switch must not let iOS suspend the app

    private let watch = KeepAwakeRule.routeWatchSeconds

    private func wants(_ k: inout KeepAwakeRule, live: Bool = true, interrupted: Bool = false,
                       running: Bool, foreground: Bool = false, now: TimeInterval) -> Bool {
        k.evaluate(live: live, interrupted: interrupted, engineRunning: running,
                   foreground: foreground, now: now)
    }

    func test_keepAwake_engineDownWhileLive_holdsTheAppAwakeUntilItRunsAgain() {
        var k = KeepAwakeRule()
        XCTAssertTrue(wants(&k, running: false, now: 100), "a suspended app leaves the extension unanswered")
        XCTAssertTrue(wants(&k, running: false, now: 120))
        XCTAssertFalse(wants(&k, running: true, now: 121), "released once the audio is back")
    }

    func test_keepAwake_afterHeadphoneChange_holdsForTheWatchEvenWhilePlaying() {
        var k = KeepAwakeRule()
        k.routeChanged(now: 10, causedByApp: false)
        XCTAssertTrue(wants(&k, running: true, now: 10), "the engine can stop a moment after the change")
        XCTAssertTrue(wants(&k, running: true, now: 10 + watch - 0.01))
        XCTAssertFalse(wants(&k, running: true, now: 10 + watch), "the watch ends on time")
    }

    func test_keepAwake_watchOutlastsTheInterruptionRetry() {
        XCTAssertGreaterThan(KeepAwakeRule.routeWatchSeconds, InterruptionRetry.seconds,
                             "a switch that comes with an interruption must still be covered at the retry")
    }

    func test_keepAwake_settledAndPlaying_orOff_neverHoldsATask() {
        var k = KeepAwakeRule()
        XCTAssertFalse(wants(&k, running: true, now: 0), "normal playback costs nothing extra")
        XCTAssertFalse(wants(&k, live: false, running: false, now: 0), "Off must let iOS suspend the app")
        k.routeChanged(now: 0, causedByApp: false)
        XCTAssertFalse(wants(&k, live: false, running: false, now: 1), "a route change while Off changes nothing")
    }

    func test_keepAwake_duringACall_waitsForIOSUnlessARouteJustChanged() {
        var k = KeepAwakeRule()
        XCTAssertFalse(wants(&k, interrupted: true, running: false, now: 0))
        k.routeChanged(now: 50, causedByApp: false)
        XCTAssertTrue(wants(&k, interrupted: true, running: false, now: 51))
        XCTAssertFalse(wants(&k, interrupted: true, running: false, now: 50 + watch + 1))
    }

    func test_keepAwake_afterIOSEndsTheTask_doesNotAskAgainInALoop() {
        var k = KeepAwakeRule()
        XCTAssertTrue(wants(&k, running: false, now: 0))
        k.taskExpired()
        XCTAssertFalse(wants(&k, running: false, now: 30), "asking again at once would loop")
        XCTAssertFalse(wants(&k, running: false, now: 60))
        XCTAssertTrue(k.exhausted)
    }

    func test_keepAwake_afterExpiry_aNewHeadphoneChangeOrOpeningTheAppTriesAgain() {
        var k = KeepAwakeRule()
        k.taskExpired()
        XCTAssertFalse(wants(&k, running: false, now: 0))
        k.routeChanged(now: 1, causedByApp: false)
        XCTAssertTrue(wants(&k, running: false, now: 1), "a new switch deserves a new try")

        k.taskExpired()
        XCTAssertFalse(wants(&k, running: false, now: 2))
        XCTAssertTrue(wants(&k, running: false, foreground: true, now: 3), "the user opened the app")
    }

    func test_keepAwake_routeChangesTheAppCausedItself_neitherRearmNorWatch() {
        var k = KeepAwakeRule()
        k.taskExpired()
        k.routeChanged(now: 0, causedByApp: true)       // its own override or category change
        XCTAssertTrue(k.exhausted, "the app's own restarts must not loop the task")
        XCTAssertFalse(wants(&k, running: false, now: 0))

        var fresh = KeepAwakeRule()
        fresh.routeChanged(now: 0, causedByApp: true)
        XCTAssertFalse(wants(&fresh, running: true, now: 1), "no watch for the app's own change")
    }

    func test_keepAwake_expiryDuringTheWatchWhilePlaying_staysQuietThenRearms() {
        var k = KeepAwakeRule()
        k.routeChanged(now: 0, causedByApp: false)
        XCTAssertTrue(wants(&k, running: true, now: 0))
        k.taskExpired()                         // iOS had little background time left
        XCTAssertFalse(wants(&k, running: true, now: 1), "no begin/expire loop inside the watch")
        XCTAssertFalse(wants(&k, running: true, now: watch + 1), "watch over, nothing needed")
        XCTAssertFalse(k.exhausted, "re-armed once nothing needs the task")
        XCTAssertTrue(wants(&k, running: false, now: watch + 2), "a later stop is covered again")
    }

    // MARK: Tick gaps: telling a suspension apart in the journal

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// A tick where the uptime and wall clocks moved together.
    private func tick(_ g: inout TickGapWatch, _ seconds: TimeInterval, live: Bool = true) -> TickGapWatch.Gap? {
        g.tick(now: seconds, date: t0 + seconds, live: live)
    }

    func test_tickGap_aLongGapWhileLive_isReportedWithItsStart() {
        var g = TickGapWatch()
        XCTAssertNil(tick(&g, 0))
        XCTAssertNil(tick(&g, 1))
        let gap = tick(&g, 12.5)
        XCTAssertEqual(gap?.awakeSeconds ?? -1, 11.5, accuracy: 1e-9)
        XCTAssertEqual(gap?.clockSeconds ?? -1, 11.5, accuracy: 1e-9)
        XCTAssertEqual(gap?.since, t0 + 1, "when the last tick ran, to line up with the route change")
        XCTAssertNil(tick(&g, 13), "reported once")
    }

    func test_tickGap_whileThePhoneSlept_isSeenOnTheWallClock() {
        var g = TickGapWatch()
        _ = g.tick(now: 100, date: t0, live: true)
        // Suspended, then asleep for an hour: uptime barely moved.
        let gap = g.tick(now: 101, date: t0 + 3_600, live: true)
        XCTAssertNotNil(gap, "a suspension spent asleep must still show")
        XCTAssertEqual(gap?.awakeSeconds ?? -1, 1, accuracy: 1e-9)
        XCTAssertEqual(gap?.clockSeconds ?? -1, 3_600, accuracy: 1e-9)
        XCTAssertEqual(gap?.since, t0)
    }

    func test_tickGap_atTheThreshold_isNotReported() {
        var g = TickGapWatch()
        _ = tick(&g, 0)
        XCTAssertNil(tick(&g, TickGapWatch.reportSeconds))
    }

    func test_tickGap_afterTheTimerStoppedOnPurpose_isNotASuspension() {
        var g = TickGapWatch()
        _ = tick(&g, 0)
        g.timerStopped()                        // Off in the background
        XCTAssertNil(tick(&g, 600))
    }

    func test_tickGap_whenThePreviousTickWasNotLive_isNotReported() {
        var g = TickGapWatch()
        _ = tick(&g, 0, live: false)            // Off in the foreground: the timer may slow
        XCTAssertNil(tick(&g, 30))
    }
}
