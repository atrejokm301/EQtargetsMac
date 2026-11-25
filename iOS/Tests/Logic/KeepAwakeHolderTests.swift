//
//  KeepAwakeHolderTests.swift
//  EQtargets (iOS)
//
//  The background-task wiring, with UIApplication replaced by a fake: one task
//  at a time, each ended exactly once, and no asking again in a loop.
//

import UIKit
import XCTest

@MainActor
final class KeepAwakeHolderTests: XCTestCase {

    /// Stands in for UIApplication's begin/end.
    private final class FakeTasks {
        var refuse = false
        /// iOS ends the task before `begin` returns.
        var expireDuringBegin = false
        /// Notes and ends in the order they happened.
        var order: [String] = []
        var nextID = 1
        var begun: [UIBackgroundTaskIdentifier] = []
        var ended: [UIBackgroundTaskIdentifier] = []
        var expiry: (() -> Void)?

        var open: Int { begun.count - ended.count }

        func begin(_ expired: @escaping () -> Void) -> UIBackgroundTaskIdentifier {
            guard !refuse else { return .invalid }
            let id = UIBackgroundTaskIdentifier(rawValue: nextID)
            nextID += 1
            begun.append(id)
            expiry = expired
            if expireDuringBegin { expired() }
            return id
        }
    }

    private var tasks: FakeTasks!
    private var notes: [String] = []
    private var holder: KeepAwakeHolder!

    override func setUp() async throws {
        tasks = FakeTasks()
        notes = []
        let tasks = tasks!
        holder = KeepAwakeHolder(begin: { tasks.begin($0) },
                                 end: { tasks.ended.append($0); tasks.order.append("end") },
                                 note: { [weak self] in self?.notes.append($0); tasks.order.append("note") })
    }

    @discardableResult
    private func update(live: Bool = true, interrupted: Bool = false, running: Bool,
                        foreground: Bool = false, now: TimeInterval) -> Bool {
        holder.update(live: live, interrupted: interrupted, engineRunning: running,
                      foreground: foreground, now: now)
    }

    func test_engineDown_takesOneTask_andEndsItWhenTheAudioIsBack() {
        XCTAssertTrue(update(running: false, now: 0), "the caller must speed up its tick")
        XCTAssertTrue(holder.isHeld)
        XCTAssertFalse(update(running: false, now: 1), "already held: no second task")
        XCTAssertFalse(update(running: false, now: 2))
        XCTAssertEqual(tasks.begun.count, 1)

        XCTAssertTrue(update(running: true, now: 3))
        XCTAssertFalse(holder.isHeld)
        XCTAssertEqual(tasks.ended, tasks.begun, "every task ended exactly once")
        XCTAssertEqual(tasks.open, 0)
    }

    func test_headphoneChange_holdsForTheWatch_thenReleases() {
        holder.routeChanged(now: 0, causedByApp: false)
        update(running: true, now: 0)
        XCTAssertTrue(holder.isHeld)
        update(running: true, now: KeepAwakeRule.routeWatchSeconds + 0.25)
        XCTAssertFalse(holder.isHeld)
        XCTAssertEqual(tasks.open, 0)
    }

    func test_iOSEndsTheTask_itIsEnded_andNotAskedForAgainInALoop() {
        var expiredCalls = 0
        holder.onExpired = { expiredCalls += 1 }
        update(running: false, now: 0)
        tasks.expiry?()                         // iOS's expiry handler
        XCTAssertEqual(tasks.ended, tasks.begun, "the expiry handler must end the task")
        XCTAssertFalse(holder.isHeld)
        XCTAssertEqual(expiredCalls, 1, "the engine slows its tick again")

        for t in 1 ... 20 { update(running: false, now: TimeInterval(t)) }
        XCTAssertEqual(tasks.begun.count, 1, "no begin/expire loop")
        XCTAssertTrue(notes.contains { $0.hasPrefix("iOS ended the keep-awake time") })
    }

    func test_iOSRefusesTheTask_doesNotAskOnEveryUpdate() {
        tasks.refuse = true
        XCTAssertFalse(update(running: false, now: 0))
        XCTAssertFalse(holder.isHeld)
        tasks.refuse = false
        for t in 1 ... 10 { update(running: false, now: TimeInterval(t)) }
        XCTAssertTrue(tasks.begun.isEmpty, "a refusal counts like an expiry")
        XCTAssertEqual(notes.filter { $0.hasPrefix("iOS refused") }.count, 1, "noted once")

        holder.routeChanged(now: 11, causedByApp: false)
        update(running: false, now: 11)
        XCTAssertTrue(holder.isHeld, "a new headphone change tries again")
    }

    func test_expiryBeforeBeginReturns_endsThatTask_andDoesNotHoldIt() {
        tasks.expireDuringBegin = true
        XCTAssertFalse(update(running: false, now: 0))
        XCTAssertFalse(holder.isHeld)
        XCTAssertEqual(tasks.ended, tasks.begun, "a task iOS already ended must still be ended once")
        tasks.expireDuringBegin = false
        update(running: false, now: 1)
        XCTAssertEqual(tasks.begun.count, 1, "counts as an expiry: no loop")
    }

    func test_release_writesTheNoteBeforeEndingTheTask() {
        update(running: false, now: 0)
        tasks.order.removeAll()
        tasks.expiry?()
        XCTAssertEqual(tasks.order, ["note", "end"], "after the end the app may already be suspended")
    }

    func test_off_releasesAHeldTask_andNeverTakesOne() {
        update(running: false, now: 0)
        XCTAssertTrue(update(live: false, running: false, now: 1))
        XCTAssertFalse(holder.isHeld)
        holder.routeChanged(now: 2, causedByApp: false)
        update(live: false, running: false, now: 2)
        XCTAssertFalse(holder.isHeld, "Off lets iOS suspend the app")
        XCTAssertEqual(tasks.open, 0)
    }

    func test_lateExpiryForAnEndedTask_changesNothing() {
        update(running: false, now: 0)
        let stale = tasks.expiry
        update(running: true, now: 1)
        stale?()                                // a late handler for the task already ended
        XCTAssertEqual(tasks.ended.count, 1, "nothing ended twice")
        XCTAssertFalse(holder.rule.exhausted, "a late handler must not block the next switch")
        update(running: false, now: 2)
        XCTAssertTrue(holder.isHeld)
    }

    func test_lateExpiryForAnOldTask_leavesTheNewerTaskHeld() {
        update(running: false, now: 0)
        let stale = tasks.expiry
        update(running: true, now: 1)
        update(running: false, now: 2)          // a second task
        stale?()
        XCTAssertTrue(holder.isHeld, "only its own task's handler may end it")
        XCTAssertEqual(tasks.open, 1)
    }
}
