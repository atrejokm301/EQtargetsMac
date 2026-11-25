//
//  EngineDisplay.swift
//  EQtargets (iOS)
//
//  The UI's view of the engine:
//
//  - `EngineDisplay` is the small value a view reads, so a snapshot can show any
//    state with real layout and copy without touching the audio session.
//  - `StandInEngine` conforms to the iOS `EngineDriving` for previews, snapshots
//    and tests. It never opens an audio session or a socket.
//

import Foundation
import Observation

/// Everything a view shows about the engine, as one value.
struct EngineDisplay: Equatable {
    var status: EngineStatus = .off
    var isPowered = false
    var currentOutput: OutputDevice?
    var stats = EngineStats()

    @MainActor
    init(engine: any EngineDriving) {
        status = engine.status
        isPowered = engine.isPowered
        currentOutput = engine.currentOutput
        stats = engine.stats
    }

    init(status: EngineStatus, isPowered: Bool, currentOutput: OutputDevice?, stats: EngineStats) {
        self.status = status
        self.isPowered = isPowered
        self.currentOutput = currentOutput
        self.stats = stats
    }

    var isRunning: Bool { status == .running }
    /// The EQ is in the audio path (running, or idle waiting for sound).
    /// `.passThrough` is deliberately not here: audio flows, but unprocessed.
    var isProcessing: Bool { Self.isProcessing(status) }
    static func isProcessing(_ status: EngineStatus) -> Bool { status == .running || status == .idle }

    /// Sample rate the graph should evaluate at (§7.1).
    var graphSampleRate: Double {
        isProcessing ? ResponseMath.displaySampleRate(stats.sampleRate) : ResponseMath.fallbackSampleRate
    }

    var errorMessage: String? {
        if case .error(let m) = status { return m }
        return nil
    }
}

/// Side-effect-free engine. Values are set directly; `apply`, `setPowered` and
/// `setForeground` only record what they were asked.
@MainActor
@Observable
final class StandInEngine: EngineDriving {
    var status: EngineStatus = .off
    var isPowered = false
    var currentOutput: OutputDevice?
    var stats = EngineStats()
    @ObservationIgnored var onOutputChanged: ((OutputDevice?) -> Void)?

    @ObservationIgnored var meterValues = ChainMeters()
    @ObservationIgnored private(set) var applied: [ChainParameters] = []
    @ObservationIgnored private(set) var poweredCalls: [Bool] = []
    @ObservationIgnored private(set) var foregroundCalls: [Bool] = []
    @ObservationIgnored private(set) var retryCalls = 0
    @ObservationIgnored private(set) var watchCalls = 0
    /// Makes a start fail, as when iOS refuses the audio session.
    @ObservationIgnored var startFailure: String?

    func setPowered(_ on: Bool) {
        poweredCalls.append(on)
        isPowered = on
        if let startFailure { status = on ? .error(startFailure) : .off }
    }

    func retry() { retryCalls += 1 }
    func apply(_ parameters: ChainParameters) { applied.append(parameters) }
    func meters() -> ChainMeters { meterValues }
    func setForeground(_ foreground: Bool) { foregroundCalls.append(foreground) }
    func watchForPeer() { watchCalls += 1 }
}
