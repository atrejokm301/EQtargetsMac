//
//  StatusChips.swift
//  EQtargets (macOS)
//
//  Decides which status chip the toolbar pill shows (DESIGN §6.7): one at a
//  time, highest first — Clipping › Limiting › Dropouts. Limiting / Clipping
//  hold for 2 s after the last event; Dropouts shows while `underruns` rose in
//  the last 10 s. Pure value type with injected timestamps.
//
//  Event sources, from the frozen `ChainMeters`:
//  • `overCount` is a LIFETIME counter of blocks that would have exceeded
//    0 dBFS without protection, so only its movement means anything; the first
//    observation is a baseline, never an event.
//  • With protection on, movement (or `limiterReductionDB` > 0.1) means the
//    limiter acted → Limiting. With protection off it means real clipping, as
//    does an output peak at 0 dBFS.
//

import Foundation

struct StatusChipTracker: Equatable {
    enum Chip: Equatable {
        case clipping
        case limiting
        case dropouts(Int)
    }

    static let holdSeconds: TimeInterval = 2
    static let dropoutWindow: TimeInterval = 10

    private(set) var lastClip: TimeInterval = -.infinity
    private(set) var lastLimit: TimeInterval = -.infinity
    /// How far the output went over during the current Limiting / Clipping
    /// episode, dB: the limiter's gain reduction (protection on) or the peak
    /// above 0 dBFS (protection off). Feeds the chip's "Lower Preamp" fix,
    /// which must work even when the EQ curve itself never goes above 0 dB
    /// (a hot master, Punch, Bass post gain). Restarts with each new episode.
    private(set) var episodeOverDB: Double = 0
    private var dropoutEvents: [(time: TimeInterval, count: Int)] = []
    private var lastOverCount: Int?
    private var lastUnderruns: Int?

    static func == (a: StatusChipTracker, b: StatusChipTracker) -> Bool {
        a.lastClip == b.lastClip && a.lastLimit == b.lastLimit && a.lastOverCount == b.lastOverCount
            && a.episodeOverDB == b.episodeOverDB
            && a.lastUnderruns == b.lastUnderruns && a.dropoutEvents.map(\.time) == b.dropoutEvents.map(\.time)
    }

    mutating func observe(meters m: ChainMeters, underruns: Int, protectionOn: Bool, now: TimeInterval) {
        let oversMoved = lastOverCount.map { m.overCount != $0 } ?? false
        lastOverCount = m.overCount
        let episodeRunning = now - max(lastClip, lastLimit) <= Self.holdSeconds
        let event: Bool
        if protectionOn {
            event = oversMoved || m.limiterReductionDB > 0.1
            if event { lastLimit = now }
        } else {
            event = oversMoved || m.outputPeakDB >= -0.001
            if event { lastClip = now }
        }
        if event {
            let over = protectionOn ? m.limiterReductionDB : m.outputPeakDB
            if !episodeRunning { episodeOverDB = 0 }
            if over.isFinite { episodeOverDB = max(episodeOverDB, over, 0) }
        }
        if let u = lastUnderruns, underruns > u {
            dropoutEvents.append((now, underruns - u))
        }
        lastUnderruns = underruns
        dropoutEvents.removeAll { now - $0.time > Self.dropoutWindow }
    }

    /// `episodeOverDB` while a Limiting / Clipping chip shows, else 0.
    func overDB(now: TimeInterval) -> Double {
        now - max(lastClip, lastLimit) <= Self.holdSeconds ? episodeOverDB : 0
    }

    func chip(now: TimeInterval) -> Chip? {
        if now - lastClip <= Self.holdSeconds { return .clipping }
        if now - lastLimit <= Self.holdSeconds { return .limiting }
        let recent = dropoutEvents.filter { now - $0.time <= Self.dropoutWindow }
        if !recent.isEmpty { return .dropouts(recent.reduce(0) { $0 + $1.count }) }
        return nil
    }

    /// Forget the baseline (engine stopped / restarted).
    mutating func reset() { self = StatusChipTracker() }
}
