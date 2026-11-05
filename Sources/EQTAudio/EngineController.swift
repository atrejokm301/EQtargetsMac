//
//  EngineController.swift
//  EQtargets (macOS)
//
//  CONTRACT FILE — the API below is what the UI (Sources/App) builds against.
//  Signatures are frozen; replace the stub bodies. Internals (Core Audio HAL
//  helpers, AUHAL output, routing, volume mirroring, driver install) live in
//  other files of Sources/EQTAudio.
//
//  What "on" means: macOS's default output is set to the EQtargets Audio
//  virtual device; the driver hands the system mix to us through shared
//  memory; we run the DSP chain and play the result on the REAL device the
//  user is listening on. "Off" restores macOS's default output to that real
//  device and stops all processing (zero CPU).
//

import Foundation
import Observation
import CoreAudio

enum OutputTransport: String, Equatable, Hashable {
    case builtIn, bluetooth, usb, hdmi, displayPort, airPlay, thunderbolt, virtual, aggregate, other
}

/// A real output device the processed audio can be played on.
/// Never the EQtargets Audio virtual device itself.
struct OutputDevice: Identifiable, Hashable {
    var id: String { uid }
    let objectID: AudioObjectID
    let uid: String
    let name: String
    let transport: OutputTransport
    let nominalSampleRate: Double
    /// True if the device exposes a settable output volume (volume mirroring
    /// targets the hardware; otherwise the chain applies digital gain).
    let hasHardwareVolume: Bool
}

enum EngineStatus: Equatable {
    /// The EQtargets Audio device is not present (driver not installed, or
    /// installed but coreaudiod not restarted yet).
    case driverMissing
    /// The user turned EQtargets off; macOS output is untouched.
    case off
    case starting
    /// Routed through EQtargets but nothing is playing — the output unit is
    /// stopped to save power and restarts the instant audio arrives.
    case idle
    /// Audio is flowing through the chain.
    case running
    /// Human-readable, shown in the UI as-is.
    case error(String)
}

struct EngineStats: Equatable {
    var sampleRate: Double = 0
    var outputBufferFrames: Int = 0
    /// Ring + chain + output-device latency, milliseconds.
    var latencyMs: Double = 0
    var driftPPM: Double = 0
    var underruns: Int = 0
    var resyncs: Int = 0
    /// Render time / buffer period, 0…1, smoothed.
    var cpuLoad: Double = 0
}

@MainActor
@Observable
final class EngineController {

    private(set) var status: EngineStatus = .driverMissing
    /// The user's on/off choice. The app persists it and calls `setPowered` at launch.
    private(set) var isPowered: Bool = false
    /// Real outputs, excluding EQtargets Audio. Sorted: current first, then by name.
    private(set) var outputDevices: [OutputDevice] = []
    /// Where processed audio is going right now (nil when off / no device).
    private(set) var currentOutput: OutputDevice?
    private(set) var stats = EngineStats()
    /// Mirror of the EQtargets Audio device's volume (what the volume keys move), 0…1.
    private(set) var systemVolume: Float = 1
    private(set) var systemMuted: Bool = false

    /// Called on the main actor whenever `currentOutput` changes (device
    /// switched in the macOS Sound menu, AirPods connected, user picked one in
    /// the app…). The app uses it to load the Target bound to that device.
    var onOutputChanged: ((OutputDevice?) -> Void)?

    init() {}

    /// True if the EQtargets Audio device is currently published by coreaudiod.
    var isDriverInstalled: Bool { false }

    /// Route through EQtargets (true) or restore macOS output and stop (false).
    func setPowered(_ on: Bool) {}

    /// `nil` = follow macOS (whatever the user picks in the Sound menu / Control
    /// Center becomes the real output). A UID pins a specific device.
    func selectOutput(uid: String?) {}

    /// Push new DSP parameters. Cheap to call at drag rate (≤ 60 Hz).
    func apply(_ parameters: ChainParameters) {}

    /// Lock-free meter snapshot. The UI polls this at ≤ 30 Hz while visible.
    func meters() -> ChainMeters { ChainMeters() }

    /// Copy the embedded driver into /Library/Audio/Plug-Ins/HAL (one admin
    /// prompt) and restart coreaudiod; returns once the device has appeared.
    func installDriver() async throws {}

    func uninstallDriver() async throws {}

    /// Synchronous. Call from `applicationWillTerminate`: restores macOS's
    /// default output to the real device and stops processing.
    func shutdown() {}
}
