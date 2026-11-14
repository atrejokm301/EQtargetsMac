//
//  AUHALCheck.swift
//  eqt-engine --auhal-selftest
//
//  The real OutputUnit (AUHAL + render callback + RingReader + chain) on a
//  REAL output device, fed by an in-process ring that a real-time thread
//  writes on the host clock (as the driver does). The chain's output is
//  digitally MUTED, so the device plays exact silence.
//
//  It does NOT touch macOS's default output, the virtual device, any volume,
//  or any shared device setting — it only opens an output stream for N
//  seconds, as any player would (its IO buffer request, like the app's, is
//  per process and ends with it). What it proves on hardware:
//   • AUHAL accepts our configuration and binds the device; input stays OFF
//     (read back from the unit, and Core Audio reports this process is not
//     running input — no HFP, no orange dot);
//   • the callback runs at the device's buffer size and pace;
//   • RingReader locks against a real device clock and absorbs the true
//     host-clock ↔ DAC-clock drift with no underruns;
//   • CPU cost per callback on the real IO thread.
//

import CoreAudio
import Darwin
import Foundation
import Synchronization

/// Writes 512-frame chunks on the host clock, like the driver's WriteMix.
/// By default the thread gets a Mach time-constraint (real-time) policy, as
/// coreaudiod's IO threads have; `realtime: false` keeps an ordinary thread,
/// whose wake-ups macOS may delay by milliseconds (timer coalescing).
final class RealtimeWriter: @unchecked Sendable {
    private let writer: SimWriter
    private let frames: Int
    private let rate: Double
    private let realtime: Bool
    private let stopFlag = Atomic<Bool>(false)
    private let finished = DispatchSemaphore(value: 0)
    let writes = Atomic<Int>(0)
    let lateWakeups = Atomic<Int>(0)
    let maxLateTicks = Atomic<UInt64>(0)
    let sumLateTicks = Atomic<UInt64>(0)
    let policyResult = Atomic<Int32>(-1)

    init(ring: RingMapping, signal: SimSignal, rate: Double, frames: Int, realtime: Bool) {
        writer = SimWriter(ring: ring, signal: signal, maxFrames: frames)
        self.frames = frames
        self.rate = rate
        self.realtime = realtime
    }

    func start() {
        let t = Thread { [self] in self.loop() }
        t.name = "RealtimeWriter"
        t.qualityOfService = .userInteractive
        t.start()
    }

    func stop() {
        stopFlag.store(true, ordering: .relaxed)
        finished.wait()
    }

    var meanLateMs: Double {
        let n = max(1, writes.load(ordering: .relaxed))
        return Double(sumLateTicks.load(ordering: .relaxed)) / Double(n) / RingReader.hostTicksPerSecond * 1000
    }

    var maxLateMs: Double { Double(maxLateTicks.load(ordering: .relaxed)) / RingReader.hostTicksPerSecond * 1000 }

    private func loop() {
        let tps = RingReader.hostTicksPerSecond
        let period = Double(frames) / rate * tps
        if realtime {
            var policy = thread_time_constraint_policy_data_t(
                period: UInt32(period), computation: UInt32(0.0005 * tps),
                constraint: UInt32(0.002 * tps), preemptible: 1)
            let count = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size)
            let kr = withUnsafeMutablePointer(to: &policy) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    thread_policy_set(pthread_mach_thread_np(pthread_self()),
                                      thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, count)
                }
            }
            policyResult.store(kr, ordering: .relaxed)
        }
        let start = mach_absolute_time()
        var k: Int64 = 0
        while !stopFlag.load(ordering: .relaxed) {
            let due = start &+ UInt64(Double(k + 1) * period)
            mach_wait_until(due)
            let now = mach_absolute_time()
            let late = now &- due
            if Double(late) > 0.002 * tps { lateWakeups.add(1, ordering: .relaxed) }
            if late > maxLateTicks.load(ordering: .relaxed) { maxLateTicks.store(late, ordering: .relaxed) }
            sumLateTicks.add(late, ordering: .relaxed)
            writer.write(first: k * Int64(frames), count: frames, hostTime: now)
            writes.add(1, ordering: .relaxed)
            k += 1
        }
        finished.signal()
    }
}

enum AUHALCheck {

    static func run(_ r: SelfTestReport, seconds: Double, outputUID: String?, realtimeWriter: Bool = true) {
        r.section("Live AUHAL check — real output device, chain output MUTED (silence)")
        let devices = DeviceCatalog.outputDevices()
        let defaultBefore = HAL.defaultOutputDevice()
        let systemBefore = HAL.defaultSystemOutputDevice()
        let chosen = outputUID.flatMap { u in devices.first { $0.uid == u } }
            ?? devices.first { $0.objectID == defaultBefore }
            ?? devices.first { $0.transport == .builtIn }
            ?? devices.first
        guard let device = chosen else {
            r.check("a real output device to test on", false, "none found")
            return
        }
        let buffer = HAL.bufferFrameSize(device.objectID) ?? 0
        r.note("device: \(device.name) [\(device.uid)] \(device.transport), \(device.nominalSampleRate.f(0)) Hz, IO buffer \(buffer) frames, hardware volume \(device.hasHardwareVolume)")

        let ring = RingMapping.inProcess()
        SimWriter.initialize(ring.mutableHeader!, sampleRate: 48_000)
        let signal = SimSignal(left: [SimTone(frequency: 1_000, amplitude: 0.25)],
                               right: [SimTone(frequency: 1_500, amplitude: 0.25)], rate: 48_000)
        let writer = RealtimeWriter(ring: ring, signal: signal, rate: 48_000, frames: 512, realtime: realtimeWriter)

        // Muted BEFORE the unit exists: OutputUnit.init → chain.prepare adopts
        // these parameters instantly, so not one audible sample is produced.
        let chain = ProcessingChain(maxFrames: 4_096, maxChannels: 2)
        var muted = ChainParameters()
        muted.outputMuted = true
        chain.setParameters(muted)

        let unit: OutputUnit
        do {
            unit = try OutputUnit(device: device.objectID, ring: ring, chain: chain)
        } catch {
            r.check("AUHAL configured on \(device.name)", false, (error as? OutputUnit.Failure)?.message ?? "\(error)")
            return
        }
        r.check("AUHAL configured and initialized (input off, Float32 non-interleaved stereo @ device rate)", true)
        r.check("AUHAL input stays disabled (read back after initialize)", !unit.inputEnabled)
        r.check("AUHAL bound to the requested device", unit.boundDevice == device.objectID,
                "bound \(unit.boundDevice.map { "\($0)" } ?? "nil"), wanted \(device.objectID)")
        // A device may round the request up (AirPods Max: 128 asked, 256 run,
        // although its range says 15…960). What must hold: when a smaller size
        // was asked for, the buffer shrank and stayed within [request, before];
        // when nothing was asked for, it is unchanged. That the size read back
        // is the one the callback really gets is checked after the run.
        let requested = HAL.bufferRequest(current: buffer, preferred: OutputUnit.preferredBufferFrames,
                                          range: HAL.bufferFrameSizeRange(device.objectID))
        let shrank = requested.map { unit.bufferFrames >= $0 && unit.bufferFrames < buffer } ?? (unit.bufferFrames == buffer)
        r.check("IO buffer request takes effect (\(buffer) → asked \(requested.map(String.init) ?? "nothing"), range \(HAL.bufferFrameSizeRange(device.objectID).map { "\($0.lowerBound)…\($0.upperBound)" } ?? "unknown"))",
                shrank, "device runs \(unit.bufferFrames)")

        // PropertyListener against the real HAL: our own start/stop toggles
        // the device's IsRunning (for this process) — a harmless trigger.
        let fires = Atomic<Int>(0)
        let listenerQueue = DispatchQueue(label: "auhal-check.listener")
        let listener = PropertyListener(object: device.objectID, address: HAL.address(kAudioDevicePropertyDeviceIsRunning),
                                        queue: listenerQueue) { fires.add(1, ordering: .relaxed) }
        func toggle() {
            try? unit.start()
            Thread.sleep(forTimeInterval: 0.3)
            unit.stop()
            Thread.sleep(forTimeInterval: 0.3)
            listenerQueue.sync {}
        }
        toggle()
        let whileRegistered = fires.load(ordering: .relaxed)
        listener.cancel()
        toggle()
        let afterCancel = fires.load(ordering: .relaxed) - whileRegistered
        r.check("PropertyListener receives real HAL notifications (device start/stop)", listener.registrationStatus == noErr && whileRegistered > 0,
                "\(whileRegistered) notifications")
        r.check("PropertyListener.cancel() really removes it (no notifications after)", afterCancel == 0, "\(afterCancel) after cancel")

        writer.start()
        let callsBefore = unit.context.renderCalls.load(ordering: .relaxed)   // exclude the listener toggles
        do {
            try unit.start()
        } catch {
            writer.stop()
            r.check("AUHAL started", false, (error as? OutputUnit.Failure)?.message ?? "\(error)")
            return
        }
        _ = chain.meters()
        var lockedAt: Double?
        var underrunsAtLock = 0
        var runningOutput = false
        var runningInput = false
        let ctx = unit.context
        let t0 = Date()
        var lastBusy: UInt64 = 0, lastPeriod: UInt64 = 0
        var cpu: [Double] = []
        for s in 1 ... max(1, Int(seconds)) {
            Thread.sleep(until: t0.addingTimeInterval(Double(s)))
            let st = ctx.reader.stats()
            if lockedAt == nil, st.lock == .locked { lockedAt = Double(s); underrunsAtLock = st.underruns }
            let busy = ctx.busyTicks.load(ordering: .relaxed), period = ctx.periodTicks.load(ordering: .relaxed)
            let load = period > lastPeriod ? Double(busy - lastBusy) / Double(period - lastPeriod) : 0
            lastBusy = busy; lastPeriod = period
            cpu.append(load)
            let io = processIO()
            runningOutput = runningOutput || io.output
            runningInput = runningInput || io.input
            print(String(format: "  t=%2ds  %@  fill %7.1f / %6.1f  drift %+8.2f ppm  underruns %d  resyncs %d  calls %llu  frames %d  cpu %.3f%%",
                         s, "\(st.lock)".padding(toLength: 9, withPad: " ", startingAt: 0), st.fillFrames, st.targetFillFrames,
                         st.driftPPM, st.underruns, st.resyncs, ctx.renderCalls.load(ordering: .relaxed),
                         ctx.lastFrameCount.load(ordering: .relaxed), load * 100))
            fflush(stdout)
        }
        let elapsed = Date().timeIntervalSince(t0)
        let meters = chain.meters()
        let final = ctx.reader.stats()
        let calls = ctx.renderCalls.load(ordering: .relaxed) - callsBefore
        let frames = ctx.lastFrameCount.load(ordering: .relaxed)
        let busyUs = Double(ctx.busyTicks.load(ordering: .relaxed)) / RingReader.hostTicksPerSecond / Double(max(calls, 1)) * 1e6
        unit.dispose()
        writer.stop()

        let expectedCalls = elapsed * unit.sampleRate / Double(max(frames, 1))
        r.check("callback runs at the device's pace (calls ≈ duration × rate / buffer, ±15 %)",
                frames > 0 && abs(Double(calls) - expectedCalls) <= 0.15 * expectedCalls,
                "\(calls) calls of \(frames) frames in \(elapsed.f(2)) s, expected \(expectedCalls.f(0))")
        r.check("callback buffer = device IO buffer", frames == unit.bufferFrames, "\(frames) vs \(unit.bufferFrames)")
        r.check("RingReader locks to the real device clock", lockedAt != nil, lockedAt.map { "locked by \($0.f(0)) s" } ?? "status \(final.lock)")
        r.check("zero underruns after lock", lockedAt != nil && final.underruns == underrunsAtLock,
                "after lock \(final.underruns - underrunsAtLock), total \(final.underruns)")
        r.note("test writer (plays the driver): \(realtimeWriter ? "time-constraint thread, thread_policy_set → \(writer.policyResult.load(ordering: .relaxed))" : "ordinary thread")"
               + "; wake-up lateness mean \(writer.meanLateMs.f(3)) ms, max \(writer.maxLateMs.f(3)) ms, >2 ms: \(writer.lateWakeups.load(ordering: .relaxed)) of \(writer.writes.load(ordering: .relaxed))")
        r.check("the chain received the audio (input peak) …", meters.inputPeakDB > -20, "\(meters.inputPeakDB.f(1)) dBFS")
        r.check("… and the device got exact silence (output peak)", meters.outputPeakDB <= -120, "\(meters.outputPeakDB.f(1)) dBFS")
        r.check("Core Audio: this process ran OUTPUT and never INPUT", runningOutput && !runningInput,
                "output \(runningOutput), input \(runningInput)")
        r.check("macOS default output and alert output untouched",
                HAL.defaultOutputDevice() == defaultBefore && HAL.defaultSystemOutputDevice() == systemBefore)
        r.note("measured: drift host-clock ↔ \(device.name) clock \(final.driftPPM.f(2)) ppm; ring fill \(final.fillFrames.f(1)) / target \(final.targetFillFrames.f(1)) frames; render \(busyUs.f(2)) µs per callback; CPU (median of 1 s windows) \((cpu.sorted()[cpu.count / 2] * 100).f(3)) %")
    }

    /// Whether Core Audio currently sees THIS process running output / input IO.
    static func processIO() -> (output: Bool, input: Bool) {
        let list = HAL.array(HAL.systemObject, HAL.address(kAudioHardwarePropertyProcessObjectList), of: AudioObjectID.self)
        let me = getpid()
        for obj in list {
            guard let pid: pid_t = HAL.get(obj, HAL.address(kAudioProcessPropertyPID)), pid == me else { continue }
            let out: UInt32 = HAL.get(obj, HAL.address(kAudioProcessPropertyIsRunningOutput)) ?? 0
            let inp: UInt32 = HAL.get(obj, HAL.address(kAudioProcessPropertyIsRunningInput)) ?? 0
            return (out != 0, inp != 0)
        }
        return (false, false)
    }
}
