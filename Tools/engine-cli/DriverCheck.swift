//
//  DriverCheck.swift
//  eqt-engine --driver-selftest
//
//  The engine against the REAL installed driver, with no audible output and
//  no setting changed:
//
//    this process ──IOProc (test tone)──► EQtargets Audio (the installed driver)
//        driver WriteMix → the real shm ring "/eqtargets.audio.ring"
//    RingMapping.open() → RenderContext (RingReader + ProcessingChain) driven
//    through EQTRenderCallback by a real-time pull thread on the host clock —
//    the output is captured to memory and analysed, never played.
//
//  macOS's default output, the virtual device's volume / rate and every other
//  property are left alone (playing into a device is what any app does).
//  Refuses if EQtargets Audio is currently macOS's default output (then the
//  app is routed and this test would mix a tone into the user's audio).
//

import AudioToolbox
import CoreAudio
import Darwin
import Foundation
import Synchronization

enum DriverCheck {

    static func run(_ r: SelfTestReport, seconds: Double) -> Int32? {
        r.section("Real driver check — tone into EQtargets Audio, engine reads the real ring (nothing is played)")
        guard let vid = DeviceCatalog.virtualDevice() else {
            print("EQtargets Audio driver is not installed; nothing to test.")
            return 2
        }
        if HAL.defaultOutputDevice() == vid {
            print("EQtargets Audio is macOS's default output right now (the app is routed). Refusing: the test tone would be mixed into your audio.")
            return 2
        }
        let defaultBefore = HAL.defaultOutputDevice()
        let volumeBefore = HAL.volumeScalar(vid, elements: [kAudioObjectPropertyElementMain])
        guard let deviceRate = HAL.nominalSampleRate(vid) else { r.check("virtual device rate readable", false); return nil }
        let ring: RingMapping
        switch RingMapping.open() {
        case .success(let m): ring = m
        case .failure(let e): r.check("driver ring opens read-only", false, "\(e)"); return nil
        }
        r.check("driver ring opens read-only and is valid (EQTRingHeaderIsValid)", ring.isValid,
                "rate \(ring.sampleRate.f(0)), generation \(ring.generation)")
        let generationBefore = ring.generation

        // Tone into the virtual device (its own format: 2 ch Float32 interleaved).
        let signal = SimSignal(left: [SimTone(frequency: 1_000, amplitude: 0.25)],
                               right: [SimTone(frequency: 1_500, amplitude: 0.25)], rate: deviceRate)
        let produced = Atomic<Int64>(0)
        let formatOK = Atomic<Bool>(true)
        var procID: AudioDeviceIOProcID?
        let created = AudioDeviceCreateIOProcIDWithBlock(&procID, vid, nil) { _, _, _, outData, _ in
            let list = UnsafeMutableAudioBufferListPointer(outData)
            guard list.count == 1, list[0].mNumberChannels == 2, let d = list[0].mData else {
                formatOK.store(false, ordering: .relaxed)
                for b in list { if let p = b.mData { memset(p, 0, Int(b.mDataByteSize)) } }
                return
            }
            let frames = Int(list[0].mDataByteSize) / 8
            let first = produced.load(ordering: .relaxed)
            signal.render(first: first, count: frames, into: d.assumingMemoryBound(to: Float.self))
            produced.store(first + Int64(frames), ordering: .relaxed)
        }
        guard created == noErr, let procID else { r.check("IOProc on EQtargets Audio", false, HAL.describe(created)); return nil }

        // Engine side: the very same context / callback as OutputUnit, pulled
        // by a real-time thread every 512 frames of host time; output captured.
        let outRate = deviceRate
        let reader = RingReader(header: ring.header)
        reader.configure(outputSampleRate: outRate, outputMaxFrames: 4_096, outputBufferFrames: 512)
        let chain = ProcessingChain(maxFrames: 4_096, maxChannels: 2)
        chain.prepare(sampleRate: outRate, channelCount: 2)
        chain.setParameters(ChainParameters())
        let ctx = RenderContext(reader: reader, chain: chain, ring: ring, sampleRate: outRate)
        let puller = Puller(context: ctx, rate: outRate, frames: 512, seconds: seconds + 1)

        let started = AudioDeviceStart(vid, procID)
        guard started == noErr else {
            AudioDeviceDestroyIOProcID(vid, procID)
            r.check("IOProc started on EQtargets Audio", false, HAL.describe(started))
            return nil
        }
        puller.start()
        var lockedAt: Double?
        var underrunsAtLock = 0
        var lockSample = 0
        let t0 = Date()
        var running = false
        for s in 1 ... max(1, Int(seconds)) {
            Thread.sleep(until: t0.addingTimeInterval(Double(s)))
            let st = reader.stats()
            running = running || HAL.isRunningSomewhere(vid)
            if lockedAt == nil, st.lock == .locked {
                lockedAt = Double(s); underrunsAtLock = st.underruns; lockSample = puller.captured
            }
            print(String(format: "  t=%2ds  %@  fill %7.1f / %6.1f  drift %+8.2f ppm  underruns %d  resyncs %d  gen %llu  ring head %lld",
                         s, "\(st.lock)".padding(toLength: 9, withPad: " ", startingAt: 0), st.fillFrames, st.targetFillFrames,
                         st.driftPPM, st.underruns, st.resyncs, st.generation, ring.writeHead))
            fflush(stdout)
        }
        let io = AUHALCheck.processIO()
        AudioDeviceStop(vid, procID)
        AudioDeviceDestroyIOProcID(vid, procID)
        puller.stop()
        let final = reader.stats()

        r.check("driver bumped the generation on our StartIO", ring.generation > generationBefore,
                "\(generationBefore) → \(ring.generation)")
        r.check("virtual device stream format as expected (2 ch interleaved)", formatOK.load(ordering: .relaxed))
        r.check("RingReader locks to the driver's clock", lockedAt != nil, lockedAt.map { "locked by \($0.f(0)) s" } ?? "\(final.lock)")
        r.check("zero underruns / overruns after lock", lockedAt != nil && final.underruns == underrunsAtLock && final.overruns == 0,
                "underruns after lock \(final.underruns - underrunsAtLock), total \(final.underruns); overruns \(final.overruns)")
        r.check("our process ran output only, never input (no mic, no orange dot)", io.output && !io.input,
                "output \(io.output), input \(io.input)")
        r.note("pull thread: \(puller.pulls.load(ordering: .relaxed)) pulls, lateness mean \(puller.meanLateMs.f(3)) ms, max \(puller.maxLateMs.f(3)) ms; reader: fill \(final.fillFrames.f(1)) / target \(final.targetFillFrames.f(1)), drift \(final.driftPPM.f(2)) ppm, latency \((final.latencySeconds * 1000).f(2)) ms")

        // Output analysis (steady state: 2 s after lock).
        let start = lockSample + Int(2 * outRate)
        let L = puller.left, R = puller.right
        if lockedAt != nil, start + Int(outRate) * 3 <= L.count {
            for (name, x, tone) in [("L", L, 1_000.0), ("R", R, 1_500.0)] {
                let fit = ToneAnalysis.fit(x, from: start, windowSize: Int(outRate), frequency: tone, sampleRate: outRate)
                let ppm = fit.frequencyErrorHz / tone * 1e6
                let level = ToneAnalysis.dB(fit.amplitude / 0.25)
                r.check("\(name) \(Int(tone)) Hz through driver + ring + chain: frequency within 5 ppm", abs(ppm) <= 5,
                        "\(ppm.f(2)) ppm over \(fit.windows) s")
                r.check("\(name) \(Int(tone)) Hz: level within 0.05 dB of what was played, steady", abs(level) <= 0.05 && fit.amplitudeSpreadDB <= 0.05,
                        "error \(level.f(4)) dB, spread \(fit.amplitudeSpreadDB.f(4)) dB")
            }
            let nonFinite = (L + R).filter { !$0.isFinite }.count
            r.check("no NaN / Inf in the captured output", nonFinite == 0, "\(nonFinite)")
        } else {
            r.check("enough locked audio to analyse", false, "captured \(L.count) frames, lock sample \(lockSample)")
        }
        r.check("macOS default output untouched", HAL.defaultOutputDevice() == defaultBefore)
        r.check("EQtargets Audio volume untouched", HAL.volumeScalar(vid, elements: [kAudioObjectPropertyElementMain]) == volumeBefore)
        _ = running
        return nil
    }
}

/// Pulls the render callback every `frames` of host time from a real-time
/// thread and records the output (test only; allocation happens up front).
final class Puller: @unchecked Sendable {
    private let ctx: RenderContext
    private let frames: Int
    private let rate: Double
    private let capacity: Int
    private let bufL: UnsafeMutablePointer<Float>
    private let bufR: UnsafeMutablePointer<Float>
    private let stopFlag = Atomic<Bool>(false)
    private let done = DispatchSemaphore(value: 0)
    private let count = Atomic<Int>(0)
    let pulls = Atomic<Int>(0)
    let maxLateTicks = Atomic<UInt64>(0)
    let sumLateTicks = Atomic<UInt64>(0)

    init(context: RenderContext, rate: Double, frames: Int, seconds: Double) {
        ctx = context
        self.frames = frames
        self.rate = rate
        capacity = Int(seconds * rate) + frames
        bufL = .allocate(capacity: capacity)
        bufR = .allocate(capacity: capacity)
    }

    deinit { bufL.deallocate(); bufR.deallocate() }

    var captured: Int { count.load(ordering: .relaxed) }
    var left: [Float] { Array(UnsafeBufferPointer(start: bufL, count: captured)) }
    var right: [Float] { Array(UnsafeBufferPointer(start: bufR, count: captured)) }
    var meanLateMs: Double { Double(sumLateTicks.load(ordering: .relaxed)) / Double(max(1, pulls.load(ordering: .relaxed))) / RingReader.hostTicksPerSecond * 1000 }
    var maxLateMs: Double { Double(maxLateTicks.load(ordering: .relaxed)) / RingReader.hostTicksPerSecond * 1000 }

    func start() {
        let t = Thread { [self] in self.loop() }
        t.qualityOfService = .userInteractive
        t.start()
    }

    func stop() {
        stopFlag.store(true, ordering: .relaxed)
        done.wait()
    }

    private func loop() {
        let tps = RingReader.hostTicksPerSecond
        let period = Double(frames) / rate * tps
        var policy = thread_time_constraint_policy_data_t(period: UInt32(period), computation: UInt32(0.001 * tps),
                                                          constraint: UInt32(0.003 * tps), preemptible: 1)
        let n = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &policy) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) {
                thread_policy_set(pthread_mach_thread_np(pthread_self()), thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, n)
            }
        }
        let abl = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(abl.unsafeMutablePointer) }
        var flags = AudioUnitRenderActionFlags()
        var stamp = AudioTimeStamp()
        let ref = Unmanaged.passUnretained(ctx).toOpaque()
        let start = mach_absolute_time()
        var k = 0
        while !stopFlag.load(ordering: .relaxed) {
            let due = start &+ UInt64(Double(k + 1) * period)
            mach_wait_until(due)
            let late = mach_absolute_time() &- due
            sumLateTicks.add(late, ordering: .relaxed)
            if late > maxLateTicks.load(ordering: .relaxed) { maxLateTicks.store(late, ordering: .relaxed) }
            let at = count.load(ordering: .relaxed)
            if at + frames <= capacity {
                abl[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: bufL + at)
                abl[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: bufR + at)
                _ = EQTRenderCallback(ref, &flags, &stamp, 0, UInt32(frames), abl.unsafeMutablePointer)
                count.store(at + frames, ordering: .relaxed)
            }
            pulls.add(1, ordering: .relaxed)
            k += 1
        }
        done.signal()
    }
}
