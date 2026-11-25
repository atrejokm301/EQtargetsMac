//
//  LinkEngine.swift
//  EQtargets (iOS)
//
//  Owns the audio session and output. The system mix arrives from the extension
//  over the loopback link, runs through the Mac app's reader and DSP chain, and
//  plays on the output that was in use before EQtargets was picked.
//
//  Rules measured on devices by the MIT-0 sample and by EffectDeck:
//  - The session is playAndRecord + mixWithOthers + allowBluetoothA2DP. Nothing
//    ever reads the microphone. Plain `playback` follows the system route, which
//    would be our own virtual device, and the only way back off that route
//    (`overrideOutputAudioPort`) requires playAndRecord.
//  - That category still gives the session an input. If it lands on a Bluetooth
//    mic, the whole link drops to HFP (16 or 32 kHz mono), so it stays pinned to
//    the built-in mic. allowBluetoothA2DP alone does not prevent this.
//  - Never put an AVRoutePickerView on screen. It joins this app to the shared
//    output context, so when EQtargets is picked this app's own session follows
//    it onto the virtual device and the audio feeds back into itself.
//  - Never use MPNowPlayingInfoCenter, for the same reason.
//  - The engine keeps running in silence while On, even with no peer. iOS only
//    keeps a background app alive while it plays, and a suspended app cannot
//    accept the extension's connection.
//

import AVFoundation
import Observation
import UIKit
import os

@MainActor
@Observable
final class LinkEngine: EngineDriving {

    private(set) var status: EngineStatus = .off
    private(set) var isPowered = false
    private(set) var currentOutput: OutputDevice?
    private(set) var stats = EngineStats()
    @ObservationIgnored var onOutputChanged: ((OutputDevice?) -> Void)?

    @ObservationIgnored private let log = Logger(subsystem: EQT_LOG_SUBSYSTEM, category: "engine")
    @ObservationIgnored private let ring: UnsafeMutablePointer<EQTRingHeader>
    @ObservationIgnored private let receiver: OpaquePointer
    @ObservationIgnored private let context: LinkRenderContext
    @ObservationIgnored private var engine = AVAudioEngine()
    @ObservationIgnored private var sourceNode: AVAudioSourceNode?
    @ObservationIgnored private var builtRate: Double?
    @ObservationIgnored private var power = LinkPowerState()
    @ObservationIgnored private var failure: String?
    @ObservationIgnored private var interrupted = false
    @ObservationIgnored private var feedback = false
    @ObservationIgnored private var lastStartAttempt: TimeInterval = -.infinity
    @ObservationIgnored private var lastReceived: UInt64 = 0
    @ObservationIgnored private var lastAudioAt: TimeInterval = -.infinity
    @ObservationIgnored private var lastPeerAt: TimeInterval = -.infinity
    @ObservationIgnored private var hadPeer = false
    @ObservationIgnored private var rateWatch = RateChangeWatch()
    @ObservationIgnored private var escape = FeedbackEscape()
    @ObservationIgnored private var lastParameters: ChainParameters?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var timerInterval: TimeInterval = 0
    @ObservationIgnored private var foreground = true
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var smoothedLoad = 0.0
    @ObservationIgnored private var interruptedAt: TimeInterval = 0
    @ObservationIgnored private var listenerLostAt: TimeInterval?
    @ObservationIgnored private var hasLinkKey = false
    @ObservationIgnored private var watchUntil: TimeInterval = 0
    @ObservationIgnored private var watchTask = UIBackgroundTaskIdentifier.invalid
    @ObservationIgnored private let keepAwake: KeepAwakeHolder
    @ObservationIgnored private let journal: LinkJournal
    @ObservationIgnored private var tickGap = TickGapWatch()
    @ObservationIgnored private var removalMute = RemovalMute()

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private static let listenerGraceSeconds: TimeInterval = 3

    /// `port` exists so tests and the Preview build can use a private port.
    init(port: UInt16 = UInt16(EQT_LINK_PORT), journal: LinkJournal? = nil) {
        let journal = journal ?? LinkJournal()
        self.journal = journal
        keepAwake = KeepAwakeHolder.live(note: { journal.add($0, important: true) })
        journal.add("app started", important: true)
        let bytes = Int(EQTRingTotalBytes())
        let memory = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 4096)
        ring = memory.bindMemory(to: EQTRingHeader.self, capacity: 1)
        EQTLinkRingFormat(ring)
        guard let receiver = EQTLinkReceiverCreate(port, ring) else {
            fatalError("Could not allocate the audio link")
        }
        self.receiver = receiver
        #if DEBUG && !EQT_HAS_EXTENSION
        let silentOutput = DemoFeeder.isRequested
        #else
        let silentOutput = false
        #endif
        context = LinkRenderContext(ring: UnsafePointer(ring), receiver: receiver, silentOutput: silentOutput)
        observeSession()
        refreshRoute()
        loadLinkKey()       // before listening: callers are checked against it
        // Listening from launch, even while Off: EQtargets may already be the
        // selected output, and nobody listening would mean silence in every app.
        _ = EQTLinkReceiverStart(receiver)
        updateTimer()
        keepAwake.onExpired = { [weak self] in self?.updateTimer() }
    }

    // MARK: EngineDriving

    func setPowered(_ on: Bool) {
        guard on != power.isPowered else { return }
        failure = nil
        let hasPeer = currentlyHasPeer
        if hasPeer { lastPeerAt = Self.now }
        perform(power.setPowered(on, hasPeer: hasPeer, secondsSincePeer: Self.now - lastPeerAt))
    }

    func retry() {
        guard power.isLive else { return }
        loadLinkKey()
        failure = nil
        listenerLostAt = nil
        interrupted = false
        if ensureListening() { startAudio() }
        publishStatus()
    }

    func apply(_ parameters: ChainParameters) {
        lastParameters = parameters
        pushParameters()
    }

    func meters() -> ChainMeters {
        context.chain.meters()
    }

    func setForeground(_ foreground: Bool) {
        guard foreground != self.foreground else { return }
        self.foreground = foreground
        journal.add(foreground ? "app opened" : "app in the background")
        if foreground, interrupted { interruptedAt = 0 }    // retry on the next tick
        updateTimer()
    }

    func watchForPeer() {
        watchUntil = Self.now + LinkPowerState.peerGraceSeconds + 1
        if watchTask == .invalid {
            watchTask = UIApplication.shared.beginBackgroundTask(withName: "EQtargets tile") { [weak self] in
                MainActor.assumeIsolated { self?.endWatch() }
            }
        }
        updateTimer()
    }

    private func endWatch() {
        watchUntil = 0
        releaseWatchTask()
        updateTimer()
    }

    private func releaseWatchTask() {
        guard watchTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(watchTask)
        watchTask = .invalid
    }

    // MARK: Power

    private func perform(_ effect: LinkPowerState.Effect) {
        if isPowered != power.isPowered { isPowered = power.isPowered }
        if effect != .none {
            journal.add("power \(power.isPowered ? "on" : "off") passThrough=\(power.passThrough) \(effect)",
                        important: true)
            // Off with EQtargets selected only bypasses, and the mute applies in
            // bypass too: without this, the whole phone would stay silent.
            liftRemovalMute("power changed")
        }
        switch effect {
        case .none:
            break
        case .updateBypass:
            pushParameters()
        case .startEngine:
            pushParameters()
            if ensureListening() { startAudio() }
        case .stopEngine:
            stopEngine()
        }
        updateTimer()
        publishStatus()
    }

    private var currentlyHasPeer: Bool {
        var s = EQTLinkReceiverStats()
        EQTLinkReceiverGetStats(receiver, &s)
        return s.hasPeer != 0
    }

    private func ensureListening() -> Bool {
        let e = EQTLinkReceiverStart(receiver)
        guard e != 0 else { return true }
        failure = "The audio link could not open (error \(e)). Force-quit EQtargets and open it again."
        return false
    }

    private func pushParameters() {
        var p = lastParameters ?? ChainParameters()
        if power.passThrough { p.masterBypass = true }
        // The chain ramps this over 20 ms, so the mute never clicks.
        if removalMute.isMuted { p.outputMuted = true }
        context.chain.setParameters(p)
    }

    /// Stops the audio so iOS can suspend the app and Off really costs no battery.
    /// The listener stays open, but a suspended app cannot accept: picking
    /// EQtargets while Off and in the background is silent until the app opens.
    private func stopEngine() {
        stopAudio()
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            log.notice("session deactivate: \(error.localizedDescription, privacy: .public)")
        }
        interrupted = false
        feedback = false
        failure = nil
        listenerLostAt = nil
        escape.reset()
        liftRemovalMute("turned off")
        context.setMuted(false)
        pushParameters()
        stats = EngineStats()
    }

    // MARK: Start / stop

    private func configureSession(_ session: AVAudioSession) throws {
        #if targetEnvironment(simulator)
        // No virtual route exists here, and playAndRecord opens the Mac's real
        // microphone and deadlocks AURemoteIO while the engine initializes.
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        #else
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.defaultToSpeaker, .mixWithOthers, .allowBluetoothA2DP])
        #endif
        try session.setPreferredSampleRate(EQT_LINK_SAMPLE_RATE)
        try session.setPreferredIOBufferDuration(0.01)
        try session.setActive(true)
        #if !targetEnvironment(simulator)
        pinInputToBuiltInMic(session, route: nil)
        // Leave a stale override in place only if we are escaping our own route.
        let onOwnRoute = session.currentRoute.outputs.contains { LinkRoute.isOwnRoute(portName: $0.portName) }
        // While escaping, the route reads "speaker" because of the override, so
        // clearing it here would put the app straight back on its own route.
        if !onOwnRoute, !escape.overriding {
            try? session.overrideOutputAudioPort(.none)
            escape.reset()
        }
        #endif
    }

    /// `route` nil always applies the pin. Otherwise the real input decides:
    /// `preferredInput` is only a wish and can stay on the mic while the actual
    /// input has moved to Bluetooth.
    private func pinInputToBuiltInMic(_ session: AVAudioSession, route: AVAudioSessionRouteDescription?) {
        if let route, route.inputs.contains(where: { $0.portType == .builtInMic }) { return }
        guard let mic = session.availableInputs?.first(where: { $0.portType == .builtInMic }) else { return }
        do {
            try session.setPreferredInput(mic)
        } catch {
            log.notice("could not pin the input: \((error as NSError).code)")
        }
    }

    private func startAudio() {
        lastStartAttempt = Self.now
        stopAudio()

        let session = AVAudioSession.sharedInstance()
        do {
            try configureSession(session)
        } catch {
            let ns = error as NSError
            log.error("session failed \(ns.domain, privacy: .public) \(ns.code)")
            journal.add("session failed \(ns.domain) \(ns.code)")
            failure = "iOS would not start the audio session (\(ns.code)). Close other audio apps and try again."
            publishStatus()
            return
        }

        let rate = session.sampleRate > 0 ? session.sampleRate : EQT_LINK_SAMPLE_RATE
        let bufferFrames = max(64, Int((session.ioBufferDuration * rate).rounded()))
        context.prepare(sampleRate: rate, bufferFrames: bufferFrames)

        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else {
            failure = "The audio format is not supported."
            publishStatus()
            return
        }
        let unmanaged = Unmanaged.passUnretained(context)
        let node = AVAudioSourceNode(format: format) { _, _, frames, buffers in
            unmanaged._withUnsafeGuaranteedRef { $0.render(frameCount: Int(frames), buffers: buffers) }
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        sourceNode = node

        do {
            try engine.start()
        } catch {
            let ns = error as NSError
            log.error("engine failed \(ns.domain, privacy: .public) \(ns.code)")
            journal.add("engine failed \(ns.domain) \(ns.code)")
            failure = "The audio engine could not start (\(ns.code))."
            context.quiesce()
            engine.detach(node)
            sourceNode = nil
            publishStatus()
            return
        }

        builtRate = rate
        failure = nil
        rateWatch = RateChangeWatch()
        stats.sampleRate = rate
        stats.outputBufferFrames = bufferFrames
        refreshRoute()
        publishStatus()
        log.notice("audio started rate=\(rate) buffer=\(bufferFrames)")
        journal.add("audio started rate=\(rate) buffer=\(bufferFrames) \(Self.summary(of: session.currentRoute))")
    }

    private func stopAudio() {
        guard let node = sourceNode else { return }
        if engine.isRunning { context.quiesce() }
        engine.stop()
        engine.detach(node)
        sourceNode = nil
        builtRate = nil
    }

    // MARK: Session events

    private func observeSession() {
        let center = NotificationCenter.default
        func observe(_ name: Notification.Name, object: AnyObject? = nil,
                     _ handler: @escaping @MainActor (LinkEngine, Notification) -> Void) {
            observers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] note in
                nonisolated(unsafe) let note = note
                MainActor.assumeIsolated {
                    guard let self else { return }
                    handler(self, note)
                }
            })
        }
        observe(AVAudioSession.routeChangeNotification) { engine, note in
            engine.routeDidChange(note)
        }
        observe(AVAudioSession.interruptionNotification) { engine, note in
            engine.handleInterruption(note)
        }
        observe(AVAudioSession.mediaServicesWereResetNotification) { engine, _ in
            engine.handleMediaServicesReset()
        }
        observe(.AVAudioEngineConfigurationChange) { engine, note in
            guard note.object as AnyObject? === engine.engine else { return }
            guard engine.power.isLive, !engine.interrupted else { return }
            engine.journal.add("engine configuration changed running=\(engine.engine.isRunning)")
            // Also when the restart has to wait: the app must stay awake until
            // the tick gets to it, or iOS suspends it with the audio down.
            defer { engine.publishStatus() }
            // The rate can settle just after a start. Rebuilding on every change
            // would stop and restart the audio each second. The tick retries
            // anything skipped here.
            guard engine.sourceNode == nil || !engine.engine.isRunning,
                  Self.now - engine.lastStartAttempt >= RateChangeWatch.settleSeconds else { return }
            engine.startAudio()
        }
    }

    /// Headphones connecting or leaving land here. The engine may stop a moment
    /// later, so the app stays awake for the watch even while it still plays.
    private func routeDidChange(_ note: Notification) {
        let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
        let previous = note.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
        journal.add("route changed reason=\(Self.reasonName(reason)) from \(previous.map { Self.summary(of: $0) } ?? "?") "
                    + "to \(Self.summary(of: AVAudioSession.sharedInstance().currentRoute))", important: true)
        // A category change or override is this app's own doing, not a new pair
        // of headphones, and must not re-arm the keep-awake.
        let causedByApp = reason == AVAudioSession.RouteChangeReason.categoryChange.rawValue
            || reason == AVAudioSession.RouteChangeReason.override.rawValue
        if power.isLive { keepAwake.routeChanged(now: Self.now, causedByApp: causedByApp) }
        let deviceGone = reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
        if HeadphoneRemoval.shouldMute(deviceGone: deviceGone, previousOutputs: Self.ports(previous?.outputs ?? []),
                                       newOutputs: Self.ports(AVAudioSession.sharedInstance().currentRoute.outputs),
                                       live: power.isLive, hasPeer: currentlyHasPeer,
                                       streamActive: streamActive, alreadyMuted: removalMute.isMuted) {
            removalMute.begin()
            pushParameters()
            journal.add("headphones removed: muted until the music is paused or headphones are back", important: true)
        }
        refreshRoute()
        publishStatus()
    }

    // MARK: Headphones removed

    /// Other apps' audio is flowing through EQtargets right now.
    private var streamActive: Bool {
        currentlyHasPeer && context.secondsOfSilence < HeadphoneRemoval.playingWithinSeconds
    }

    private static func ports(_ ports: [AVAudioSessionPortDescription]) -> [HeadphoneRemoval.Port] {
        ports.map { HeadphoneRemoval.Port(name: $0.portName, type: $0.portType.rawValue) }
    }

    private func updateRemovalMute() {
        let outputs = Self.ports(AVAudioSession.sharedInstance().currentRoute.outputs)
        let secondsSincePeer = currentlyHasPeer ? 0 : Self.now - lastPeerAt
        guard let release = removalMute.observe(secondsOfSilence: context.secondsOfSilence,
                                                onExternalOutput: outputs.contains(where: HeadphoneRemoval.isExternal),
                                                secondsSincePeer: secondsSincePeer)
        else { return }
        pushParameters()
        journal.add("unmuted: \(release)", important: true)
    }

    private func liftRemovalMute(_ why: String) {
        guard removalMute.isMuted else { return }
        removalMute.cancel()
        pushParameters()
        journal.add("unmuted: \(why)", important: true)
    }

    private static func reasonName(_ raw: UInt?) -> String {
        guard let raw, let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return "unknown" }
        switch reason {
        case .newDeviceAvailable: return "newDevice"
        case .oldDeviceUnavailable: return "oldDeviceGone"
        case .categoryChange: return "category"
        case .override: return "override"
        case .wakeFromSleep: return "wake"
        case .noSuitableRouteForCategory: return "noSuitableRoute"
        case .routeConfigurationChange: return "configuration"
        case .unknown: return "unknown"
        @unknown default: return "raw\(raw)"
        }
    }

    /// Port names and types, for the journal.
    private static func summary(of route: AVAudioSessionRouteDescription) -> String {
        let outputs = route.outputs.map { "\($0.portName)/\($0.portType.rawValue)" }.joined(separator: ",")
        let inputs = route.inputs.map(\.portType.rawValue).joined(separator: ",")
        return "[out \(outputs) | in \(inputs)]"
    }

    private func handleInterruption(_ note: Notification) {
        // No default for the type: rawValue 0 is `.began`, and a malformed
        // notification must not stop the audio.
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw), power.isLive else { return }
        switch type {
        case .began:
            journal.add("interruption began")
            interrupted = true
            interruptedAt = Self.now
            stopAudio()
        case .ended:
            interrupted = false
            // Without shouldResume the timer retries, so the EQ still comes back.
            let raw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let resume = AVAudioSession.InterruptionOptions(rawValue: raw).contains(.shouldResume)
            journal.add("interruption ended resume=\(resume)")
            if resume { startAudio() }
        @unknown default:
            interrupted = false
        }
        publishStatus()
    }

    /// The old engine and session configuration are dead.
    private func handleMediaServicesReset() {
        log.notice("media services were reset")
        journal.add("media services were reset")
        sourceNode = nil
        builtRate = nil
        engine = AVAudioEngine()
        interrupted = false
        lastStartAttempt = -.infinity
        if power.isLive { startAudio() }
    }

    // MARK: Timer

    /// 4 Hz while the user can see a live engine, 1 Hz otherwise. No timer at all
    /// when Off in the background, so iOS can suspend the app.
    private func updateTimer() {
        guard power.isLive || foreground || Self.now < watchUntil else {
            timer?.invalidate()
            timer = nil
            timerInterval = 0
            watchUntil = 0
            tickGap.timerStopped()
            releaseWatchTask()      // nothing is left to end it
            return
        }
        // Kept awake through a route change, the background gets the fast tick
        // too, so a stopped engine restarts within a second instead of two.
        let fast = power.isLive && (foreground || keepAwake.isHeld)
        let interval: TimeInterval = fast ? 0.25 : 1
        guard timer == nil || interval != timerInterval else { return }
        timer?.invalidate()
        timerInterval = interval
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = interval * 0.25
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        loadLinkKey()
        let now = Self.now
        if let gap = tickGap.tick(now: now, date: Date(), live: power.isLive) {
            journal.addGap(gap)
        }
        var link = EQTLinkReceiverStats()
        EQTLinkReceiverGetStats(receiver, &link)

        if link.receivedFrames != lastReceived {
            lastReceived = link.receivedFrames
            lastAudioAt = now
        }
        let hasPeer = link.hasPeer != 0
        if hasPeer != hadPeer {
            hadPeer = hasPeer
            context.requestReservePolicyReset()
            log.notice("peer \(hasPeer ? "connected" : "left", privacy: .public)")
            journal.add("peer \(hasPeer ? "connected" : "left") \(Self.summary(of: AVAudioSession.sharedInstance().currentRoute))",
                        important: true)
        }
        if hasPeer { lastPeerAt = now }

        let effect = power.observe(hasPeer: hasPeer, secondsSincePeer: now - lastPeerAt)
        if effect != .none { perform(effect) }
        if watchUntil > 0, now >= watchUntil { endWatch() }
        guard power.isLive else {
            _ = EQTLinkReceiverStart(receiver)      // a failed bind gets another chance
            return
        }
        guard ensureListening() else {
            publishStatus()
            return
        }

        if link.listening != 0 {
            listenerLostAt = nil
        } else if listenerLostAt == nil {
            listenerLostAt = now
        }

        // No `.ended` may ever arrive. If the session can be activated again,
        // the interruption is over.
        if interrupted, now - interruptedAt >= InterruptionRetry.seconds {
            interruptedAt = now
            if (try? AVAudioSession.sharedInstance().setActive(true)) != nil {
                interrupted = false
                startAudio()
            }
        }

        // A pause also ends in an underrun, so a quiet stream drops back to the
        // shallow reserve instead of keeping that latency for the whole session.
        if now - lastAudioAt > 1, link.reserveFrames != UInt32(EQT_LINK_DEFAULT_RESERVE) {
            context.requestReservePolicyReset()
        }

        if sourceNode == nil || !engine.isRunning, !interrupted,
           now - lastStartAttempt >= RateChangeWatch.settleSeconds {
            startAudio()
        }

        refreshRoute()
        let hardware = AVAudioSession.sharedInstance().sampleRate
        if sourceNode != nil, rateWatch.observe(builtRate: builtRate, hardwareRate: hardware,
                                                now: now, lastStart: lastStartAttempt) {
            log.notice("hardware rate changed to \(hardware), rebuilding")
            startAudio()
        }

        if removalMute.isMuted { updateRemovalMute() }
        updateStats(link: link)
        publishStatus()
    }

    private func updateStats(link: EQTLinkReceiverStats) {
        let r = context.reader.stats()
        var s = stats
        s.driftPPM = r.driftPPM
        s.underruns = r.underruns
        s.resyncs = r.resyncs
        s.reserveFrames = Int(link.reserveFrames)
        let session = AVAudioSession.sharedInstance()
        let chainSeconds = s.sampleRate > 0 ? Double(context.chain.latencyFrames) / s.sampleRate : 0
        s.latencyMs = (r.latencySeconds + chainSeconds + session.outputLatency) * 1000
        smoothedLoad += (context.takeLoad() - smoothedLoad) * 0.3
        s.cpuLoad = smoothedLoad
        // Only while someone can see it: every assignment re-renders observers.
        if foreground, s != stats { stats = s }
    }

    private func loadLinkKey() {
        guard !hasLinkKey, let key = LinkKey.loadOrCreate() else { return }
        EQTLinkReceiverSetKey(receiver, key)
        hasLinkKey = true
    }

    /// Without the key every caller is refused, so the app must say why it is silent.
    private var linkKeyFailure: String? {
        hasLinkKey ? nil : "EQtargets could not open its secure key. Restart your iPhone and try again."
    }

    private var listenerFailure: String? {
        guard let lost = listenerLostAt, Self.now - lost >= Self.listenerGraceSeconds else { return nil }
        return "The audio link closed. Force-quit EQtargets and open it again."
    }

    private func publishStatus() {
        let next = LinkStatusRule.status(
            isPowered: power.isPowered,
            passThrough: power.passThrough,
            engineRunning: sourceNode != nil && engine.isRunning,
            failure: failure ?? linkKeyFailure ?? listenerFailure,
            interrupted: interrupted,
            feedback: feedback,
            hasPeer: currentlyHasPeer,
            secondsSinceAudio: Self.now - lastAudioAt)
        if next != status { status = next }
        // Every change to the engine's state ends here, so this is where the
        // app decides whether it must stay awake.
        updateKeepAwake()
    }

    // MARK: Keep awake

    /// See `KeepAwakeRule` and `KeepAwakeHolder`.
    private func updateKeepAwake() {
        let changed = keepAwake.update(live: power.isLive, interrupted: interrupted,
                                       engineRunning: sourceNode != nil && engine.isRunning,
                                       foreground: foreground, now: Self.now)
        if changed { updateTimer() }
    }

    // MARK: Route

    private func refreshRoute() {
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute
        let outputs = route.outputs
        let names = outputs.map(\.portName)

        let own = names.contains { LinkRoute.isOwnRoute(portName: $0) }
        if power.isLive {
            #if !targetEnvironment(simulator)
            pinInputToBuiltInMic(session, route: route)
            #endif
            let onSpeaker = outputs.contains { $0.portType == .builtInSpeaker }
            switch escape.decide(onOwnRoute: own, onSpeaker: onSpeaker, now: Self.now) {
            case .overrideToSpeaker?:
                log.notice("output points at EQtargets, moving it off")
                journal.add("output points at EQtargets, moving it off")
                try? session.overrideOutputAudioPort(.speaker)
            case .clearOverride?:
                journal.add("output left EQtargets, clearing the override")
                try? session.overrideOutputAudioPort(.none)
            case nil:
                break
            }
            if own != feedback {
                feedback = own
                context.setMuted(own)
            }
        }

        // While escaping our own route the speaker is not the real output, and
        // reporting it would load the speaker's correction.
        guard !escape.overriding else { return }
        let next = LinkRoute.realOutput(names: names).map { Self.describe(outputs[$0]) }
        if next != currentOutput, !(own && next == nil) {
            currentOutput = next
            journal.add("output is now \(next.map { "\($0.name) (\($0.transport.rawValue))" } ?? "none")")
            onOutputChanged?(next)
        }
    }

    private static func describe(_ port: AVAudioSessionPortDescription) -> OutputDevice {
        let transport: OutputTransport
        switch port.portType {
        case .builtInSpeaker, .builtInReceiver: transport = .builtIn
        case .headphones, .lineOut: transport = .wired
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP: transport = .bluetooth
        case .usbAudio: transport = .usb
        case .HDMI: transport = .hdmi
        case .airPlay: transport = .airPlay
        case .carAudio: transport = .carPlay
        default: transport = .other
        }
        return OutputDevice(uid: port.uid, name: port.portName, transport: transport)
    }
}
