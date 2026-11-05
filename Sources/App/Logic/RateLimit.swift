//
//  RateLimit.swift
//  EQtargets (macOS)
//
//  Decision core of the parameter throttle. `EngineController.apply` is
//  contract-limited to ≤ 60 Hz, but a node drag on a 120 Hz ProMotion trackpad
//  delivers ~120 events/s. The gate passes the first change immediately (no
//  added latency when you start a drag), then at most one per interval, and
//  ALWAYS delivers a trailing update so the final resting value is never lost.
//
//  Pure value type with an injected clock, so the self-test can drive it with
//  synthetic timestamps.
//

import Foundation

struct ThrottleGate {
    enum Action: Equatable {
        /// Send now.
        case fire
        /// Schedule a trailing send after this many seconds.
        case schedule(after: TimeInterval)
        /// A trailing send is already scheduled; it will pick up the latest value.
        case coalesce
    }

    let interval: TimeInterval
    private(set) var lastFire: TimeInterval = -.infinity
    private(set) var trailingPending = false

    init(interval: TimeInterval) { self.interval = interval }

    mutating func offer(now: TimeInterval) -> Action {
        if trailingPending { return .coalesce }
        let elapsed = now - lastFire
        if elapsed >= interval {
            lastFire = now
            return .fire
        }
        trailingPending = true
        return .schedule(after: interval - elapsed)
    }

    /// Call when the scheduled trailing send ran.
    mutating func trailingFired(now: TimeInterval) {
        trailingPending = false
        lastFire = now
    }
}
