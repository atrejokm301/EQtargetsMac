//
//  OfflineSimulation.swift
//  eqt-engine --offline-selftest
//
//  The whole audio path without the driver, AUHAL or any device:
//
//    SimWriter thread ──(in-memory EQTRingHeader ring, the real protocol)──►
//    EQTRenderCallback(RenderContext) — the SAME C callback AUHAL calls:
//        RingReader.render → consumeDiscontinuity → requestReset → ProcessingChain.process
//
//  Time is simulated: the writer runs on its own clock (nominal rate ± ppm,
//  512-frame writes, 0–50 µs wake-up jitter, stamping lastWriteHostTime like
//  the driver), the "device" pulls 512 frames at exactly the output rate with
//  its own jitter, and RingReader reads "now" from `hostClockOverride`. The
//  two sides are interleaved in timestamp order, so 60 s of audio runs in
//  well under a second (Release) and every run is bit-for-bit repeatable.
//
//  The writer is a real second thread (handshaken per write), so the ring's
//  release/acquire publication is exercised across threads exactly as in
//  production.
//

import AudioToolbox
import CoreAudio
import Foundation

struct SimTone {
    var frequency: Double
    var amplitude: Double
}

/// The test signal: steady tones per channel plus periodic kick bursts on both.
struct SimSignal {
    var left: [SimTone]
    var right: [SimTone]
    var kickAmplitude = 0.3
    var kickPeriodSeconds = 0.5
    /// Writer nominal rate: frame i is at time i / rate on the WRITER's clock.
    var rate: Double

    /// 55 Hz burst: 2 ms raised-cosine attack (a smooth onset keeps its
    /// spectrum out of the tone bins), 50 ms exponential decay, 10 ms taper.
    func kick(_ t: Double) -> Double {
        guard t >= 0, t < 0.15 else { return 0 }
        var env = t < 0.002 ? 0.5 - 0.5 * cos(Double.pi * t / 0.002) : exp(-(t - 0.002) / 0.05)
        if t > 0.14 { env *= 0.5 + 0.5 * cos(Double.pi * (t - 0.14) / 0.01) }
        return env * sin(2 * Double.pi * 55 * t)
    }

    func render(first: Int64, count: Int, into dst: UnsafeMutablePointer<Float>) {
        for i in 0 ..< count {
            let n = Double(first + Int64(i))
            let t = n / rate
            let k = kickAmplitude * kick(t.truncatingRemainder(dividingBy: kickPeriodSeconds))
            var l = k, r = k
            for tone in left { l += tone.amplitude * sin(2 * Double.pi * (tone.frequency * n / rate).truncatingRemainder(dividingBy: 1)) }
            for tone in right { r += tone.amplitude * sin(2 * Double.pi * (tone.frequency * n / rate).truncatingRemainder(dividingBy: 1)) }
            dst[2 * i] = Float(l)
            dst[2 * i + 1] = Float(r)
        }
    }
}

/// Plays the driver's writer half of Shared/EQTRingProtocol.h on its own thread.
final class SimWriter: @unchecked Sendable {
    enum Command {
        case write(first: Int64, count: Int, hostTime: UInt64)
        /// StartIO again: generation += 1, head = 0 (driver's RestartTimeline).
        case restart
        case stop
    }

    private let header: UnsafeMutablePointer<EQTRingHeader>
    private let samples: UnsafeMutablePointer<Float>
    private let signal: SimSignal
    private let scratch: UnsafeMutablePointer<Float>
    private let scratchFrames: Int
    private var command = Command.stop
    /// Signal frames written before the current generation (the signal keeps
    /// running across a restart; the ring timeline starts again at 0).
    private var signalBase: Int64 = 0
    private var generationFrames: Int64 = 0
    private let go = DispatchSemaphore(value: 0)
    private let done = DispatchSemaphore(value: 0)

    init(ring: RingMapping, signal: SimSignal, maxFrames: Int) {
        header = ring.mutableHeader!
        samples = EQTRingSamples(header)
        self.signal = signal
        scratchFrames = maxFrames
        scratch = .allocate(capacity: 2 * maxFrames)
    }

    deinit { scratch.deallocate() }

    /// Header exactly as the driver publishes it: fields, then magic last.
    static func initialize(_ h: UnsafeMutablePointer<EQTRingHeader>, sampleRate: Double) {
        h.pointee.version = EQT_RING_VERSION
        h.pointee.channels = EQT_RING_CHANNELS
        h.pointee.capacityFrames = EQT_RING_CAPACITY_FRAMES
        h.pointee.headerBytes = EQT_RING_HEADER_BYTES
        EQTRingStoreSampleRate(h, sampleRate)
        EQTRingStoreWriteHead(h, 0)
        EQTRingBumpGeneration(h)
        EQTRingStoreWriteHead(h, 0)
        EQTRingStoreIORunning(h, 1)
        EQTRingStoreMagic(h, EQT_RING_MAGIC)
    }

    func start() {
        let t = Thread { [self] in self.loop() }
        t.name = "SimWriter"
        t.start()
    }

    /// Runs one command on the writer thread and waits for it.
    func perform(_ c: Command) {
        command = c
        go.signal()
        done.wait()
    }

    private func loop() {
        while true {
            go.wait()
            switch command {
            case .write(let first, let count, let host):
                write(first: first, count: count, hostTime: host)
            case .restart:
                EQTRingStoreIORunning(header, 0)
                signalBase += generationFrames
                generationFrames = 0
                EQTRingStoreWriteHead(header, 0)
                EQTRingBumpGeneration(header)
                EQTRingStoreWriteHead(header, 0)
                EQTRingStoreIORunning(header, 1)
            case .stop:
                done.signal()
                return
            }
            done.signal()
        }
    }

    /// One WriteMix. Called on the writer thread (or by a caller that owns
    /// the writer role, like the live AUHAL check's real-time thread).
    func write(first: Int64, count: Int, hostTime: UInt64) {
        let n = min(count, scratchFrames)
        signal.render(first: signalBase + first, count: n, into: scratch)
        let capacity = Int(EQT_RING_CAPACITY_FRAMES)
        var f = first, src = scratch, remaining = n
        while remaining > 0 {
            let slot = Int(f & Int64(capacity - 1))
            let run = min(remaining, capacity - slot)
            (samples + slot * 2).update(from: src, count: run * 2)
            f += Int64(run)
            src += run * 2
            remaining -= run
        }
        // Publish (RELEASE) after the samples, then the diagnostics — the
        // driver's order.
        let head = EQTRingLoadWriteHead(header)
        EQTRingStoreWriteHead(header, max(head, first + Int64(n)))
        EQTRingStoreIOBufferFrames(header, UInt32(n))
        EQTRingStoreLastWriteHostTime(header, hostTime)
        generationFrames = max(generationFrames, first + Int64(n))
    }
}

struct SimCase {
    var name: String
    var sourceRate = 48_000.0
    var outputRate = 48_000.0
    var writerPPM = 0.0
    var seconds = 60.0
    var ioFrames = 512
    var outFrames = 512
    var jitterSeconds = 50e-6
    var parameters = ChainParameters()
    var signal: SimSignal
    var restartAt: Double?
    var seed: UInt64 = 0x5EED
}

struct SimResult {
    var outL: [Float] = []
    var outR: [Float] = []
    var lockTime: Double?
    var relockTime: Double?
    var underrunsAtLock = 0
    var final = RingReaderStats()
    var maxFillError = 0.0
    var latencyRange = (min: Double.infinity, max: -Double.infinity)
    var targetFill = 0.0
    /// Output sample index where steady-state analysis may begin.
    var measureFrom: Int?
    var discontinuities: UInt64 = 0
    var renderCalls: UInt64 = 0
    var rejected: UInt64 = 0
    var silenceFlags = 0
    var busyTicks: UInt64 = 0
    var periodTicks: UInt64 = 0
    var meters = ChainMeters()
    var overCountAtMeasure = 0
    var nonFinite = 0
    var peak: Float = 0
    var wallSeconds = 0.0
    var chainLatencyFrames = 0
}

enum Simulation {

    static func run(_ c: SimCase) -> SimResult {
        let wallStart = Date()
        var r = SimResult()
        let tps = RingReader.hostTicksPerSecond
        func ticks(_ seconds: Double) -> UInt64 { UInt64((seconds * tps).rounded()) }

        // Ring + writer (the driver's side).
        let ring = RingMapping.inProcess()
        SimWriter.initialize(ring.mutableHeader!, sampleRate: c.sourceRate)
        let writer = SimWriter(ring: ring, signal: c.signal, maxFrames: c.ioFrames)
        writer.start()

        // Reader + chain + context (the app's side), configured exactly as
        // OutputUnit does, except the reader's clock is simulated.
        let clock = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        defer { clock.deallocate() }
        let t0 = 10.0
        clock.pointee = ticks(t0)
        let reader = RingReader(header: ring.header)
        reader.hostClockOverride = clock
        reader.configure(outputSampleRate: c.outputRate, outputMaxFrames: 4_096, outputBufferFrames: c.outFrames)
        let chain = ProcessingChain(maxFrames: 4_096, maxChannels: 2)
        chain.prepare(sampleRate: c.outputRate, channelCount: 2)
        chain.setParameters(c.parameters)
        r.chainLatencyFrames = chain.latencyFrames
        let ctx = RenderContext(reader: reader, chain: chain, ring: ring, sampleRate: c.outputRate)
        let refCon = Unmanaged.passUnretained(ctx).toOpaque()

        // What AUHAL hands the callback: two non-interleaved Float32 buffers.
        let abl = AudioBufferList.allocate(maximumBuffers: 2)
        let bufL = UnsafeMutablePointer<Float>.allocate(capacity: c.outFrames)
        let bufR = UnsafeMutablePointer<Float>.allocate(capacity: c.outFrames)
        defer { bufL.deallocate(); bufR.deallocate(); free(abl.unsafeMutablePointer) }
        var flags = AudioUnitRenderActionFlags()
        var stamp = AudioTimeStamp()

        var rng = SplitMix64(seed: c.seed)
        let wPeriod = Double(c.ioFrames) / (c.sourceRate * (1 + c.writerPPM * 1e-6))
        let rPeriod = Double(c.outFrames) / c.outputRate
        var wEpoch = t0
        var wk = 0
        var wJitter = rng.unit() * c.jitterSeconds
        var rk = 0
        var rJitter = rng.unit() * c.jitterSeconds
        let renders = Int(c.seconds / rPeriod)
        let statEvery = max(1, Int(0.25 / rPeriod))
        var restarted = false
        r.outL.reserveCapacity(renders * c.outFrames)
        r.outR.reserveCapacity(renders * c.outFrames)

        while rk < renders {
            let tw = wEpoch + Double(wk) * wPeriod + wJitter
            let tr = t0 + Double(rk) * rPeriod + rJitter
            if let at = c.restartAt, !restarted, min(tw, tr) >= t0 + at {
                clock.pointee = ticks(t0 + at)
                writer.perform(.restart)
                restarted = true
                wEpoch = t0 + at + 0.001
                wk = 0
                continue
            }
            if tw <= tr {
                clock.pointee = ticks(tw)
                writer.perform(.write(first: Int64(wk) * Int64(c.ioFrames), count: c.ioFrames, hostTime: ticks(tw)))
                wk += 1
                wJitter = rng.unit() * c.jitterSeconds
                continue
            }

            // One device pull. Buffers arrive holding garbage (NaN): every
            // frame must be overwritten by the callback.
            clock.pointee = ticks(tr)
            bufL.update(repeating: .nan, count: c.outFrames)
            bufR.update(repeating: .nan, count: c.outFrames)
            abl[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(c.outFrames * 4), mData: bufL)
            abl[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(c.outFrames * 4), mData: bufR)
            flags = AudioUnitRenderActionFlags()
            _ = EQTRenderCallback(refCon, &flags, &stamp, 0, UInt32(c.outFrames), abl.unsafeMutablePointer)
            if flags.contains(.unitRenderAction_OutputIsSilence) { r.silenceFlags += 1 }
            for i in 0 ..< c.outFrames {
                let l = bufL[i], rr = bufR[i]
                if !l.isFinite || !rr.isFinite { r.nonFinite += 1 }
                r.peak = max(r.peak, abs(l), abs(rr))
            }
            r.outL.append(contentsOf: UnsafeBufferPointer(start: bufL, count: c.outFrames))
            r.outR.append(contentsOf: UnsafeBufferPointer(start: bufR, count: c.outFrames))
            rk += 1
            rJitter = rng.unit() * c.jitterSeconds

            if rk % statEvery == 0 {
                let t = Double(rk) * rPeriod
                let s = reader.stats()
                let afterRestart = c.restartAt.map { t > $0 } ?? false
                if s.lock == .locked {
                    if r.lockTime == nil {
                        r.lockTime = t
                        r.underrunsAtLock = s.underruns
                    } else if afterRestart, r.relockTime == nil, restarted {
                        r.relockTime = t
                    }
                }
                // Steady state: 2 s after (re)lock, and for a restart case,
                // only after the restart.
                let settledFrom = afterRestart ? r.relockTime : (c.restartAt == nil ? r.lockTime : nil)
                if let lt = settledFrom, t >= lt + 2 {
                    if r.measureFrom == nil {
                        r.measureFrom = rk * c.outFrames
                        _ = chain.meters()                       // clear maxima: measure from here on
                        r.overCountAtMeasure = chain.meters().overCount
                    }
                    r.maxFillError = max(r.maxFillError, abs(s.fillFrames - s.targetFillFrames))
                    r.latencyRange.min = min(r.latencyRange.min, s.latencySeconds)
                    r.latencyRange.max = max(r.latencyRange.max, s.latencySeconds)
                    r.targetFill = s.targetFillFrames
                }
            }
        }
        writer.perform(.stop)

        r.final = reader.stats()
        r.meters = chain.meters()
        r.discontinuities = ctx.discontinuities.load(ordering: .relaxed)
        r.renderCalls = ctx.renderCalls.load(ordering: .relaxed)
        r.rejected = ctx.rejectedBuffers.load(ordering: .relaxed)
        r.busyTicks = ctx.busyTicks.load(ordering: .relaxed)
        r.periodTicks = ctx.periodTicks.load(ordering: .relaxed)
        r.wallSeconds = Date().timeIntervalSince(wallStart)
        return r
    }
}
