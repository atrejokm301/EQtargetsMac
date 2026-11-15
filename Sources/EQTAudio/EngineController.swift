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
//  IMPLEMENTATION NOTES
//  ------------------------------------------------------------------
//  Everything here runs on the main actor. HAL property listeners fire on a
//  private serial queue and only post an event to the main queue; events are
//  coalesced and handled in a fixed order (service restart → device list →
//  default output → real-device format → virtual running → volumes), each
//  handler re-reading the HAL instead of trusting the notification.
//
//  States:  driverMissing ⇄ off → starting → idle ⇄ running,  any → error(msg)
//   • idle ⇄ running follows the virtual device's IsRunningSomewhere: the AUHAL
//     starts the moment something plays and stops 3 s after the last client
//     stops (zero CPU while silent; the unit stays configured for a fast restart).
//   • Any failure while routed restores macOS's default output first, so a
//     failure never leaves the Mac silent.
//
//  Routing (ARCHITECTURE.md §6) is decided by the pure `RoutingPolicy`
//  (Routing.swift) so the rules are tested without touching the system.
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

    // MARK: Internals

    /// UserDefaults key of the last real output we played on (fallback / recovery).
    nonisolated static let lastRealOutputKey = "eqtargets.mac.lastRealOutputUID"
    /// Idle hangover after the last client stops playing.
    static let idleHangoverSeconds = 3.0
    static let statsInterval = 0.5

    private enum Event: Int, Comparable, CaseIterable {
        case serviceRestarted, devices, defaultOutput, realFormat, virtualRunning, virtualVolume, realVolume
        static func < (a: Event, b: Event) -> Bool { a.rawValue < b.rawValue }
    }

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let chain = ProcessingChain(maxFrames: 4_096, maxChannels: 2)
    @ObservationIgnored private let listenerQueue = DispatchQueue(label: "com.eqtargets.engine.hal-listeners")
    @ObservationIgnored private var systemListeners: [PropertyListener] = []
    @ObservationIgnored private var virtualListeners: [PropertyListener] = []
    @ObservationIgnored private var realListeners: [PropertyListener] = []
    @ObservationIgnored private var pending = Set<Event>()
    @ObservationIgnored private var flushScheduled = false

    @ObservationIgnored private var virtualID: AudioObjectID?
    @ObservationIgnored private var listenedVirtualID: AudioObjectID?
    @ObservationIgnored private var pinnedUID: String?
    @ObservationIgnored private var recentUIDs: [String] = []
    /// The device we were playing on when it vanished and we fell back
    /// (Follow macOS): when it returns we go back to it.
    @ObservationIgnored private var fellBackFrom: String?
    /// Set by `fail(_:excluding:)` for the teardown it triggers: the device
    /// that refused to play, which macOS's default must not go back to.
    @ObservationIgnored private var excludingOnRestore: String?
    /// True while this process is registered with the driver as a ring reader
    /// ('eqta'). The driver's reader count includes us, so it is subtracted
    /// when deciding whether OTHER processes still read the ring.
    @ObservationIgnored private var readerAttachedHere = false
    /// The last device that refused to play, until a device starts playing
    /// again. Later restores (stranded default, retries) keep avoiding a jump
    /// onto loud speakers because of it.
    @ObservationIgnored private var lastRefusedUID: String?
    /// True while macOS's default output points at EQtargets Audio because of us.
    @ObservationIgnored private var routed = false
    @ObservationIgnored private var ring: RingMapping?
    @ObservationIgnored private var watchdog = RingWatchdog()
    @ObservationIgnored private var output: OutputUnit?
    @ObservationIgnored private var hangoverToken = 0
    @ObservationIgnored private var statsTimer: DispatchSourceTimer?
    @ObservationIgnored private var cpuLoad = 0.0
    @ObservationIgnored private var lastBusy: UInt64 = 0
    @ObservationIgnored private var lastPeriod: UInt64 = 0
    @ObservationIgnored private var counterBase = (underruns: 0, resyncs: 0)
    @ObservationIgnored private var followGuard = BurstGuard(limit: 6, window: 10)
    /// Same brake for handing a stranded default back (an app that insists on
    /// EQtargets Audio while we're off must not get an endless fight).
    @ObservationIgnored private var releaseGuard = BurstGuard(limit: 6, window: 10)
    @ObservationIgnored private var lastReportedLatency = -1

    // Volume mirroring
    @ObservationIgnored private var appParameters = ChainParameters()
    @ObservationIgnored private var realVolumeElements: [AudioObjectPropertyElement] = []
    @ObservationIgnored private var realMuteElements: [AudioObjectPropertyElement] = []
    @ObservationIgnored private var lastWrittenRealVolume: Float?
    @ObservationIgnored private var lastWrittenRealMute: Bool?
    @ObservationIgnored private var virtualVolumeDB: Double?

    @ObservationIgnored private var powerRequested = false
    @ObservationIgnored private var isShutDown = false

    init() {
        if let last = defaults.string(forKey: Self.lastRealOutputKey) { recentUIDs = [last] }
        installSystemListeners()
        refreshDevices()
        installVirtualListenersIfNeeded()
        readVirtualVolume()
        status = virtualID == nil ? .driverMissing : .off
        // Launch recovery: if macOS still points at EQtargets Audio (we crashed
        // or were killed while on) and the app does not turn us on right away,
        // give the user their sound back. Deferred so the normal launch path
        // (`setPowered(true)` from applicationDidFinishLaunching) never causes
        // a needless route flip.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            MainActor.assumeIsolated { self?.launchRecoveryIfNeeded() }
        }
    }

    /// True if the EQtargets Audio device is currently published by coreaudiod.
    var isDriverInstalled: Bool { DeviceCatalog.virtualDevice() != nil }

    /// Route through EQtargets (true) or restore macOS output and stop (false).
    func setPowered(_ on: Bool) {
        guard !isShutDown else { return }
        powerRequested = true
        fellBackFrom = nil
        if on {
            let needsStart = !isPowered || !routed
            isPowered = true
            followGuard.reset()
            releaseGuard.reset()
            if needsStart { powerOn() }
        } else {
            isPowered = false
            teardownRouting(restoreDefault: true)
            status = virtualID == nil ? .driverMissing : .off
        }
    }

    /// `nil` = follow macOS (whatever the user picks in the Sound menu / Control
    /// Center becomes the real output). A UID pins a specific device.
    func selectOutput(uid: String?) {
        guard !isShutDown else { return }
        pinnedUID = uid
        fellBackFrom = nil               // an explicit choice ends any pending return
        if isPowered, !routed, case .error = status { powerOn(); return }
        guard isPowered, routed, let uid else { sortDevices(); return }
        if uid != currentOutput?.uid, let device = outputDevices.first(where: { $0.uid == uid }) {
            route(to: device)
        }
        sortDevices()
    }

    /// Push new DSP parameters. Cheap to call at drag rate (≤ 60 Hz).
    func apply(_ parameters: ChainParameters) {
        appParameters = parameters
        pushChainParameters()
    }

    /// Lock-free meter snapshot. The UI polls this at ≤ 30 Hz while visible.
    func meters() -> ChainMeters { chain.meters() }

    /// Copy the embedded driver into /Library/Audio/Plug-Ins/HAL (one admin
    /// prompt) and restart coreaudiod; returns once the device has appeared.
    func installDriver() async throws {
        try await installDriver(from: DriverInstaller.embeddedDriver())
    }

    func uninstallDriver() async throws {
        // Hand macOS its output back first: the device is about to vanish.
        teardownRouting(restoreDefault: true)
        do {
            try await DriverInstaller.uninstall()
        } catch {
            resumeAfterAbortedDriverChange()     // cancelled at the admin prompt / failed
            throw error
        }
        let gone = await DriverInstaller.waitForDevice(present: false)
        handleDeviceListChange()
        if !gone { throw DriverInstallError.timedOut(installing: false) }
    }

    /// Synchronous. Call from `applicationWillTerminate`: restores macOS's
    /// default output to the real device and stops processing.
    func shutdown() {
        guard !isShutDown else { return }
        // Restores macOS's default even if we never powered on this launch but
        // it still pointed at us (crash leftovers): never leave the Mac silent.
        teardownRouting(restoreDefault: true)
        isShutDown = true
        systemListeners.forEach { $0.cancel() }
        virtualListeners.forEach { $0.cancel() }
        realListeners.forEach { $0.cancel() }
        systemListeners = []
        virtualListeners = []
        realListeners = []
        status = virtualID == nil ? .driverMissing : .off
    }

    // MARK: - Internal API (CLI / diagnostics)

    /// Installs a driver bundle from an explicit path (the CLI's `install-driver`).
    func installDriver(from url: URL) async throws {
        try DriverInstaller.validate(url)
        teardownRouting(restoreDefault: true)
        do {
            try await DriverInstaller.install(from: url)
        } catch {
            resumeAfterAbortedDriverChange()     // cancelled at the admin prompt / failed
            throw error
        }
        let appeared = await DriverInstaller.waitForDevice(present: true)
        handleDeviceListChange()
        if !appeared { throw DriverInstallError.timedOut(installing: true) }
    }

    /// Install / uninstall tore routing down first; if the privileged step then
    /// didn't happen (password prompt cancelled, script failed) the driver is
    /// unchanged: route again if the user had us on, else show plain Off.
    /// Without this the engine stayed "On / running" with no EQ applied.
    private func resumeAfterAbortedDriverChange() {
        guard !isShutDown else { return }
        if isPowered {
            powerOn()
        } else {
            refreshDevices()
            status = virtualID == nil ? .driverMissing : .off
        }
    }

    /// The running unit's render counters (CLI diagnostics).
    var renderCounters: (calls: UInt64, discontinuities: UInt64, rejected: UInt64, lastFrames: Int)? {
        guard let c = output?.context else { return nil }
        return (c.renderCalls.load(ordering: .relaxed), c.discontinuities.load(ordering: .relaxed),
                c.rejectedBuffers.load(ordering: .relaxed), c.lastFrameCount.load(ordering: .relaxed))
    }

    /// Reader lock state of the running unit (CLI diagnostics).
    var readerStats: RingReaderStats? { output?.context.reader.stats() }

    // MARK: - Power

    private func powerOn() {
        guard !isShutDown else { return }
        refreshDevices()
        installVirtualListenersIfNeeded()
        guard virtualID != nil else { status = .driverMissing; return }
        status = .starting

        if ring == nil {
            switch RingMapping.open() {
            case .success(let m):
                ring = m
                watchdog.reset()
            case .failure(let e):
                fail(e.userMessage)
                return
            }
        }

        let macDefaultUID = HAL.defaultOutputDevice().flatMap { id in outputDevices.first { $0.objectID == id }?.uid }
        guard let target = RoutingPolicy.powerOnChoice(devices: outputDevices, pinnedUID: pinnedUID,
                                                       macDefaultUID: macDefaultUID, recentUIDs: recentUIDs) else {
            fail("No speakers or headphones are available to play through.")
            return
        }
        route(to: target)
    }

    /// Point everything at `device`: rebuild the output unit, match the
    /// virtual rate, seed / mirror volume, make EQtargets Audio macOS's default.
    ///
    /// Order matters:
    ///  1. the chain gets its FINAL parameters (volume fold included) before
    ///     the unit is built — `ProcessingChain.prepare` adopts them instantly,
    ///     so a digital-volume device never plays 20 ms at full level while the
    ///     gain glides down;
    ///  2. the output unit is built BEFORE macOS's default output is taken — if
    ///     the device refuses, the user's sound was never interrupted.
    private func route(to device: OutputDevice) {
        guard !isShutDown, let vid = virtualID else { return }
        guard let ring else { fail(RingMapping.OpenError.notFound.userMessage); return }
        let changed = currentOutput?.uid != device.uid
        let previous = currentOutput

        // First: tell the driver this process reads the ring ('eqta'). A
        // driver that hides EQtargets Audio while nobody reads it must be
        // visible again well before macOS's default output is taken below.
        setReaderAttached(true, on: vid)

        teardownOutput()
        realListeners.forEach { $0.cancel() }
        realListeners = []

        // Re-read: the list entry may be seconds old (rate, volume capability).
        let fresh = DeviceCatalog.describe(device.objectID, virtualID: vid) ?? device
        currentOutput = fresh

        // Same rate on both sides → the resampler only absorbs clock drift.
        let rate = RoutingPolicy.virtualRate(matching: fresh.nominalSampleRate)
        if let current = HAL.nominalSampleRate(vid), abs(current - rate) > 0.5 {
            HAL.setNominalSampleRate(vid, rate)
        }

        // Volume: the real device's own controls are the truth when it has
        // them, so the volume keys start from where the device already is.
        realVolumeElements = HAL.settableVolumeElements(fresh.objectID)
        realMuteElements = HAL.settableMuteElements(fresh.objectID)
        lastWrittenRealVolume = nil
        lastWrittenRealMute = nil
        if !realVolumeElements.isEmpty, let v = HAL.volumeScalar(fresh.objectID, elements: realVolumeElements) {
            HAL.setVolumeScalar(vid, elements: [kAudioObjectPropertyElementMain], v)
        }
        if !realMuteElements.isEmpty, let m = HAL.isMuted(fresh.objectID, elements: realMuteElements) {
            HAL.setMuted(vid, elements: [kAudioObjectPropertyElementMain], m)
        }
        readVirtualVolume()
        pushChainParameters()                                   // (1)

        do {                                                    // (2)
            output = try OutputUnit(device: fresh.objectID, ring: ring, chain: chain)
        } catch {
            // The device refused. If macOS's default is ours it goes back to
            // the device that WAS playing, never to the one that just refused
            // (and the refusing device is not remembered as "last used").
            currentOutput = previous
            if let f = error as? OutputUnit.Failure {
                fail("EQtargets couldn't play through \(fresh.name): \(f.message).", excluding: fresh.uid)
            } else {
                fail("EQtargets couldn't play through \(fresh.name).", excluding: fresh.uid)
            }
            return
        }
        // Kept so a refused START below can undo "last used" (ARCHITECTURE §6).
        let undoRemember = (recents: recentUIDs, last: defaults.string(forKey: Self.lastRealOutputKey))
        recentUIDs = RoutingPolicy.remember(fresh.uid, in: recentUIDs)
        defaults.set(fresh.uid, forKey: Self.lastRealOutputKey)
        installRealListeners(fresh.objectID)

        if HAL.defaultOutputDevice() != vid {
            let s = takeDefaultOutput(vid)
            if s != noErr {
                fail("macOS didn't accept EQtargets Audio as the sound output (Core Audio error \(HAL.describe(s))).")
                return
            }
        }
        routed = true
        applyVolume()
        lastReportedLatency = -1
        if HAL.isRunningSomewhere(vid) {
            startOutput(onRefusal: { [unowned self] in
                // Refused at route time: it never played, so it is neither
                // the device the user was on nor the last-used one.
                self.currentOutput = previous
                self.recentUIDs = undoRemember.recents
                self.defaults.set(undoRemember.last, forKey: Self.lastRealOutputKey)
            })
            guard routed else { return }   // refused → fail() tore the route down
        } else {
            status = .idle
            reportLatency()
        }
        sortDevices()
        if changed { onOutputChanged?(fresh) }
    }

    /// `onRefusal` runs before the teardown when the device refuses to start
    /// (route() uses it to put back the device that was playing).
    private func startOutput(onRefusal: (() -> Void)? = nil) {
        guard let output else { return }
        hangoverToken += 1
        if !output.isRunning {
            let refusing = currentOutput
            do {
                try output.start()
            } catch {
                let detail = (error as? OutputUnit.Failure).map { ": \($0.message)" } ?? ""
                onRefusal?()
                fail("EQtargets couldn't play through \(refusing?.name ?? "the output")\(detail).",
                     excluding: refusing?.uid)
                return
            }
        }
        lastRefusedUID = nil               // something plays again
        status = .running
        startStatsTimer()
        sampleStats()
        reportLatency()
    }

    private func enterIdle() {
        guard let output else { return }
        output.stop()
        stopStatsTimer()
        sampleStats()
        status = .idle
    }

    /// Stop and drop the output unit (chain parameters are kept).
    private func teardownOutput() {
        stopStatsTimer()
        hangoverToken += 1
        if let o = output {
            let rs = o.context.reader.stats()
            counterBase.underruns += rs.underruns
            counterBase.resyncs += rs.resyncs
            o.dispose()
            output = nil
        }
        lastBusy = 0
        lastPeriod = 0
    }

    /// Off / failure / quit / uninstall: stop, give macOS its output back.
    private func teardownRouting(restoreDefault: Bool) {
        teardownOutput()
        realListeners.forEach { $0.cancel() }
        realListeners = []
        if routed, let vid = virtualID, HAL.isSettable(vid, HAL.address(EQT_PROPERTY_CLIENT_LATENCY)) {
            setClientLatency(0, on: vid)   // nothing is added while we are not in the path
        }
        if restoreDefault { restoreDefaultOutputIfOurs(excluding: excludingOnRestore) }
        excludingOnRestore = nil
        // No longer reading: a driver with 'eqta' hides EQtargets Audio once no
        // process reads the ring, so it can't be picked (or fallen back to)
        // while nothing would play it. Only once macOS is off it.
        if let vid = virtualID, HAL.defaultOutputDevice() != vid { setReaderAttached(false, on: vid) }
        routed = false
        lastReportedLatency = -1
        stats = EngineStats()
        cpuLoad = 0
        realVolumeElements = []
        realMuteElements = []
        if currentOutput != nil {
            currentOutput = nil
            sortDevices()
            onOutputChanged?(nil)
        }
    }

    /// If macOS's default output is EQtargets Audio, point it at a real device
    /// (never `excluding`, a device that just refused to play).
    private func restoreDefaultOutputIfOurs(excluding: String? = nil) {
        guard let vid = virtualID ?? DeviceCatalog.virtualDevice(), HAL.defaultOutputDevice() == vid else { return }
        let devices = DeviceCatalog.outputDevices()
        if let target = RoutingPolicy.restoreChoice(devices: devices, currentUID: currentOutput?.uid, recentUIDs: recentUIDs,
                                                    excluding: excluding) {
            HAL.setDefaultOutputDevice(target.objectID)
        }
    }

    private func fail(_ message: String, excluding: String? = nil) {
        if let excluding { lastRefusedUID = excluding }
        excludingOnRestore = excluding
        teardownRouting(restoreDefault: true)
        status = .error(message)
    }

    private func launchRecoveryIfNeeded() {
        guard !powerRequested, !isPowered, !isShutDown else { return }
        restoreDefaultOutputIfOurs()
        if let vid = virtualID, HAL.defaultOutputDevice() != vid { setReaderAttached(false, on: vid) }
    }

    /// macOS's default output is EQtargets Audio but this engine isn't playing
    /// what reaches it (Off, failed, stepped aside, not routed yet) — picked
    /// in the Sound menu, or chosen by coreaudiod as a fallback when the real
    /// device left. Nothing reads the ring, so the Mac would be silent: hand
    /// the default back, unless another process is reading (a driver with
    /// 'eqta' says so; an older driver can't, and then nobody is assumed).
    private func releaseDefaultIfStranded() {
        guard !isShutDown, let vid = virtualID else { return }
        let ours = HAL.defaultOutputDevice() == vid
        guard ours else {
            // Off with the default elsewhere but still registered as a reader
            // (an earlier teardown couldn't move the default): let go, so the
            // driver can hide EQtargets Audio again.
            if readerAttachedHere, !(isPowered && routed) { setReaderAttached(false, on: vid) }
            return
        }
        // The count includes this process while it is still attached (a
        // teardown that could not move the default keeps us attached): only
        // OTHER readers keep the Mac from being silent.
        let others = RoutingPolicy.otherReaders(reported: HAL.customNumber(vid, EQT_PROPERTY_READER_ATTACHED),
                                                attachedHere: readerAttachedHere)
        guard RoutingPolicy.mustReleaseDefault(defaultIsOurs: ours, poweredAndRouted: isPowered && routed,
                                               otherReaders: others),
              releaseGuard.record(at: Date().timeIntervalSinceReferenceDate) else { return }
        restoreDefaultOutputIfOurs(excluding: lastRefusedUID)
        if HAL.defaultOutputDevice() != vid { setReaderAttached(false, on: vid) }
    }

    /// 'eqta': this process does / doesn't read the ring (no-op on an older
    /// driver without the property).
    private func setReaderAttached(_ attached: Bool, on vid: AudioObjectID) {
        guard HAL.isSettable(vid, HAL.address(EQT_PROPERTY_READER_ATTACHED)) else { readerAttachedHere = false; return }
        // Trust only a SET the driver accepted (its reader table can be full).
        if HAL.setCustomNumber(vid, EQT_PROPERTY_READER_ATTACHED, attached ? 1 : 0) == noErr {
            readerAttachedHere = attached
        }
    }

    /// macOS's default output → EQtargets Audio. Right after the driver was
    /// made visible again ('eqta') coreaudiod may need a beat before it
    /// accepts the device as default: retry briefly before calling it a failure.
    private func takeDefaultOutput(_ vid: AudioObjectID) -> OSStatus {
        var s = HAL.setDefaultOutputDevice(vid)
        var attempt = 0
        while s != noErr, attempt < 3 {
            attempt += 1
            usleep(30_000)
            s = HAL.setDefaultOutputDevice(vid)
        }
        return s
    }

    // MARK: - Devices

    private func refreshDevices() {
        let vid = DeviceCatalog.virtualDevice()
        // A new device object = a new driver instance (coreaudiod restarted)
        // with an empty reader table: we are not attached to it.
        if vid != virtualID { readerAttachedHere = false }
        virtualID = vid
        let devices = DeviceCatalog.outputDevices()
        let current = currentOutput.flatMap { c in devices.first { $0.uid == c.uid } }
        if let current { currentOutput = current }
        outputDevices = RoutingPolicy.sorted(devices, currentUID: currentOutput?.uid ?? macDefaultUID(in: devices))
    }

    private func sortDevices() {
        outputDevices = RoutingPolicy.sorted(outputDevices, currentUID: currentOutput?.uid ?? macDefaultUID(in: outputDevices))
    }

    /// While off, "current" in the list is whatever macOS plays to.
    private func macDefaultUID(in devices: [OutputDevice]) -> String? {
        guard let id = HAL.defaultOutputDevice() else { return nil }
        return devices.first { $0.objectID == id }?.uid
    }

    // MARK: - Listeners

    private func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        event: Event) -> PropertyListener {
        PropertyListener(object: object, address: HAL.address(selector, scope), queue: listenerQueue) { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.post(event) }
            }
        }
    }

    private func installSystemListeners() {
        let sys = HAL.systemObject
        systemListeners = [
            listen(sys, kAudioHardwarePropertyDevices, event: .devices),
            listen(sys, kAudioHardwarePropertyDefaultOutputDevice, event: .defaultOutput),
            listen(sys, kAudioHardwarePropertyServiceRestarted, event: .serviceRestarted),
        ]
    }

    private func installVirtualListenersIfNeeded() {
        guard listenedVirtualID != virtualID else { return }
        virtualListeners.forEach { $0.cancel() }
        virtualListeners = []
        listenedVirtualID = virtualID
        guard let vid = virtualID else { return }
        let out = kAudioObjectPropertyScopeOutput
        virtualListeners = [
            listen(vid, kAudioDevicePropertyDeviceIsRunningSomewhere, event: .virtualRunning),
            listen(vid, kAudioDevicePropertyVolumeScalar, out, event: .virtualVolume),
            listen(vid, kAudioDevicePropertyMute, out, event: .virtualVolume),
        ]
    }

    private func installRealListeners(_ device: AudioObjectID) {
        let out = kAudioObjectPropertyScopeOutput
        var l = [
            listen(device, kAudioDevicePropertyNominalSampleRate, event: .realFormat),
            listen(device, kAudioDevicePropertyStreamConfiguration, out, event: .realFormat),
            listen(device, kAudioDevicePropertyDeviceIsAlive, event: .devices),
        ]
        for e in realVolumeElements {
            l.append(PropertyListener(object: device, address: HAL.address(kAudioDevicePropertyVolumeScalar, out, e),
                                      queue: listenerQueue) { [weak self] in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.post(.realVolume) } }
            })
        }
        for e in realMuteElements {
            l.append(PropertyListener(object: device, address: HAL.address(kAudioDevicePropertyMute, out, e),
                                      queue: listenerQueue) { [weak self] in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.post(.realVolume) } }
            })
        }
        realListeners = l
    }

    private func post(_ event: Event) {
        guard !isShutDown else { return }
        pending.insert(event)
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    private func flush() {
        flushScheduled = false
        let events = pending.sorted()
        pending = []
        guard !isShutDown else { return }
        for e in events {
            switch e {
            case .serviceRestarted: handleServiceRestart(); return   // re-derives everything
            case .devices: handleDeviceListChange()
            case .defaultOutput: handleDefaultOutputChange()
            case .realFormat: handleRealFormatChange()
            case .virtualRunning: handleVirtualRunning()
            case .virtualVolume: handleVirtualVolume()
            case .realVolume: handleRealVolume()
            }
        }
    }

    // MARK: - Handlers

    /// coreaudiod restarted (driver install, crash): every object ID may have
    /// changed and per-device listeners are gone. Start over from the UIDs.
    private func handleServiceRestart() {
        teardownOutput()
        realListeners.forEach { $0.cancel() }
        realListeners = []
        routed = false
        ring = nil                       // re-open by name (the driver re-attached or re-created it)
        listenedVirtualID = nil
        let playingOn = currentOutput?.uid
        readerAttachedHere = false       // the restarted driver's reader table is empty
        refreshDevices()
        installVirtualListenersIfNeeded()
        if isPowered, virtualID != nil {
            powerOn()
            // Devices are re-published one by one after a restart (Bluetooth
            // often after ours): if the one we were playing on isn't back yet,
            // go back to it when it is.
            if routed, let was = playingOn, currentOutput?.uid != was, fellBackFrom == nil { fellBackFrom = was }
        } else {
            if currentOutput != nil { currentOutput = nil; onOutputChanged?(nil) }
            status = virtualID == nil ? .driverMissing : .off
            // flush() drops the rest of a batch after a restart: a default
            // left on EQtargets Audio must still be handed back now.
            releaseDefaultIfStranded()
        }
    }

    private func handleDeviceListChange() {
        let hadVirtual = virtualID != nil
        refreshDevices()
        installVirtualListenersIfNeeded()

        guard virtualID != nil else {
            // Driver gone: macOS has already moved its default elsewhere.
            if hadVirtual || routed || output != nil {
                teardownRouting(restoreDefault: false)
                ring = nil
            }
            readerAttachedHere = false
            status = .driverMissing
            return
        }
        guard isPowered else {
            if status == .driverMissing { status = .off }
            releaseDefaultIfStranded()
            return
        }
        guard routed else {
            // Powered but not routed: the driver just appeared, or we failed
            // earlier (e.g. no device) and something changed — try again.
            powerOn()
            return
        }
        guard let current = currentOutput else { powerOn(); return }
        let stillThere = outputDevices.contains { $0.uid == current.uid } && HAL.isAlive(current.objectID)
        if !stillThere {
            guard let next = RoutingPolicy.fallbackChoice(devices: outputDevices, pinnedUID: pinnedUID,
                                                          recentUIDs: recentUIDs, excluding: current.uid) else {
                fail("No speakers or headphones are available to play through.")
                return
            }
            // Remember the device the user was really listening on (the
            // first one lost, if fallbacks chain) so we can go back to it.
            if fellBackFrom == nil { fellBackFrom = current.uid }
            route(to: next)
        } else if let pin = pinnedUID, pin != current.uid, let pinned = outputDevices.first(where: { $0.uid == pin }) {
            route(to: pinned)          // the pinned device came back
        } else if let back = RoutingPolicy.returnChoice(devices: outputDevices, fellBackFrom: fellBackFrom,
                                                        currentUID: current.uid, pinnedUID: pinnedUID),
                  HAL.isAlive(back.objectID) {
            fellBackFrom = nil
            route(to: back)            // the device we fell back from came back (Follow macOS)
        } else if fellBackFrom == current.uid {
            fellBackFrom = nil
        }
    }

    /// macOS's default output moved. If it moved to another real device the
    /// user (or macOS, e.g. AirPods connecting) chose it: play there, and take
    /// the default back so the audio still flows through us.
    private func handleDefaultOutputChange() {
        sortDevices()
        releaseDefaultIfStranded()
        guard isPowered, routed, let vid = virtualID, let def = HAL.defaultOutputDevice(), def != vid else { return }
        guard followGuard.record(at: Date().timeIntervalSinceReferenceDate) else {
            isPowered = false
            teardownRouting(restoreDefault: false)   // leave the user's latest choice in place
            status = .error("Another app keeps changing the sound output, so EQtargets stepped aside. Turn EQtargets back on to retry.")
            return
        }
        // Follow macOS unless a pinned device is actually present: a pin
        // whose device is away must not make every Control Center pick bounce.
        // A present pin keeps (or puts back) the route on the PINNED device.
        let follows = RoutingPolicy.followsMacDefault(pinnedUID: pinnedUID, devices: outputDevices)
        if let device = RoutingPolicy.defaultChangeTarget(picked: DeviceCatalog.describe(def, virtualID: vid),
                                                          pinnedUID: pinnedUID, currentUID: currentOutput?.uid,
                                                          devices: outputDevices) {
            if follows { fellBackFrom = nil }   // the user chose: no automatic return
            route(to: device)          // route() sets the default back to EQtargets Audio
        } else {
            HAL.setDefaultOutputDevice(vid)   // already where we should be: keep the default
        }
    }

    /// The real device's rate or stream layout changed: rebuild for the new
    /// format (and re-match the virtual device's rate).
    private func handleRealFormatChange() {
        guard isPowered, routed, let current = currentOutput else { return }
        guard let fresh = DeviceCatalog.describe(current.objectID, virtualID: virtualID) else {
            handleDeviceListChange()
            return
        }
        // Same rate: AUHAL adapts to stream-layout changes by itself, and
        // rebuilding would only cause a gap.
        if let o = output, abs(o.sampleRate - fresh.nominalSampleRate) < 0.5 {
            currentOutput = fresh
            return
        }
        route(to: fresh)
    }

    private func handleVirtualRunning() {
        guard isPowered, routed, let vid = virtualID, output != nil else { return }
        if HAL.isRunningSomewhere(vid) {
            startOutput()
        } else {
            hangoverToken += 1
            let token = hangoverToken
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleHangoverSeconds) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, token == self.hangoverToken, !self.isShutDown,
                          let vid = self.virtualID, !HAL.isRunningSomewhere(vid) else { return }
                    self.enterIdle()
                }
            }
        }
    }

    private func handleVirtualVolume() {
        readVirtualVolume()
        guard isPowered, routed else { return }
        applyVolume()
    }

    /// The real device's own volume moved (e.g. AirPods Max crown): reflect it
    /// on the virtual device so the menu-bar slider and the keys agree.
    private func handleRealVolume() {
        guard isPowered, routed, let vid = virtualID, let dev = currentOutput?.objectID else { return }
        if !realVolumeElements.isEmpty, let v = HAL.volumeScalar(dev, elements: realVolumeElements) {
            let echo = lastWrittenRealVolume.map { abs($0 - v) < 0.01 } ?? false
            if !echo, abs(v - systemVolume) > 0.005 {
                lastWrittenRealVolume = v
                HAL.setVolumeScalar(vid, elements: [kAudioObjectPropertyElementMain], v)
            }
        }
        if !realMuteElements.isEmpty, let m = HAL.isMuted(dev, elements: realMuteElements) {
            if m != lastWrittenRealMute, m != systemMuted {
                lastWrittenRealMute = m
                HAL.setMuted(vid, elements: [kAudioObjectPropertyElementMain], m)
            }
        }
    }

    // MARK: - Volume mirroring

    private func readVirtualVolume() {
        guard let vid = virtualID else { return }
        let main: [AudioObjectPropertyElement] = [kAudioObjectPropertyElementMain]
        if let v = HAL.volumeScalar(vid, elements: main) { systemVolume = v }
        if let m = HAL.isMuted(vid, elements: main) { systemMuted = m }
        virtualVolumeDB = HAL.volumeDecibels(vid)
    }

    /// Virtual → real hardware where it can be set; everything else is folded
    /// into the chain's digital output gain / mute.
    private func applyVolume() {
        if let dev = currentOutput?.objectID {
            if !realVolumeElements.isEmpty {
                let current = HAL.volumeScalar(dev, elements: realVolumeElements)
                if current.map({ abs($0 - systemVolume) > 0.001 }) ?? true {
                    lastWrittenRealVolume = systemVolume
                    HAL.setVolumeScalar(dev, elements: realVolumeElements, systemVolume)
                }
            }
            if !realMuteElements.isEmpty, HAL.isMuted(dev, elements: realMuteElements) != systemMuted {
                lastWrittenRealMute = systemMuted
                HAL.setMuted(dev, elements: realMuteElements, systemMuted)
            }
        }
        pushChainParameters()
    }

    /// The volume fold applies whenever a real device is chosen (it is set
    /// up before the default output is taken — see `route`).
    private func pushChainParameters() {
        guard currentOutput != nil else {
            chain.setParameters(appParameters)
            return
        }
        chain.setParameters(VolumeLaw.fold(appParameters, volume: systemVolume, muted: systemMuted,
                                           volumeDB: virtualVolumeDB,
                                           hardwareVolume: !realVolumeElements.isEmpty,
                                           hardwareMute: !realMuteElements.isEmpty))
    }

    // MARK: - Stats, watchdog, latency report

    private func startStatsTimer() {
        guard statsTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + Self.statsInterval, repeating: Self.statsInterval, leeway: .milliseconds(50))
        t.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.statsTick() }
        }
        t.resume()
        statsTimer = t
    }

    private func stopStatsTimer() {
        statsTimer?.cancel()
        statsTimer = nil
    }

    private func statsTick() {
        guard output != nil else { return }
        sampleStats()
        checkRingHealth()
        reportLatency()
    }

    private func sampleStats() {
        guard let o = output else { return }
        let ctx = o.context
        let rs = ctx.reader.stats()
        let busy = ctx.busyTicks.load(ordering: .relaxed)
        let period = ctx.periodTicks.load(ordering: .relaxed)
        if period > lastPeriod, busy >= lastBusy {
            let load = Double(busy - lastBusy) / Double(period - lastPeriod)
            cpuLoad += (min(max(load, 0), 1) - cpuLoad) * 0.5
        }
        lastBusy = busy
        lastPeriod = period
        let deviceFrames = o.presentationLatencyFrames
        stats = EngineStats(
            sampleRate: o.sampleRate,
            outputBufferFrames: o.bufferFrames,
            latencyMs: LatencyMath.engineLatencyMs(ringSeconds: rs.latencySeconds, chainFrames: chain.latencyFrames,
                                                   deviceFrames: deviceFrames, outputRate: o.sampleRate),
            driftPPM: rs.driftPPM,
            underruns: counterBase.underruns + rs.underruns,
            resyncs: counterBase.resyncs + rs.resyncs,
            cpuLoad: cpuLoad)
    }

    /// Re-open the ring if the mapping went dead (see RingMapping.swift).
    private func checkRingHealth() {
        guard let ring, let vid = virtualID else { return }
        let dead = watchdog.observe(valid: ring.isValid, head: ring.writeHead, stamp: ring.lastWriteHostTime,
                                    deviceRunning: HAL.isRunningSomewhere(vid), dt: Self.statsInterval)
        guard dead else { return }
        watchdog.reset()
        guard case .success(let fresh) = RingMapping.open(), !fresh.hasSameHeaderBytes(as: ring) else { return }
        self.ring = fresh
        if let current = currentOutput { route(to: current) }   // new reader on the new mapping
    }

    /// Tell the driver how much latency we add, so players keep lip sync.
    ///
    /// Players apply it only when the HAL announces it, and the driver can only
    /// have it announced through a configuration change, which briefly stops IO
    /// on EQtargets Audio. So the figure is right from the first report of a
    /// route (before the reader has run, the ring target is estimated from the
    /// writer's last buffer size), and later it is re-sent only when it moved
    /// by `LatencyMath.reportThresholdSeconds` — never for the few ms the ring
    /// target moves when another app's buffer size starts the stream.
    private func reportLatency() {
        guard routed, let vid = virtualID, let o = output else { return }
        let rs = o.context.reader.stats()
        let source = rs.sourceSampleRate > 0 ? rs.sourceSampleRate : (HAL.nominalSampleRate(vid) ?? o.sampleRate)
        let writer = o.context.ring.ioBufferFrames
        let target = rs.targetFillFrames > 0 ? rs.targetFillFrames
            : RingReader.targetFill(writerFrames: Double(writer > 0 && writer <= 16_384 ? writer : 512),
                                    outputFramesInSource: Double(o.bufferFrames) * source / o.sampleRate,
                                    kernelTaps: ResamplerTable.baseTaps)
        let frames = LatencyMath.driverReportFrames(ringTargetFrames: target, chainFrames: chain.latencyFrames,
                                                    deviceFrames: o.presentationLatencyFrames,
                                                    outputRate: o.sampleRate, sourceRate: source)
        guard LatencyMath.shouldReport(frames, last: lastReportedLatency, sourceRate: source) else { return }
        guard HAL.isSettable(vid, HAL.address(EQT_PROPERTY_CLIENT_LATENCY)) else { return }
        if setClientLatency(frames, on: vid) == noErr { lastReportedLatency = frames }
    }

    /// 'eqtl' is a CFPropertyList custom property: the value is a CFNumber.
    @discardableResult
    private func setClientLatency(_ frames: Int, on device: AudioObjectID) -> OSStatus {
        var a = HAL.address(EQT_PROPERTY_CLIENT_LATENCY)
        var number: CFNumber = NSNumber(value: Double(max(0, frames))) as CFNumber
        return withUnsafePointer(to: &number) { p in
            AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<CFNumber>.size), p)
        }
    }
}
