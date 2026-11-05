//
//  RingReader.swift
//  EQtargets (macOS)
//
//  CONTRACT FILE — signatures frozen; replace the stub bodies.
//
//  Reads the system mix out of the driver's shared-memory ring (see
//  Shared/EQTRingProtocol.h) and delivers it at the OUTPUT device's rate.
//
//  The virtual device and the real output device run on different clocks.
//  Even at the same nominal rate they drift (measured on the previous driver:
//  +0.24 %), so a plain copy would eventually underrun or overrun. This
//  reader therefore:
//    • resamples with a high-quality fractional (windowed-sinc) interpolator;
//    • runs a PLL on the ring fill level: the resample ratio is nudged so the
//      distance between the driver's write head and our read position holds
//      at a target latency. Corrections are bounded (±1 %) and slow enough to
//      be inaudible as pitch;
//    • resyncs (with a short fade) on generation change, underrun or overrun —
//      never plays stale audio, never clicks.
//
//  IMPLEMENTATION NOTES
//  ------------------------------------------------------------------
//  Measuring the fill. The writer advances the head in whole IO buffers, so
//  the fill seen at our callback saw-tooths by one buffer. Worse, when both
//  sides use the same buffer size (the normal case: 512 / 512) the two
//  callback trains are nearly synchronous and the drift walks their relative
//  phase slowly through that sawtooth: sampled at our callback the fill shows a
//  sawtooth with a period of seconds (≈4 s at 0.24 % drift). No smoothing short
//  of tens of seconds removes that, and a PLL that follows it modulates pitch.
//  So the fill is measured against the PROJECTED head: the driver stamps
//  `lastWriteHostTime` on every write, and head + (now − stamp) × source rate is
//  a continuous estimate of where the writer is right now. What remains is IO
//  jitter (a frame or two), which a 50 ms smoother removes. If the stamp is
//  missing or the writer is late (> 2 buffers), the raw head is used.
//
//  The loop. Fill error e (seconds) obeys ė = drift − correction, so a PI
//  controller c = Kp·e + Ki·∫e gives s² + Kp·s + Ki. Acquiring: ωn = 2π·0.2 Hz,
//  ζ = 1, 50 ms fill smoothing, anti-windup through the slew limit. Lock is
//  declared once the fill is on target AND has stopped moving (slope < 2
//  frames/s for 1 s). Locked: ωn = 2π·0.05 Hz, ζ = 1, 0.5 s smoothing — four
//  times narrower, so the
//  IO-timing jitter left in the fill measurement no longer frequency-modulates
//  the output. Gear changes are bumpless. The correction is clamped to ±1 % and
//  slew-limited to 2000 ppm/s (≈3.5 cents/s — far below anything heard as
//  vibrato). The integrator holds the measured drift across resyncs, so
//  re-locking after a dropout is quick.
//
//  Target fill = writer buffer + our buffer (in source frames) + filter
//  half-length + a safety margin of max(256, half the larger buffer), clamped to
//  [256, capacity/4]. At 512/512 @ 48 kHz that is 1298 frames ≈ 27 ms.
//
//  Resync. Generation change, a torn / lapped read, an overrun (reader too far
//  behind) or an invalid ring stop the stream abruptly; the last emitted sample
//  is then ramped to zero over 5 ms (a declick — never a step). An underrun with
//  enough audio left fades that audio out over its last 5 ms instead. A new
//  stream always starts at the target fill and fades in over 5 ms. Frames below
//  the write head of the CURRENT generation are the only audio ever played.
//

import Foundation
import Synchronization

struct RingReaderStats: Equatable {
    enum Lock: Equatable {
        /// No valid ring or the driver is not writing (nothing playing).
        case waiting
        /// Streaming, PLL in its capture range.
        case locked
        /// Streaming, PLL still converging after a resync.
        case acquiring
    }
    var lock: Lock = .waiting
    /// Smoothed distance between write head and read position, in source frames.
    var fillFrames: Double = 0
    var targetFillFrames: Double = 0
    /// Current source frames consumed per output frame.
    var ratio: Double = 1
    /// (ratio / nominal ratio − 1) × 1e6 — the clock drift being absorbed.
    var driftPPM: Double = 0
    var underruns: Int = 0
    var overruns: Int = 0
    var resyncs: Int = 0
    var generation: UInt64 = 0
    /// Nominal rate the driver reports for the ring.
    var sourceSampleRate: Double = 0
    /// Latency the ring adds right now, in seconds (fill / source rate).
    var latencySeconds: Double = 0
}

/// Single consumer of an `EQTRingHeader` ring. Owned by the output engine.
///
/// Threading: `init` / `configure` on a non-RT thread with rendering stopped;
/// `render` on the output render thread; `stats` from any thread.
final class RingReader: @unchecked Sendable {

    // MARK: Constants

    static let capacity = Int(EQT_RING_CAPACITY_FRAMES)
    private static let mask = Int64(EQT_RING_CAPACITY_FRAMES) - 1
    /// Rates the driver publishes; a resampler table is precomputed for each.
    static let supportedSourceRates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000]
    /// Resync fade / declick length.
    static let fadeSeconds = 0.005

    // PLL (see header comment). Two gears: a fast one to acquire, a 10×
    // narrower one once locked so IO-timing jitter in the fill measurement does
    // not reach the ratio (measured: single-gear left the output tone at
    // −46 dB THD+N from close-in FM; see RingReaderTests).
    static let acquireHz = 0.2
    static let acquireDamping = 1.0
    static let acquireSmoothingSeconds = 0.05
    static let lockedHz = 0.05
    static let lockedDamping = 1.0
    static let lockedSmoothingSeconds = 0.5
    static let maxCorrection = 0.01
    static let slewPerSecond = 0.002
    /// Lock requires the fill to have STOPPED moving, not merely to be near the
    /// target: a loop still swinging through the target looked "locked" and
    /// the narrow gear then took ~50 s to finish the job (measured).
    static let lockHoldSeconds = 1.0
    static let lockSlopeFramesPerSecond = 2.0
    static let slopeSmoothingSeconds = 1.0

    /// mach_absolute_time ticks per second.
    static let hostTicksPerSecond: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        guard info.numer > 0 else { return 1e9 }
        return 1e9 * Double(info.denom) / Double(info.numer)
    }()

    // MARK: Ring

    private let header: UnsafePointer<EQTRingHeader>
    private let ringSamples: UnsafePointer<Float>

    /// Tests: when set (before `configure`), the reader reads "now" from here
    /// instead of `mach_absolute_time()`, so simulated time is deterministic.
    var hostClockOverride: UnsafeMutablePointer<UInt64>?
    private var clock: UnsafeMutablePointer<UInt64>?
    /// Copy of `hostTicksPerSecond` read at init: touching the lazy static on
    /// the render thread compiled to a `swift_once` call (found by scanning the
    /// Release machine code), whose first use could block.
    private let ticksPerSecond: Double

    // MARK: Configuration (non-RT)

    private var configured = false
    private var outRate = 48_000.0
    private var outMaxFrames = 0
    private var outBufferFrames = 512
    private var fadeLen = 240
    private var tables: [ResamplerTable] = []              // ownership only
    private var kernels: UnsafeMutablePointer<ResamplerKernel>
    private var kernelRates: UnsafeMutablePointer<Double>
    private var kernelCount = 0
    private var baseKernel: ResamplerKernel
    private var histL: UnsafeMutablePointer<Float>
    private var histR: UnsafeMutablePointer<Float>
    private var histCapacity = 0
    private var outL: UnsafeMutablePointer<Float>
    private var outR: UnsafeMutablePointer<Float>

    // MARK: Render state

    private var streaming = false
    private var haveGeneration = false
    private var generation: UInt64 = 0
    private var srcRate = 0.0
    private var nominalRatio = 1.0
    private var rateValid = false
    private var kernel: ResamplerKernel
    private var posIndex: Int64 = 0
    private var posFrac = 0.0
    private var histBase: Int64 = 0
    private var histCount = 0
    private var ioFrames = 512

    private var integrator = 0.0
    private var correction = 0.0
    private var smoothedFill = 0.0
    private var targetFill = 1024.0
    private var lockedFor = 0.0
    private var locked = false
    /// Smoothed d(fill)/dt, frames per second = source rate × residual drift.
    private var fillSlope = 0.0
    /// Writer frames per host second, measured over ≥ 2 s baselines. The head
    /// projection must use the writer's REAL rate: with the nominal rate a
    /// writer 2400 ppm fast is under-projected by up to 1.2 frames, and that
    /// error beats slowly against our callbacks (measured ±6 ppm ratio wander).
    private var writerRate = 48_000.0
    private var rateRefHead: Int64 = -1
    private var rateRefStamp: UInt64 = 0
    /// Earliest source position a restart may begin at in this generation.
    /// After an underrun / drain it is where playback stopped, so a restart can
    /// never replay audio that was already played (it waits for new frames).
    private var minRestart = -Double.infinity

    private var fadeInLeft = 0
    private var declickLeft = 0
    private var declickL: Float = 0
    private var declickR: Float = 0
    private var lastL: Float = 0
    private var lastR: Float = 0

    private var lastHead: Int64 = -1
    private var framesSinceHeadMoved = 0
    private var lockState: RingReaderStats.Lock = .waiting
    private var underruns = 0
    private var overruns = 0
    private var resyncs = 0

    // MARK: Cross-thread

    private let discontinuity = Atomic<Bool>(false)
    private let statSeq = Atomic<UInt64>(0)
    private let sLock = Atomic<Int>(0)
    private let sFill = Atomic<UInt64>(0)
    private let sTarget = Atomic<UInt64>(0)
    private let sRatio = Atomic<UInt64>(1.0.bitPattern)
    private let sDrift = Atomic<UInt64>(0)
    private let sUnder = Atomic<Int>(0)
    private let sOver = Atomic<Int>(0)
    private let sResync = Atomic<Int>(0)
    private let sGen = Atomic<UInt64>(0)
    private let sRate = Atomic<UInt64>(0)
    private let sLatency = Atomic<UInt64>(0)

    // MARK: - Lifecycle

    /// `header` must stay mapped (and point at `EQT_RING_TOTAL_BYTES`) for the
    /// reader's whole lifetime. Tests pass plain allocated memory.
    init(header: UnsafePointer<EQTRingHeader>) {
        self.header = header
        ringSamples = EQTRingSamplesConst(header)
        ticksPerSecond = Self.hostTicksPerSecond
        kernels = .allocate(capacity: 1)
        kernelRates = .allocate(capacity: 1)
        histL = .allocate(capacity: 1)
        histR = .allocate(capacity: 1)
        outL = .allocate(capacity: 1)
        outR = .allocate(capacity: 1)
        let base = ResamplerTable.table(forRatio: 1)
        tables = [base]
        baseKernel = ResamplerKernel(base)
        kernel = baseKernel
    }

    deinit {
        kernels.deallocate()
        kernelRates.deallocate()
        histL.deallocate(); histR.deallocate()
        outL.deallocate(); outR.deallocate()
    }

    /// Non-RT. `outputBufferFrames` is the device's IO buffer size, used to
    /// size the target latency; `outputMaxFrames` bounds a single `render`.
    func configure(outputSampleRate: Double, outputMaxFrames: Int, outputBufferFrames: Int) {
        let rate = outputSampleRate.isFinite && outputSampleRate >= 8_000 ? outputSampleRate : 48_000
        outRate = rate
        outMaxFrames = max(16, outputMaxFrames)
        outBufferFrames = max(16, outputBufferFrames)
        fadeLen = max(1, Int((Self.fadeSeconds * rate).rounded()))
        clock = hostClockOverride

        // Resampler tables for every rate the driver can publish (cached
        // process-wide; built here, never on the render thread).
        let base = ResamplerTable.table(forRatio: 1)
        var owned = [base]
        baseKernel = ResamplerKernel(base)
        kernels.deallocate(); kernelRates.deallocate()
        let rates = Self.supportedSourceRates
        kernels = .allocate(capacity: rates.count)
        kernelRates = .allocate(capacity: rates.count)
        var maxTaps = base.taps
        var maxRatio = 1.0
        for (i, r) in rates.enumerated() {
            let ratio = r / rate
            let t = ResamplerTable.table(forRatio: ratio)
            owned.append(t)
            (kernels + i).initialize(to: ResamplerKernel(t))
            (kernelRates + i).initialize(to: r)
            maxTaps = max(maxTaps, t.taps)
            maxRatio = max(maxRatio, ratio)
        }
        kernelCount = rates.count
        tables = owned

        // History: taps + one maximal render's worth of source frames (+PLL
        // headroom); output scratch: one maximal render.
        let maxSourcePerRender = Int((Double(outMaxFrames) * maxRatio * (1 + 2 * Self.maxCorrection)).rounded(.up))
        histCapacity = maxTaps + maxSourcePerRender + 16
        histL.deallocate(); histR.deallocate(); outL.deallocate(); outR.deallocate()
        histL = .allocate(capacity: histCapacity); histL.initialize(repeating: 0, count: histCapacity)
        histR = .allocate(capacity: histCapacity); histR.initialize(repeating: 0, count: histCapacity)
        outL = .allocate(capacity: outMaxFrames); outL.initialize(repeating: 0, count: outMaxFrames)
        outR = .allocate(capacity: outMaxFrames); outR.initialize(repeating: 0, count: outMaxFrames)

        // Fresh render state. Counters are lifetime diagnostics and survive.
        streaming = false
        haveGeneration = false
        rateValid = false
        kernel = baseKernel
        integrator = 0
        correction = 0
        smoothedFill = 0
        locked = false
        lockedFor = 0
        fadeInLeft = 0
        declickLeft = 0
        lastL = 0; lastR = 0
        lastHead = -1
        framesSinceHeadMoved = 0
        lockState = .waiting
        configured = true
        publishStats()
    }

    // MARK: - Render

    /// Render thread. Fills exactly `frameCount` frames in each channel
    /// (stereo; a mono destination gets the L/R average). Returns `true` if
    /// any real audio was produced, `false` if it wrote silence.
    @discardableResult
    func render(into channels: UnsafeMutableBufferPointer<UnsafeMutablePointer<Float>>, frameCount: Int) -> Bool {
        guard frameCount > 0, channels.count > 0 else { return false }
        guard configured else {
            for ch in 0 ..< channels.count { channels[ch].update(repeating: 0, count: frameCount) }
            return false
        }
        var any = false
        var offset = 0
        while offset < frameCount {
            let n = min(outMaxFrames, frameCount - offset)
            if renderChunk(n) { any = true }
            switch channels.count {
            case 1:
                let d = channels[0] + offset
                for i in 0 ..< n { d[i] = 0.5 * (outL[i] + outR[i]) }
            default:
                (channels[0] + offset).update(from: outL, count: n)
                (channels[1] + offset).update(from: outR, count: n)
                for ch in 2 ..< channels.count { (channels[ch] + offset).update(repeating: 0, count: n) }
            }
            offset += n
        }
        publishStats()
        return any
    }

    /// One chunk of ≤ outMaxFrames output frames into outL / outR.
    private func renderChunk(_ n: Int) -> Bool {
        var produced = 0
        var stopAt = -1          // frame where the stream broke off abruptly (declick from there)

        if EQTRingHeaderIsValid(header) == 0 || !Self.headIsPlausible(EQTRingLoadWriteHead(header)) {
            // No ring, or one whose head no driver could have written: never
            // do arithmetic with it (a hostile value could overflow and trap).
            if streaming { stopStreaming(); stopAt = 0 }
            haveGeneration = false
            lockState = .waiting
        } else {
            let now = clock?.pointee ?? mach_absolute_time()
            let g0 = EQTRingLoadGeneration(header)
            var h0 = EQTRingLoadWriteHead(header)
            if !Self.headIsPlausible(h0) { h0 = max(0, lastHead) }   // changed since the check above
            let running = EQTRingLoadIORunning(header) != 0
            let ioRaw = Int(EQTRingLoadIOBufferFrames(header))
            let stamp = EQTRingLoadLastWriteHostTime(header)

            if !haveGeneration || g0 != generation {
                // The timeline restarted: nothing from the old one may play.
                if streaming { stopStreaming(); stopAt = 0 }
                generation = g0
                haveGeneration = true
                minRestart = -.infinity
                adoptSourceRate(EQTRingLoadSampleRate(header))
                writerRate = srcRate
                rateRefHead = -1
                lastHead = h0
                framesSinceHeadMoved = 0
            }
            if h0 != lastHead { lastHead = h0; framesSinceHeadMoved = 0 } else { framesSinceHeadMoved += n }

            if rateValid {
                ioFrames = ioRaw > 0 ? ioRaw : 512
                updateTarget()
                let stalled = Double(framesSinceHeadMoved) * nominalRatio
                    > max(4.0 * Double(ioFrames), 2.0 * Double(outBufferFrames) * nominalRatio, 2_048)

                // Writer rate over long baselines (re-based every ≥ 2 s; a gap or
                // stall restarts the baseline).
                if running, stamp != 0 {
                    if rateRefHead < 0 || h0 < rateRefHead || stamp < rateRefStamp {
                        rateRefHead = h0; rateRefStamp = stamp
                    } else {
                        let span = Double(stamp &- rateRefStamp) / ticksPerSecond
                        if span >= 2 {
                            let measured = Double(h0 - rateRefHead) / span
                            if abs(measured / srcRate - 1) < 0.02 { writerRate = measured }
                            rateRefHead = h0; rateRefStamp = stamp
                        }
                    }
                } else {
                    rateRefHead = -1
                }

                // Projected write head (see header comment).
                var hp = Double(h0)
                if running, stamp != 0, now > stamp {
                    let elapsed = Double(now - stamp) / ticksPerSecond * writerRate
                    if elapsed < 2.0 * Double(ioFrames) { hp += elapsed }
                }

                if streaming {
                    let fill = hp - (Double(posIndex) + posFrac)
                    let nextToCopy = histBase + Int64(histCount)
                    let slack = max(4_096.0, 4.0 * Double(ioFrames))
                    if h0 - nextToCopy > Int64(Self.capacity) || fill > targetFill + slack {
                        // Lapped, or so far behind that draining at 1 % would take
                        // seconds: jump to the present.
                        overruns += 1
                        stopStreaming()
                        stopAt = 0
                        minRestart = -.infinity
                    }
                }
                if !streaming, running, !stalled, stopAt <= 0 {
                    _ = tryStart(hp: hp, h0: h0, n: n)
                }
                if streaming {
                    let fillBefore = hp - (Double(posIndex) + posFrac)
                    let r = streamFrames(n, h0: h0, g0: g0)
                    switch r.outcome {
                    case .full:
                        produced = n
                        updatePLL(measuredFill: fillBefore, dt: Double(n) / outRate)
                    case .underrun(let k):
                        if running { underruns += 1 }
                        produced = k
                        if k >= fadeLen {
                            for i in 0 ..< fadeLen {
                                let g = Float(fadeLen - i) / Float(fadeLen + 1)
                                outL[k - fadeLen + i] *= g
                                outR[k - fadeLen + i] *= g
                            }
                        } else {
                            stopAt = k
                        }
                        stopStreaming()
                        minRestart = Double(posIndex) + posFrac
                    case .torn(let lapped):
                        if lapped { overruns += 1 }
                        minRestart = -.infinity
                        produced = 0
                        stopAt = 0
                        stopStreaming()
                    }
                }
                if streaming {
                    lockState = locked ? .locked : .acquiring
                } else {
                    lockState = (!running || stalled) ? .waiting : .acquiring
                }
            } else {
                if streaming { stopStreaming(); stopAt = 0 }
                lockState = .waiting
            }
        }

        // Silence after the produced audio.
        if produced < n {
            (outL + produced).update(repeating: 0, count: n - produced)
            (outR + produced).update(repeating: 0, count: n - produced)
        }
        // Fade-in of a fresh stream (a stream only ever starts at frame 0 of a chunk).
        if fadeInLeft > 0, produced > 0 {
            var i = 0
            while i < produced, fadeInLeft > 0 {
                let g = Float(fadeLen - fadeInLeft + 1) / Float(fadeLen + 1)
                outL[i] *= g; outR[i] *= g
                fadeInLeft -= 1
                i += 1
            }
        }
        // Declick: ramp the last emitted value to zero instead of stepping.
        if declickLeft > 0 || stopAt >= 0 {
            var dl = declickL, dr = declickR, left = declickLeft
            let len = Float(fadeLen)
            for i in 0 ..< n {
                if i == stopAt {
                    dl = i > 0 ? outL[i - 1] : lastL
                    dr = i > 0 ? outR[i - 1] : lastR
                    left = fadeLen
                }
                if left > 0 {
                    let g = Float(left) / len
                    outL[i] += dl * g
                    outR[i] += dr * g
                    left -= 1
                } else if i >= stopAt {
                    break
                }
            }
            declickL = dl; declickR = dr; declickLeft = left
        }
        lastL = outL[n - 1]
        lastR = outR[n - 1]
        return produced > 0
    }

    /// 2^50 frames is ~740 years at 48 kHz; anything outside [0, 2^50] is corrupt.
    private static func headIsPlausible(_ h: Int64) -> Bool { h >= 0 && h <= (1 << 50) }

    private enum StreamOutcome {
        case full
        case underrun(Int)
        case torn(lapped: Bool)
    }

    /// Resample up to `n` frames into outL/outR from frames below `h0`.
    private func streamFrames(_ n: Int, h0: Int64, g0: UInt64) -> (outcome: StreamOutcome, ratio: Double) {
        let k0 = kernel
        let ratio = nominalRatio * (1 + correction)
        guard ratio.isFinite, ratio > 0.05, ratio < 10 else {
            // Cannot happen with a valid rate; if it ever did, restart the loop.
            integrator = 0; correction = 0; smoothedFill = targetFill
            return (.torn(lapped: false), 1)
        }

        // Drop history the next output no longer needs.
        var rel = Int(posIndex - histBase)
        let drop = rel - k0.before
        if drop > 0 {
            if drop < histCount {
                histL.update(from: histL + drop, count: histCount - drop)
                histR.update(from: histR + drop, count: histCount - drop)
                histCount -= drop
            } else {
                histCount = 0
            }
            histBase += Int64(drop)
            rel -= drop
        }

        // One frame of margin below the head absorbs float rounding in the
        // position accumulation.
        let available = Int(min(h0 - histBase - 1, Int64(histCapacity)))
        let k = DriftResampler.producible(kernel: k0, index: rel, frac: posFrac, ratio: ratio,
                                          available: available, limit: n)
        if k > 0 {
            let lastPos = Double(rel) + posFrac + Double(k - 1) * ratio
            let needCount = min(Int(lastPos) + k0.after + 2, Int(h0 - histBase), histCapacity)
            if needCount > histCount {
                let first = histBase + Int64(histCount)
                copyFromRing(first: first, count: needCount - histCount, to: histCount)
                // Reader rule 3: re-check after the copy.
                let g1 = EQTRingLoadGeneration(header)
                let h1 = EQTRingLoadWriteHead(header)
                if g1 != g0 { return (.torn(lapped: false), ratio) }
                // Same rule as the checked load in renderChunk: a head no
                // driver could have written never reaches arithmetic
                // (`Int64.min - first` traps on the render thread).
                if !Self.headIsPlausible(h1) { return (.torn(lapped: false), ratio) }
                if h1 - first > Int64(Self.capacity) { return (.torn(lapped: true), ratio) }
                histCount = needCount
            }
            let r = DriftResampler.render(kernel: k0, left: histL, right: histR,
                                          index: rel, frac: posFrac, ratio: ratio, count: k,
                                          outLeft: outL, outRight: outR)
            posIndex = histBase + Int64(r.index)
            posFrac = r.frac
        }
        return (k == n ? .full : .underrun(k), ratio)
    }

    /// Copy ring frames [first, first + count) into history at `at`,
    /// de-interleaving. Frames before 0 (start of a generation) read as silence.
    private func copyFromRing(first: Int64, count: Int, to at: Int) {
        var f = first
        var dst = at
        var remaining = count
        while remaining > 0, f < 0 {
            histL[dst] = 0; histR[dst] = 0
            f += 1; dst += 1; remaining -= 1
        }
        while remaining > 0 {
            let slot = Int(f & Self.mask)
            let run = min(remaining, Self.capacity - slot)
            let src = ringSamples + slot * 2
            for i in 0 ..< run {
                histL[dst + i] = src[2 * i]
                histR[dst + i] = src[2 * i + 1]
            }
            f += Int64(run); dst += run; remaining -= run
        }
    }

    private func tryStart(hp: Double, h0: Int64, n: Int) -> Bool {
        let p0 = hp - targetFill
        guard p0 >= 0, p0 >= minRestart else { return false }
        let idx = Int64(p0.rounded(.down))
        let frac = p0 - Double(idx)
        let base = idx - Int64(kernel.before)
        guard h0 - base <= Int64(Self.capacity) else { return false }
        let ratio = nominalRatio * (1 + correction)
        let k = DriftResampler.producible(kernel: kernel, index: kernel.before, frac: frac, ratio: ratio,
                                          available: Int(h0 - base) - 1, limit: n)
        guard k == n else { return false }
        posIndex = idx
        posFrac = frac
        histBase = base
        histCount = 0
        smoothedFill = targetFill
        fillSlope = 0
        streaming = true
        fadeInLeft = fadeLen
        locked = false
        lockedFor = 0
        resyncs += 1
        discontinuity.store(true, ordering: .releasing)
        return true
    }

    private func stopStreaming() {
        streaming = false
        locked = false
        lockedFor = 0
        fadeInLeft = 0
    }

    private func adoptSourceRate(_ rate: Double) {
        rateValid = false
        // Only a rate the reader can actually run is ever stored (and
        // published through stats()): a header rate of +inf / 1e300 must not
        // reach the engine's latency report (Int(inf) traps on the main thread).
        srcRate = 0
        guard rate.isFinite, rate >= 8_000, outRate > 0 else { return }
        let ratio = rate / outRate
        guard ratio >= 0.1, ratio <= 8 else { return }
        var chosen: ResamplerKernel?
        var bestRatio = Double.infinity
        for i in 0 ..< kernelCount {
            if abs(kernelRates[i] - rate) < 0.5 { chosen = kernels[i]; break }
            // Unknown rate: the closest table whose cutoff is at least as low
            // as this ratio needs (never one that would let aliases through).
            let r = kernelRates[i] / outRate
            if r >= ratio, r < bestRatio { bestRatio = r; chosen = kernels[i] }
        }
        if chosen == nil, ratio <= 1.02 { chosen = baseKernel }
        guard let k = chosen else { return }
        kernel = k
        nominalRatio = ratio
        srcRate = rate
        rateValid = true
    }

    private func updateTarget() {
        let outSrc = Double(outBufferFrames) * nominalRatio
        let io = Double(ioFrames)
        let margin = max(256.0, 0.5 * max(io, outSrc))
        let t = io + outSrc + Double(kernel.taps / 2) + 2 + margin
        targetFill = min(max(t, 256), Double(Self.capacity / 4))
    }

    private func updatePLL(measuredFill: Double, dt: Double) {
        // Bounded innovation: a writer that stamps its time a moment after
        // publishing its head can make one projection a buffer too high.
        let limit = max(64.0, 0.25 * Double(ioFrames))
        let innovation = min(max(measuredFill - smoothedFill, -limit), limit)
        let tau = locked ? Self.lockedSmoothingSeconds : Self.acquireSmoothingSeconds
        let previous = smoothedFill
        smoothedFill += innovation * dt / (tau + dt)
        fillSlope += ((smoothedFill - previous) / dt - fillSlope) * dt / (Self.slopeSmoothingSeconds + dt)

        let kp = Self.proportionalGain(locked: locked)
        let ki = Self.integralGain(locked: locked)
        let e = (smoothedFill - targetFill) / srcRate               // seconds
        let maxStep = Self.slewPerSecond * dt
        var want = min(max(kp * e + integrator, -Self.maxCorrection), Self.maxCorrection)
        // Anti-windup: integrate only while the output can follow (not slew- or
        // clamp-limited); integrating through the slew limit overshot to
        // +3970 ppm on a 2400 ppm step before this.
        if abs(want - correction) <= maxStep, abs(want) < Self.maxCorrection {
            integrator = min(max(integrator + ki * e * dt, -Self.maxCorrection), Self.maxCorrection)
            want = min(max(kp * e + integrator, -Self.maxCorrection), Self.maxCorrection)
        }
        correction += min(max(want - correction, -maxStep), maxStep)

        // Lock detection with hysteresis. Gear changes are bumpless: the
        // integrator absorbs the change in Kp·e so the ratio does not jump; on
        // locking it is seeded with the drift the fill slope still implies.
        let tolerance = max(24.0, 0.04 * targetFill)
        let errorFrames = abs(smoothedFill - targetFill)
        if !locked {
            if errorFrames < 0.5 * tolerance, abs(fillSlope) < Self.lockSlopeFramesPerSecond,
               abs(want - correction) < 1e-4 {
                lockedFor += dt
                if lockedFor >= Self.lockHoldSeconds {
                    locked = true
                    let drift = correction + fillSlope / srcRate
                    integrator = min(max(drift - Self.proportionalGain(locked: true) * e,
                                         -Self.maxCorrection), Self.maxCorrection)
                }
            } else {
                lockedFor = 0
            }
        } else if errorFrames > 3 * tolerance {
            locked = false
            lockedFor = 0
            integrator = correction - Self.proportionalGain(locked: false) * e
        }
    }

    /// s² + Kp·s + Ki with ωn, ζ of the gear (fill error measured in seconds).
    private static func proportionalGain(locked: Bool) -> Double {
        locked ? 2 * lockedDamping * 2 * .pi * lockedHz : 2 * acquireDamping * 2 * .pi * acquireHz
    }

    private static func integralGain(locked: Bool) -> Double {
        let wn = 2 * Double.pi * (locked ? lockedHz : acquireHz)
        return wn * wn
    }

    // MARK: - Stats

    private func publishStats() {
        let seq = statSeq.load(ordering: .relaxed)
        statSeq.store(seq &+ 1, ordering: .relaxed)
        atomicMemoryFence(ordering: .releasing)
        let lockCode: Int
        switch lockState {
        case .waiting: lockCode = 0
        case .acquiring: lockCode = 1
        case .locked: lockCode = 2
        }
        let ratio = nominalRatio * (1 + correction)
        sLock.store(lockCode, ordering: .relaxed)
        sFill.store((streaming ? smoothedFill : 0).bitPattern, ordering: .relaxed)
        sTarget.store(targetFill.bitPattern, ordering: .relaxed)
        sRatio.store(ratio.bitPattern, ordering: .relaxed)
        sDrift.store((correction * 1e6).bitPattern, ordering: .relaxed)
        sUnder.store(underruns, ordering: .relaxed)
        sOver.store(overruns, ordering: .relaxed)
        sResync.store(resyncs, ordering: .relaxed)
        sGen.store(generation, ordering: .relaxed)
        sRate.store(srcRate.bitPattern, ordering: .relaxed)
        let latency = streaming && srcRate > 0 ? smoothedFill / srcRate : 0
        sLatency.store(latency.bitPattern, ordering: .relaxed)
        statSeq.store(seq &+ 2, ordering: .releasing)
    }

    /// Any thread, lock-free snapshot.
    func stats() -> RingReaderStats {
        var s = RingReaderStats()
        for _ in 0 ..< 64 {
            let s1 = statSeq.load(ordering: .acquiring)
            switch sLock.load(ordering: .relaxed) {
            case 2: s.lock = .locked
            case 1: s.lock = .acquiring
            default: s.lock = .waiting
            }
            s.fillFrames = Double(bitPattern: sFill.load(ordering: .relaxed))
            s.targetFillFrames = Double(bitPattern: sTarget.load(ordering: .relaxed))
            s.ratio = Double(bitPattern: sRatio.load(ordering: .relaxed))
            s.driftPPM = Double(bitPattern: sDrift.load(ordering: .relaxed))
            s.underruns = sUnder.load(ordering: .relaxed)
            s.overruns = sOver.load(ordering: .relaxed)
            s.resyncs = sResync.load(ordering: .relaxed)
            s.generation = sGen.load(ordering: .relaxed)
            s.sourceSampleRate = Double(bitPattern: sRate.load(ordering: .relaxed))
            s.latencySeconds = Double(bitPattern: sLatency.load(ordering: .relaxed))
            atomicMemoryFence(ordering: .acquiring)
            let s2 = statSeq.load(ordering: .relaxed)
            if s1 == s2, s1 & 1 == 0 { break }
        }
        return s
    }

    /// True once `render` has seen the stream restart since the last call
    /// (generation change / resync). The engine uses it to `requestReset()` the chain.
    func consumeDiscontinuity() -> Bool {
        discontinuity.exchange(false, ordering: .acquiringAndReleasing)
    }
}
