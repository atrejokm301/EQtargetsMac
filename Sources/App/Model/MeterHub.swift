//
//  MeterHub.swift
//  EQtargets (macOS)
//
//  The ONE place that calls `engine.meters()`.
//
//  WHY a hub instead of each meter view polling: `ChainMeters` peaks are
//  take-on-read ("since the last meters() call"). Two independent pollers (the
//  inspector meter and the menu-bar popover meter, say) would each see only the
//  peaks the other one didn't take, and both would under-read. One poller fans
//  the same values out to every consumer.
//
//  Polling is demand-driven and stops completely when nobody visible needs it
//  (DESIGN §8.2, QA B-2: zero wakeups with the window hidden):
//  • `.activity` — a visible Punch/Rumble meter while the engine is running:
//    30 Hz (the contract maximum), feeds the meter ballistics.
//  • `.status` — a visible window/popover while running: 5 Hz, enough to catch
//    the lifetime `overCount` moving for the Limiting / Clipping chips.
//  Consumers hold a lease for exactly as long as their `.task(id:)` lives, so
//  SwiftUI's own task cancellation (view hidden, condition false) ends polling.
//

import Foundation
import Observation

@MainActor
@Observable
final class MeterHub {
    enum Demand: Hashable { case activity, status }

    private(set) var activity = MeterBallistics(intervalSeconds: MeterHub.activityInterval)
    private(set) var chip: StatusChipTracker.Chip?
    /// How far the output went over while Limiting / Clipping shows (dB, else
    /// 0): drives the chip's "Lower Preamp" fix. See `StatusChipTracker`.
    private(set) var recentOverDB: Double = 0

    static let activityInterval: TimeInterval = 1.0 / 30
    static let statusInterval: TimeInterval = 0.2

    @ObservationIgnored var read: () -> ChainMeters = { ChainMeters() }
    @ObservationIgnored var readUnderruns: () -> Int = { 0 }
    @ObservationIgnored var protectionOn: () -> Bool = { true }
    /// Snapshot mode: values are seeded and must not be polled away.
    @ObservationIgnored var frozen = false
    /// Number of `meters()` calls so far (self-test / diagnostics of B-2).
    @ObservationIgnored private(set) var pollCount = 0

    @ObservationIgnored private var leases: [Int: Demand] = [:]
    @ObservationIgnored private var nextLease = 0
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var tracker = StatusChipTracker()
    @ObservationIgnored private var lastTick: TimeInterval = 0

    var isPolling: Bool { loop != nil }
    var wantsActivity: Bool { leases.values.contains(.activity) }

    /// Holds a lease until the calling task is cancelled. Use inside `.task(id:)`.
    func hold(_ demand: Demand) async {
        let id = acquire(demand)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
        }
        release(id)
    }

    func acquire(_ demand: Demand) -> Int {
        nextLease += 1
        leases[nextLease] = demand
        updateLoop()
        return nextLease
    }

    func release(_ id: Int) {
        leases[id] = nil
        updateLoop()
    }

    /// Snapshot / preview seeding.
    func seed(boostDB: Double, trimDB: Double, chip: StatusChipTracker.Chip? = nil, overDB: Double = 0) {
        activity.set(boostDB: boostDB, trimDB: trimDB)
        self.chip = chip
        recentOverDB = overDB
    }

    // MARK: Loop

    private func updateLoop() {
        guard !frozen else { return }
        if !wantsActivity, !activity.isIdle { activity.reset() }
        if leases.isEmpty {
            loop?.cancel()
            loop = nil
            tracker.reset()
            if chip != nil { chip = nil }
            if recentOverDB != 0 { recentOverDB = 0 }
            return
        }
        guard loop == nil else { return }
        lastTick = ProcessInfo.processInfo.systemUptime
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let interval = (self?.wantsActivity ?? false) ? MeterHub.activityInterval : MeterHub.statusInterval
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { return }
                self.tick(now: ProcessInfo.processInfo.systemUptime)
            }
        }
    }

    func tick(now: TimeInterval) {
        pollCount += 1
        let m = read()
        if wantsActivity {
            activity.feed(boostDB: m.punchBoostDB, trimDB: m.punchTrimDB, elapsed: now - lastTick)
        }
        lastTick = now
        tracker.observe(meters: m, underruns: readUnderruns(), protectionOn: protectionOn(), now: now)
        let c = tracker.chip(now: now)
        if c != chip { chip = c }
        let over = tracker.overDB(now: now)
        if over != recentOverDB { recentOverDB = over }
    }
}
