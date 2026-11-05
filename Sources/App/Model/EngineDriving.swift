//
//  EngineDriving.swift
//  EQtargets (macOS)
//
//  The UI's view of the engine, layered ON TOP of the frozen `EngineController`
//  API (nothing in Sources/EQTAudio is changed):
//
//  • `EngineDriving` — exactly the frozen surface the app uses. The real
//    `EngineController` conforms with an empty extension. Snapshot rendering
//    and the self-test use `StandInEngine` instead, so they never construct the
//    real engine and can never change macOS's default output device.
//  • `EngineDisplay` — the small value type every view reads. Views never
//    touch the engine directly, so a snapshot can show "running on AirPods at
//    48 kHz" with real layout and copy, without poking engine internals.
//

import Foundation
import Observation

@MainActor
protocol EngineDriving: AnyObject {
    var status: EngineStatus { get }
    var isPowered: Bool { get }
    var outputDevices: [OutputDevice] { get }
    var currentOutput: OutputDevice? { get }
    var stats: EngineStats { get }
    var systemVolume: Float { get }
    var systemMuted: Bool { get }
    var isDriverInstalled: Bool { get }
    var onOutputChanged: ((OutputDevice?) -> Void)? { get set }

    func setPowered(_ on: Bool)
    func selectOutput(uid: String?)
    func apply(_ parameters: ChainParameters)
    func meters() -> ChainMeters
    func installDriver() async throws
    func uninstallDriver() async throws
    func shutdown()
}

extension EngineController: EngineDriving {}

/// Everything a view shows about the engine, as one value.
struct EngineDisplay: Equatable {
    var status: EngineStatus = .driverMissing
    var isPowered = false
    var outputDevices: [OutputDevice] = []
    var currentOutput: OutputDevice?
    var stats = EngineStats()

    @MainActor
    init(engine: any EngineDriving) {
        status = engine.status
        isPowered = engine.isPowered
        outputDevices = engine.outputDevices
        currentOutput = engine.currentOutput
        stats = engine.stats
    }

    init(status: EngineStatus, isPowered: Bool, outputDevices: [OutputDevice],
         currentOutput: OutputDevice?, stats: EngineStats) {
        self.status = status
        self.isPowered = isPowered
        self.outputDevices = outputDevices
        self.currentOutput = currentOutput
        self.stats = stats
    }

    var driverInstalled: Bool { status != .driverMissing }
    var isRunning: Bool { status == .running }
    /// Audio is routed through us (running, or idle waiting for sound).
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

/// Side-effect-free engine for snapshot rendering and the self-test. Values are
/// set directly; `apply` / `setPowered` only record what they were asked.
@MainActor
@Observable
final class StandInEngine: EngineDriving {
    var status: EngineStatus = .off
    var isPowered = false
    var outputDevices: [OutputDevice] = []
    var currentOutput: OutputDevice?
    var stats = EngineStats()
    var systemVolume: Float = 1
    var systemMuted = false
    var isDriverInstalled: Bool { status != .driverMissing }
    @ObservationIgnored var onOutputChanged: ((OutputDevice?) -> Void)?

    @ObservationIgnored var meterValues = ChainMeters()
    @ObservationIgnored private(set) var applied: [ChainParameters] = []
    @ObservationIgnored private(set) var poweredCalls: [Bool] = []
    @ObservationIgnored private(set) var selectedOutputs: [String?] = []
    @ObservationIgnored var installResult: Result<Void, Error> = .success(())

    func setPowered(_ on: Bool) { poweredCalls.append(on); isPowered = on }
    func selectOutput(uid: String?) { selectedOutputs.append(uid) }
    func apply(_ parameters: ChainParameters) { applied.append(parameters) }
    func meters() -> ChainMeters { meterValues }
    func installDriver() async throws { try installResult.get() }
    func uninstallDriver() async throws {}
    @ObservationIgnored private(set) var shutdownCalls = 0
    func shutdown() { shutdownCalls += 1 }
}
