//
//  Routing.swift
//  EQtargets (macOS)
//
//  Pure decisions of the engine — no HAL calls, so `eqt-engine
//  --offline-selftest` can check every rule without touching the system.
//
//  • RoutingPolicy — which REAL device plays the processed audio
//    (ARCHITECTURE.md §6), and what macOS's default output goes back to.
//  • VolumeLaw     — the driver's volume taper and the digital fallback fold.
//  • LatencyMath   — what the UI shows and what the driver is told ('eqtl').
//  • BurstGuard    — the feedback-loop brake on "follow macOS".
//

import Foundation

enum RoutingPolicy {

    /// Rates the driver can run at (Driver/README.md).
    static let driverRates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000]

    /// Never route to our own device, whatever a list says (feedback loop).
    static func isRoutable(_ d: OutputDevice) -> Bool { d.uid != EQT_DEVICE_UID }

    /// Power-on (§6): pinned (if present) → macOS's current default (if it is a
    /// real device) → most recently used real device → built-in → any.
    /// nil = there is no real output at all (never route then).
    static func powerOnChoice(devices: [OutputDevice], pinnedUID: String?, macDefaultUID: String?,
                              recentUIDs: [String]) -> OutputDevice? {
        let real = devices.filter(isRoutable)
        if let p = pinnedUID, let d = real.first(where: { $0.uid == p }) { return d }
        if let m = macDefaultUID, let d = real.first(where: { $0.uid == m }) { return d }
        return fallbackChoice(devices: real, pinnedUID: nil, recentUIDs: recentUIDs, excluding: nil)
    }

    /// The current real device disappeared: pinned → recent → built-in → any,
    /// never `excluding` (the one that just went away).
    static func fallbackChoice(devices: [OutputDevice], pinnedUID: String?, recentUIDs: [String],
                               excluding: String?) -> OutputDevice? {
        let real = devices.filter { isRoutable($0) && $0.uid != excluding }
        if let p = pinnedUID, let d = real.first(where: { $0.uid == p }) { return d }
        for uid in recentUIDs {
            if let d = real.first(where: { $0.uid == uid }) { return d }
        }
        if let b = real.first(where: { $0.transport == .builtIn }) { return b }
        return real.first
    }

    /// Where macOS's default output goes when we turn off / quit / recover:
    /// the device we were playing on → recent → built-in → any real device.
    /// If `excluding` (a device that just refused to play) is present: the
    /// device playing a moment ago → a recent PERSONAL device (headphones,
    /// USB/Thunderbolt DAC) → the refusing device itself — never a jump onto
    /// speakers the user wasn't hearing, never a default left on EQtargets
    /// Audio with nothing reading it (silence).
    static func restoreChoice(devices: [OutputDevice], currentUID: String?, recentUIDs: [String],
                              excluding: String? = nil) -> OutputDevice? {
        let routable = devices.filter(isRoutable)
        if let bad = excluding, let refusing = routable.first(where: { $0.uid == bad }) {
            // A device that is still present refused to play.
            // 1. The device we were playing on a moment ago (route() keeps it
            //    as current on refusal): no surprise, whatever kind it is.
            if let c = currentUID, c != bad, let d = routable.first(where: { $0.uid == c }) { return d }
            // 2. A recent PERSONAL device. Never jump to laptop speakers / TV /
            //    AirPlay the user wasn't just hearing (AirPods that fail to
            //    start must not put the music on the speakers in a café), nor
            //    to a virtual device (silent) or an aggregate (may include the
            //    speakers).
            let quiet = routable.filter { $0.uid != bad && isPersonal($0) }
            for uid in recentUIDs where uid != bad {
                if let d = quiet.first(where: { $0.uid == uid }) { return d }
            }
            // 3. The refusing device itself: the user's (or macOS's) latest
            //    choice. Unprocessed sound there beats a default left on
            //    EQtargets Audio with nothing reading it (silence).
            return refusing
        }
        if let c = currentUID, let d = routable.first(where: { $0.uid == c }) { return d }
        return fallbackChoice(devices: routable, pinnedUID: nil, recentUIDs: recentUIDs, excluding: nil)
    }

    /// Devices a refused-route restore may move sound to without the user
    /// having been on them: headphones and desk DACs (Bluetooth, USB,
    /// Thunderbolt). Built-in (speakers, but also the jack), HDMI/DisplayPort,
    /// AirPlay, virtual and aggregate devices are not — conservative on purpose.
    static func isPersonal(_ d: OutputDevice) -> Bool {
        switch d.transport {
        case .bluetooth, .usb, .thunderbolt: return true
        default: return false
        }
    }

    /// "Follow macOS" (adopt whatever the user / macOS makes the default
    /// output) applies unless a pinned device is actually PRESENT. A pin whose
    /// device is away (the desk DAC, at a café) must not make every Control
    /// Center pick bounce back while sound plays on a fallback.
    static func followsMacDefault(pinnedUID: String?, devices: [OutputDevice]) -> Bool {
        guard let p = pinnedUID else { return true }
        return !devices.contains { $0.uid == p && isRoutable($0) }
    }

    /// After a fallback (the device we played on vanished), the device we fell
    /// back FROM is back: return to it. macOS would, but it can't here: its
    /// default output stays EQtargets Audio throughout. Follow-macOS only — a
    /// present pin has its own return path. nil = stay.
    static func returnChoice(devices: [OutputDevice], fellBackFrom: String?, currentUID: String?,
                             pinnedUID: String?) -> OutputDevice? {
        guard followsMacDefault(pinnedUID: pinnedUID, devices: devices),
              let back = fellBackFrom, back != currentUID else { return nil }
        return devices.first { $0.uid == back && isRoutable($0) }
    }

    /// Readers OTHER than this process, from the driver's 'eqta' count (which
    /// includes us while we are attached). nil = the driver can't tell.
    static func otherReaders(reported: Double?, attachedHere: Bool) -> Int? {
        guard let n = reported else { return nil }
        let total = n.isFinite ? Int(min(max(n, 0), 1_000)) : 0
        return max(total - (attachedHere ? 1 : 0), 0)
    }

    /// macOS's default output is EQtargets Audio but THIS engine is not
    /// playing what reaches it (off, failed, stepped aside, not routed yet):
    /// the Mac is silent unless another process reads the ring. `otherReaders`
    /// is `otherReaders(reported:attachedHere:)`, nil when the driver can't
    /// tell (older driver) — then assume nobody.
    static func mustReleaseDefault(defaultIsOurs: Bool, poweredAndRouted: Bool, otherReaders: Int?) -> Bool {
        defaultIsOurs && !poweredAndRouted && (otherReaders ?? 0) == 0
    }

    /// The driver rate to run the virtual device at for a real device running at
    /// `rate`: the same rate when the driver supports it (no resampling at all
    /// beyond drift), else the lowest supported rate above it, else the highest.
    static func virtualRate(matching rate: Double) -> Double {
        guard rate.isFinite, rate > 0 else { return 48_000 }
        if let exact = driverRates.first(where: { abs($0 - rate) < 0.5 }) { return exact }
        return driverRates.first(where: { $0 > rate }) ?? driverRates[driverRates.count - 1]
    }

    /// Most-recent-first list with `uid` moved to the front, at most `limit`.
    static func remember(_ uid: String, in recent: [String], limit: Int = 8) -> [String] {
        guard uid != EQT_DEVICE_UID else { return recent }
        return Array(([uid] + recent.filter { $0 != uid }).prefix(limit))
    }

    /// Device list order: the current output first, then by name.
    static func sorted(_ devices: [OutputDevice], currentUID: String?) -> [OutputDevice] {
        devices.sorted { a, b in
            let ac = a.uid == currentUID, bc = b.uid == currentUID
            if ac != bc { return ac }
            let byName = a.name.localizedStandardCompare(b.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return a.uid < b.uid
        }
    }
}

enum VolumeLaw {

    /// The driver's taper (Driver/README.md): dB = 60·log10(F + (1−F)·s),
    /// F = 10^(−64/60), so s = 0 → −64 dB and s = 1 → 0 dB. Used only if the
    /// virtual device can't report its own dB value.
    static let floorDB = -64.0

    static func decibels(forScalar s: Double) -> Double {
        let f = pow(10, floorDB / 60)
        let x = min(max(s.isFinite ? s : 1, 0), 1)
        return min(max(60 * log10(f + (1 - f) * x), floorDB), 0)
    }

    /// The parameters the chain actually runs: the app's, plus the volume keys'
    /// position when the real device can't take it in hardware.
    ///
    /// - hardwareVolume / hardwareMute: the real device's own controls were
    ///   set from the virtual device's, so the chain must NOT also attenuate.
    /// - volumeDB: the virtual device's own dB for `volume` (nil → driver taper).
    /// - A scalar of 0 is silence, as the volume slider's bottom end is everywhere.
    /// The volume of a device whose volume is only per-channel (L/R), as
    /// macOS shows it: the loudest channel. nil if nothing was read.
    static func combinedVolume(_ channels: [Float]) -> Float? {
        let v = channels.filter(\.isFinite)
        guard !v.isEmpty, v.count == channels.count, let loudest = v.max() else { return nil }
        return min(max(loudest, 0), 1)
    }

    /// New per-channel values that move a per-channel-only device to
    /// `target` (its loudest channel) while KEEPING its L/R balance: every
    /// channel is scaled by target / loudest. Writing `target` to each channel
    /// would centre the balance on the first volume-key press. With no usable
    /// balance (all silent or unreadable) every channel gets `target`.
    static func channelVolumes(current: [Float], target: Float) -> [Float] {
        let t = min(max(target.isFinite ? target : 0, 0), 1)
        guard let loudest = combinedVolume(current), loudest > 1e-4 else {
            return Array(repeating: t, count: current.count)
        }
        return current.map { min(max($0 / loudest * t, 0), 1) }
    }

    static func fold(_ app: ChainParameters, volume: Float, muted: Bool, volumeDB: Double?,
                     hardwareVolume: Bool, hardwareMute: Bool) -> ChainParameters {
        var p = app
        if !hardwareVolume {
            let s = Double(volume.isFinite ? min(max(volume, 0), 1) : 1)
            if s <= 0 {
                p.outputMuted = true
            } else {
                let db = volumeDB.flatMap { $0.isFinite ? $0 : nil } ?? decibels(forScalar: s)
                p.outputGainDB = app.outputGainDB + min(db, 0)
            }
        }
        if muted && !hardwareMute { p.outputMuted = true }
        return p
    }
}

enum LatencyMath {

    /// What the UI shows: ring fill + chain lookahead + the real device's own
    /// presentation latency, in milliseconds.
    static func engineLatencyMs(ringSeconds: Double, chainFrames: Int, deviceFrames: Int, outputRate: Double) -> Double {
        guard outputRate > 0 else { return 0 }
        let s = max(0, ringSeconds) + Double(max(0, chainFrames) + max(0, deviceFrames)) / outputRate
        return s * 1000
    }

    /// What the driver adds to its reported latency ('eqtl'), in frames at the
    /// VIRTUAL device's rate: ring target fill (already source frames) plus the
    /// output-side latencies converted from the output rate.
    static func driverReportFrames(ringTargetFrames: Double, chainFrames: Int, deviceFrames: Int,
                                   outputRate: Double, sourceRate: Double) -> Int {
        // Every input can come from shared memory another process writes, so
        // nothing non-finite or absurd may reach Int() (it traps).
        guard outputRate.isFinite, sourceRate.isFinite, outputRate > 0, sourceRate > 0,
              ringTargetFrames.isFinite else { return 0 }
        let outSide = Double(max(0, chainFrames) + max(0, deviceFrames)) * sourceRate / outputRate
        let v = max(0, ringTargetFrames) + outSide
        guard v.isFinite else { return 0 }
        return Int(min(v, 1e9).rounded())
    }
}

/// Counts events in a sliding time window. "Follow macOS" sets the default
/// output back to EQtargets Audio every time something else takes it; if some
/// other app keeps taking it, the two would fight forever. Past `limit` events
/// in `window` seconds the engine steps aside instead.
struct BurstGuard: Equatable {
    var limit: Int
    var window: Double
    private var times: [Double] = []

    init(limit: Int, window: Double) {
        self.limit = limit
        self.window = window
    }

    /// Records an event at `now` (seconds). Returns false once the burst limit
    /// is exceeded.
    mutating func record(at now: Double) -> Bool {
        times = times.filter { now - $0 < window }
        times.append(now)
        return times.count <= limit
    }

    mutating func reset() { times.removeAll() }
}
