//
//  KeepAwakeHolder.swift
//  EQtargets (iOS)
//
//  Owns the one background task that `KeepAwakeRule` asks for. Begin and end are
//  injected so the logic tests can prove the pairing: at most one task, every
//  task ended exactly once, and no asking again in a loop after iOS ends or
//  refuses one.
//

import UIKit

@MainActor
final class KeepAwakeHolder {

    /// Starts a task. The closure runs if iOS ends it early.
    typealias Begin = (_ expired: @escaping () -> Void) -> UIBackgroundTaskIdentifier
    typealias End = (UIBackgroundTaskIdentifier) -> Void

    private(set) var rule = KeepAwakeRule()
    private(set) var task = UIBackgroundTaskIdentifier.invalid
    /// Which task an expiry handler belongs to: a late one must not end a newer task.
    private var generation = 0
    /// An expiry that arrives before `begin` has returned the task's identifier.
    private var beginning = false
    private var expiredWhileBeginning = false
    private let begin: Begin
    private let end: End
    private let note: (String) -> Void
    /// Called when iOS ends the task, which happens outside `update`.
    var onExpired: (() -> Void)?

    var isHeld: Bool { task != .invalid }

    init(begin: @escaping Begin, end: @escaping End, note: @escaping (String) -> Void) {
        self.begin = begin
        self.end = end
        self.note = note
    }

    static func live(note: @escaping (String) -> Void) -> KeepAwakeHolder {
        KeepAwakeHolder(
            begin: { expired in
                UIApplication.shared.beginBackgroundTask(withName: "EQtargets route change") {
                    MainActor.assumeIsolated { expired() }
                }
            },
            end: { UIApplication.shared.endBackgroundTask($0) },
            note: note)
    }

    func routeChanged(now: TimeInterval, causedByApp: Bool) {
        rule.routeChanged(now: now, causedByApp: causedByApp)
    }

    /// Returns true when the task was taken or let go, so the caller can
    /// change its tick rate.
    @discardableResult
    func update(live: Bool, interrupted: Bool, engineRunning: Bool,
                foreground: Bool, now: TimeInterval) -> Bool {
        let wants = rule.evaluate(live: live, interrupted: interrupted, engineRunning: engineRunning,
                                  foreground: foreground, now: now)
        let audio = engineRunning ? "running" : "down"
        if wants, task == .invalid {
            generation &+= 1
            let mine = generation
            beginning = true
            expiredWhileBeginning = false
            let id = begin { [weak self] in self?.expired(mine) }
            beginning = false
            guard id != .invalid else {
                // No background time left. Same as an expiry: don't ask again
                // on every status update.
                rule.taskExpired()
                note("iOS refused the keep-awake time, audio \(audio)")
                return false
            }
            guard !expiredWhileBeginning else {
                rule.taskExpired()
                note("iOS ended the keep-awake time at once, audio \(audio)")
                end(id)
                return false
            }
            task = id
            note("keeping the app awake, audio \(audio)")
            return true
        }
        if !wants, task != .invalid {
            release("released the keep-awake, audio \(audio)")
            return true
        }
        return false
    }

    /// iOS's expiry handler. The app may be suspended right after it returns,
    /// so the task must be ended here.
    private func expired(_ which: Int) {
        guard which == generation else { return }
        if beginning {
            expiredWhileBeginning = true
            return
        }
        guard task != .invalid else { return }
        rule.taskExpired()
        release("iOS ended the keep-awake time")
        onExpired?()
    }

    private func release(_ event: String) {
        guard task != .invalid else { return }
        // Noted first: on the expiry path the app may be suspended right after the end.
        note(event)
        end(task)
        task = .invalid
    }
}
