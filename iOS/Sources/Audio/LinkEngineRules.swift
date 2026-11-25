//
//  LinkEngineRules.swift
//  EQtargets (iOS)
//
//  The engine's decisions as plain values: no AVAudioSession, no threads. Most of
//  the live route can only run on a device, so everything that can be separated
//  from it is kept here, where the logic tests can reach it.
//

import Foundation

enum EngineStatus: Equatable {
    case off
    case starting
    /// On and listening, but EQtargets is not selected in Control Center.
    case waiting
    /// Selected, and nothing is playing.
    case idle
    /// Other apps' audio is flowing through the EQ.
    case running
    /// A call, Siri or another exclusive session took the audio.
    case interrupted
    /// This app's own output points at the EQtargets route. Output is muted so
    /// the audio cannot feed back into itself.
    case feedbackGuard
    /// Turned off while EQtargets is still the selected output. Audio keeps
    /// flowing unprocessed, because an app cannot change the system route and
    /// stopping would silence every app on the phone.
    case passThrough
    case error(String)
}

struct EngineStats: Equatable {
    var sampleRate: Double = 0
    var outputBufferFrames = 0
    /// Link buffer + chain + output device, in milliseconds.
    var latencyMs: Double = 0
    var driftPPM: Double = 0
    var underruns = 0
    var resyncs = 0
    /// Render time / buffer period, 0...1, smoothed.
    var cpuLoad: Double = 0
    var reserveFrames = 0
}

enum LinkStatusRule {
    /// How long after the last chunk the stream still counts as playing.
    static let audioHoldSeconds: TimeInterval = 0.5

    /// One answer for the whole UI. Order matters: a failure or a safety state
    /// must never be hidden behind "running".
    static func status(isPowered: Bool, passThrough: Bool = false, engineRunning: Bool, failure: String?,
                       interrupted: Bool, feedback: Bool, hasPeer: Bool,
                       secondsSinceAudio: TimeInterval) -> EngineStatus {
        guard isPowered || passThrough else { return .off }
        if let failure { return .error(failure) }
        if interrupted { return .interrupted }
        guard engineRunning else { return .starting }
        if feedback { return .feedbackGuard }
        if !isPowered { return .passThrough }
        guard hasPeer else { return .waiting }
        return secondsSinceAudio < audioHoldSeconds ? .running : .idle
    }
}

/// What On and Off mean when an app cannot change the system route.
///
/// If EQtargets is the selected output and nothing plays what reaches it, every
/// app on the phone goes silent. So whenever a peer is connected the engine keeps
/// running, and Off only bypasses the EQ. While Off with the app open, picking
/// EQtargets starts the audio in bypass. A suspended app cannot accept the
/// connection, so that case stays silent until the app is opened.
struct LinkPowerState: Equatable {
    enum Effect: Equatable { case none, startEngine, stopEngine, updateBypass }

    /// How long a peer must be gone before pass-through really stops. A brief
    /// reconnect must not tear the audio session down.
    static let peerGraceSeconds: TimeInterval = 2

    private(set) var isPowered = false
    private(set) var passThrough = false

    var isLive: Bool { isPowered || passThrough }

    /// A peer that left a moment ago is usually reconnecting, and stopping the
    /// engine now would leave it connected to nothing: every app would go silent.
    mutating func setPowered(_ on: Bool, hasPeer: Bool, secondsSincePeer: TimeInterval = .infinity) -> Effect {
        guard on != isPowered else { return .none }
        isPowered = on
        if on {
            guard passThrough else { return .startEngine }
            passThrough = false
            return .updateBypass
        }
        guard hasPeer || secondsSincePeer < Self.peerGraceSeconds else { return .stopEngine }
        passThrough = true
        return .updateBypass
    }

    /// Called on every engine tick.
    mutating func observe(hasPeer: Bool, secondsSincePeer: TimeInterval) -> Effect {
        guard !isPowered else { return .none }
        if passThrough {
            guard !hasPeer, secondsSincePeer >= Self.peerGraceSeconds else { return .none }
            passThrough = false
            return .stopEngine
        }
        guard hasPeer else { return .none }
        passThrough = true
        return .startEngine
    }
}

enum LinkRoute {
    /// Matched by name: the virtual device reports the same port type as a real
    /// AirPlay speaker, so the type cannot tell them apart.
    static func isOwnRoute(portName: String) -> Bool {
        portName.range(of: EQT_ROUTE_NAME, options: [.caseInsensitive]) != nil
    }

    /// The real output among the session's outputs: never our own virtual device.
    static func realOutput(names: [String]) -> Int? {
        names.firstIndex { !isOwnRoute(portName: $0) }
    }
}

/// When a hardware rate change is real enough to rebuild the audio graph. The
/// rate can settle just after a start, and rebuilding on the first mismatch
/// would stop and restart the audio every second.
struct RateChangeWatch {
    static let ticksRequired = 3
    static let settleSeconds: TimeInterval = 1

    private(set) var mismatchTicks = 0

    mutating func observe(builtRate: Double?, hardwareRate: Double, now: TimeInterval,
                          lastStart: TimeInterval) -> Bool {
        let mismatch: Bool
        if let builtRate, hardwareRate > 0 {
            mismatch = abs(hardwareRate - builtRate) >= 1
        } else {
            mismatch = false
        }
        mismatchTicks = mismatch ? mismatchTicks + 1 : 0
        guard mismatchTicks >= Self.ticksRequired, now - lastStart >= Self.settleSeconds else {
            return false
        }
        mismatchTicks = 0
        return true
    }
}

/// When the app must hold a background task so iOS cannot suspend it.
///
/// iOS keeps a background app running only while its audio plays. A headphone
/// switch can stop the engine, and a suspended app cannot answer the extension,
/// which gives the route back after 5 s: EQtargets drops out of Control Center.
/// So the app asks to stay awake while the engine should be playing and is not,
/// and for a short watch after every headphone change, because the engine can
/// stop a moment after the change is reported. iOS grants about 30 s and may
/// refuse.
struct KeepAwakeRule: Equatable {
    /// Longer than `InterruptionRetry.seconds`, so a switch that arrives with an
    /// interruption is still covered when that retry comes due.
    static let routeWatchSeconds: TimeInterval = 8

    private(set) var watchUntil: TimeInterval = -.infinity
    /// iOS ended or refused the last task. Asking again at once would loop, so
    /// the next request waits for a new headphone change, the app being opened,
    /// or a moment when nothing needs the task.
    private(set) var exhausted = false

    /// `causedByApp`: a category change or output override this app made
    /// itself. Its own restarts must not re-arm the rule.
    mutating func routeChanged(now: TimeInterval, causedByApp: Bool) {
        guard !causedByApp else { return }
        watchUntil = now + Self.routeWatchSeconds
        exhausted = false
    }

    mutating func taskExpired() {
        exhausted = true
    }

    /// Whether a task should be held now. Also re-arms after an expiry once
    /// nothing needs the task. `live`: the engine is meant to be playing (On,
    /// or passing audio through).
    mutating func evaluate(live: Bool, interrupted: Bool, engineRunning: Bool,
                           foreground: Bool, now: TimeInterval) -> Bool {
        let watching = now < watchUntil
        // During a call iOS owns the audio and tells the app when it may resume.
        let recovering = live && !engineRunning && !interrupted
        if !live || foreground || (!recovering && !watching) { exhausted = false }
        guard live, !exhausted else { return false }
        return recovering || watching
    }
}

/// While a call or Siri holds the audio, the engine tries to take it back this
/// often. Apple does not guarantee an `.ended` for every `.began`.
enum InterruptionRetry {
    static let seconds: TimeInterval = 5
}

/// While live, the engine's timer fires at least once a second. A longer gap
/// means iOS suspended the app or its main thread was blocked. The link thread
/// keeps answering through a blocked main thread, but not through a suspension.
///
/// The uptime clock stops while the phone sleeps and the wall clock does not,
/// so both are kept: a suspension spent asleep shows only on the wall clock.
struct TickGapWatch: Equatable {
    static let reportSeconds: TimeInterval = 3

    struct Gap: Equatable {
        let awakeSeconds: TimeInterval
        let clockSeconds: TimeInterval
        /// When the last tick before the gap ran.
        let since: Date
    }

    private(set) var lastLiveTick: TimeInterval?
    private(set) var lastLiveDate: Date?

    /// The gap to report before this tick, if any.
    mutating func tick(now: TimeInterval, date: Date, live: Bool) -> Gap? {
        defer {
            lastLiveTick = live ? now : nil
            lastLiveDate = live ? date : nil
        }
        guard let last = lastLiveTick, let lastDate = lastLiveDate else { return nil }
        let gap = Gap(awakeSeconds: now - last, clockSeconds: date.timeIntervalSince(lastDate), since: lastDate)
        guard max(gap.awakeSeconds, gap.clockSeconds) > Self.reportSeconds else { return nil }
        return gap
    }

    /// The timer was stopped on purpose, so the next gap is not a suspension.
    mutating func timerStopped() {
        lastLiveTick = nil
        lastLiveDate = nil
    }
}

/// iOS pauses music when headphones go away because the music app's own output
/// disappears. With EQtargets picked, the music app plays to EQtargets, which
/// stays, so nothing pauses and the song carries on from the speaker. No app can
/// pause another app's playback: taking the audio without mixing was tried on
/// the phone (2026-11-25), every step succeeded and the music kept playing. So
/// EQtargets mutes instead, and stays picked for the next headphones.
enum HeadphoneRemoval {
    /// `AVAudioSession.Port` raw values of the phone's own outputs (a test
    /// checks them against the SDK). Everything else is external: wired,
    /// Bluetooth, USB, car.
    static let builtInOutputTypes: Set<String> = ["Speaker", "Receiver"]
    /// Audio counts as playing if it was not exactly silent this recently.
    static let playingWithinSeconds: TimeInterval = 0.25

    struct Port: Equatable {
        let name: String
        let type: String
    }

    static func isExternal(_ port: Port) -> Bool {
        !builtInOutputTypes.contains(port.type) && !LinkRoute.isOwnRoute(portName: port.name)
    }

    /// `deviceGone`: the route change reason is `oldDeviceUnavailable`.
    /// Only a landing on the phone itself mutes: going from one pair of
    /// headphones to another must never drop the sound.
    static func shouldMute(deviceGone: Bool, previousOutputs: [Port], newOutputs: [Port], live: Bool,
                           hasPeer: Bool, streamActive: Bool, alreadyMuted: Bool) -> Bool {
        let onThePhone = !newOutputs.isEmpty && newOutputs.allSatisfy { builtInOutputTypes.contains($0.type) }
        return deviceGone && onThePhone && live && hasPeer && streamActive && !alreadyMuted
            && previousOutputs.contains(where: isExternal)
    }
}

/// Frames of unbroken exact silence in the incoming audio, counted on the
/// render thread. It starts at 0 on every (re)start, so a restart never reads as
/// a long pause, and any audible block resets it, so a short sound between two
/// looks from the main thread is never missed. Capped so it cannot overflow.
struct SilenceRun: Equatable {
    static let capSeconds: Double = 10

    private(set) var frames = 0
    let cap: Int

    init(sampleRate: Double) {
        cap = Int(Self.capSeconds * max(sampleRate, 1))
    }

    mutating func advance(_ count: Int, silent: Bool) {
        frames = silent ? min(frames + max(count, 0), cap) : 0
    }
}

/// The mute after headphones come off. It lasts until headphones are back,
/// EQtargets is no longer picked, the power is changed, or the music has been
/// paused: then pressing play on the speaker is heard at once. No timer brings
/// the sound back by itself, or the speaker would start playing on its own.
struct RemovalMute: Equatable {
    /// Unbroken exact silence this long (`SilenceRun`) means the music was
    /// paused. A gap between songs is shorter.
    static let pausedAfterSeconds: TimeInterval = 2

    enum Release: Equatable { case headphonesBack, notPicked, musicPaused }

    private(set) var isMuted = false

    mutating func begin() {
        isMuted = true
    }

    mutating func cancel() {
        isMuted = false
    }

    /// `secondsOfSilence`: unbroken exact silence so far (0 right after a
    /// restart). `secondsSincePeer`: 0 while EQtargets is picked; a link that
    /// reconnects within the grace is still picked.
    mutating func observe(secondsOfSilence: Double, onExternalOutput: Bool,
                          secondsSincePeer: TimeInterval) -> Release? {
        guard isMuted else { return nil }
        let release: Release?
        if onExternalOutput {
            release = .headphonesBack
        } else if secondsSincePeer >= LinkPowerState.peerGraceSeconds {
            release = .notPicked
        } else if secondsOfSilence >= Self.pausedAfterSeconds {
            release = .musicPaused
        } else {
            release = nil
        }
        if release != nil { cancel() }
        return release
    }
}

/// Tries a bounded number of times to move this app's output off its own route.
/// Each attempt causes a route change, and repeating them breaks the media
/// session, so after the limit the engine simply stays muted.
struct FeedbackEscape {
    enum Action: Equatable { case overrideToSpeaker, clearOverride }

    static let maxAttempts = 3
    static let retrySeconds: TimeInterval = 3

    private(set) var overriding = false
    private(set) var attempts = 0
    private var lastApply: TimeInterval = 0

    mutating func decide(onOwnRoute: Bool, onSpeaker: Bool, now: TimeInterval) -> Action? {
        if onOwnRoute {
            guard !overriding || now - lastApply >= Self.retrySeconds else { return nil }
            guard attempts < Self.maxAttempts else { return nil }
            overriding = true
            lastApply = now
            attempts += 1
            return .overrideToSpeaker
        }
        // The speaker may be the result of our own override: keep it until the
        // route has really moved somewhere else.
        guard overriding, !onSpeaker else { return nil }
        overriding = false
        attempts = 0
        lastApply = now
        return .clearOverride
    }

    mutating func reset() {
        overriding = false
        attempts = 0
        lastApply = 0
    }
}
