//
//  LimiterProcessor.swift
//  EQtargets (macOS) — DSP core ported from EQtargets Music (iOS)
//  Models/LimiterProcessor.swift (limiter v2, commit 06c888b, confirmed on device).
//
//  On the Mac this is the OUTPUT PROTECTION stage at the end of the chain: a
//  transparent lookahead safety limiter with fixed settings
//  (`LimiterState.outputProtection`: ceiling −1 dBFS, brickwall, 1.5 ms
//  lookahead, program-dependent release, no makeup gain). It only acts on overs
//  that the EQ / Bass stages push past the ceiling.
//
//  Port notes — what changed from iOS and why:
//   • The AUv3 wrapper (`EQTLimiterAudioUnit`, `LimiterKernel`, `LimiterDSP`) was
//     dropped: the whole Mac chain runs inside one render callback
//     (ProcessingChain), which owns the parameter hand-off.
//   • Genre presets / Codable / UI labels were dropped: the Mac exposes no
//     limiter controls, only the fixed safety setting.
//   • The iOS core called `log10` and `pow` once per sample while active. The
//     Mac render-thread rules forbid that, so:
//       – the level→dB conversion is skipped (exactly) whenever the window peak
//         is below the point where the static curve can produce any reduction
//         (`LimiterCoefficients.engageLinear`) — i.e. on all normal program;
//       – when it does run, it uses `FastMath` (accurate to ~1e-10 dB);
//       – the dB→gain conversion is skipped when the envelope sits at exactly
//         0 dB, which also keeps the stage bit-exact below the ceiling.
//     The gain computer, envelopes, detector and every constant are unchanged.
//   • Denormal guard: the iOS envelope decayed toward 0 dB asymptotically and,
//     after ~70 s without limiting, would sit in denormal range forever. It is
//     now snapped to exactly 0 dB below 1e-9 dB (a gain error of 1e-10).
//
//  Original design notes (iOS):
//
//    • Lookahead delay line — audio is delayed while the detector runs ahead of
//      it, so gain reduction is already fully engaged when the peak arrives.
//    • Sliding-maximum peak detector over the lookahead window (monotonic
//      deque, amortised O(1)) — the gain target reflects the loudest sample
//      still to come, not the one that already passed.
//    • Soft-knee gain computer with a real N:1 ratio.
//    • Program-dependent release: the release coefficient interpolates between
//      fast and slow based on how much reduction has been *sustained*, so brief
//      transients recover quickly while loud passages release slowly. This is
//      what stops the pumping a single fixed release produces.
//    • Hard output ceiling in dBFS, enforced as part of the gain computation
//      and backed by a final clamp so the ceiling cannot be exceeded.
//
//  Stereo is **linked** — one shared gain across channels — so limiting never
//  shifts the stereo image.
//

import Foundation

// MARK: - State

/// Limiter settings (the DSP-relevant subset of the iOS `LimiterState`).
struct LimiterState: Equatable, Hashable {
    /// Master enable. When false the stage passes audio through at unity
    /// (still delayed by the lookahead, so latency stays constant).
    var isEnabled: Bool = false
    /// Absolute output ceiling in dBFS. Output never exceeds this.
    var ceilingDB: Double = -1.0
    /// Level above which gain reduction engages (dBFS).
    var thresholdDB: Double = -8
    /// Compression strength as classic ratio N:1. Values ≥ 20 display as "∞".
    var ratio: Double = 8
    /// Soft-knee width in dB centred on the threshold. 0 = hard knee.
    var kneeDB: Double = 6
    /// Attack time in milliseconds. Clamped to the lookahead window at render.
    var attackMs: Double = 3
    /// Baseline release time in milliseconds (the *fast* end of the
    /// program-dependent range; sustained reduction stretches it up to 8×).
    var releaseMs: Double = 120
    /// Lookahead window in milliseconds. Larger = more transparent, more latency.
    var lookaheadMs: Double = 3
    /// Derive makeup gain from threshold + ratio instead of using `postGainDB`.
    var autoMakeup: Bool = true
    /// Manual makeup gain after dynamics (dB). Used when `autoMakeup` is false.
    var postGainDB: Double = 0

    static let flat = LimiterState()

    static let ceilingRange: ClosedRange<Double> = -6 ... 0
    static let thresholdRange: ClosedRange<Double> = -30 ... -1
    static let ratioRange: ClosedRange<Double> = 1.5 ... 20
    static let kneeRange: ClosedRange<Double> = 0 ... 12
    static let attackMsRange: ClosedRange<Double> = 0.1 ... 50
    static let releaseMsRange: ClosedRange<Double> = 10 ... 1000
    static let lookaheadMsRange: ClosedRange<Double> = 0.5 ... 10
    static let postGainRange: ClosedRange<Double> = -12 ... 12

    /// Largest lookahead the kernel allocates for — the delay line is sized once.
    static let maxLookaheadMs: Double = 10

    /// The Mac's fixed output protection.
    ///
    /// Threshold == ceiling makes it a pure brickwall that does nothing at all
    /// until a sample would cross −1 dBFS; the ceiling term in `staticGainDB`
    /// then pulls the peak to exactly the ceiling (ratio is irrelevant there).
    /// 1.5 ms lookahead keeps the added latency to 72 frames at 48 kHz. Attack
    /// 0.3 ms = lookahead / 5, so the envelope has covered 99.3 % of the needed
    /// reduction (in dB) by the time the peak leaves the delay line — the final
    /// clamp only trims the last fraction of a dB instead of hard-clipping.
    /// Release 100 ms is the iOS "Pop / safety net" value; sustained limiting
    /// stretches it toward 800 ms (program-dependent), which avoids pumping on
    /// loud masters. No makeup gain: protection must never make things louder.
    static let outputProtection: LimiterState = {
        var s = LimiterState()
        s.isEnabled = true
        s.ceilingDB = -1
        s.thresholdDB = -1
        s.ratio = 20
        s.kneeDB = 0
        s.attackMs = 0.3
        s.releaseMs = 100
        s.lookaheadMs = 1.5
        s.autoMakeup = false
        s.postGainDB = 0
        return s.sanitized()
    }()

    mutating func sanitize() {
        ceilingDB = Self.clamp(ceilingDB, to: Self.ceilingRange)
        thresholdDB = Self.clamp(thresholdDB, to: Self.thresholdRange)
        ratio = Self.clamp(ratio, to: Self.ratioRange)
        kneeDB = Self.clamp(kneeDB, to: Self.kneeRange)
        attackMs = Self.clamp(attackMs, to: Self.attackMsRange)
        releaseMs = Self.clamp(releaseMs, to: Self.releaseMsRange)
        lookaheadMs = Self.clamp(lookaheadMs, to: Self.lookaheadMsRange)
        postGainDB = Self.clamp(postGainDB, to: Self.postGainRange)
        // A threshold above the ceiling can never engage — pull it under.
        if thresholdDB > ceilingDB {
            thresholdDB = Self.clamp(ceilingDB, to: Self.thresholdRange)
        }
    }

    func sanitized() -> LimiterState {
        var c = self
        c.sanitize()
        return c
    }

    /// Makeup gain actually applied, honouring `autoMakeup`.
    ///
    /// Auto mode compensates a *fraction* of the theoretical reduction at 0 dBFS
    /// rather than all of it: fully restoring peak level would make every preset
    /// audibly louder than bypass, which reads as "better" for the wrong reason.
    /// The ceiling still clamps the result, so this can never push past it.
    var effectiveMakeupDB: Double {
        guard autoMakeup else { return postGainDB }
        let s = sanitized()
        let theoretical = (1.0 / s.ratio - 1.0) * (0 - s.thresholdDB)   // negative dB
        return Self.clamp(-theoretical * 0.6, to: 0 ... 12)
    }

    private static func clamp(_ v: Double, to range: ClosedRange<Double>) -> Double {
        // NaN-safe: a non-finite input lands on the lower bound instead of
        // surviving min/max (which pass NaN straight through).
        guard v.isFinite else { return v == .infinity ? range.upperBound : range.lowerBound }
        return min(max(v, range.lowerBound), range.upperBound)
    }
}

// MARK: - Coefficients

/// Sample-rate-resolved kernel parameters. Plain values only — this struct is
/// copied across to the render thread.
struct LimiterCoefficients: Equatable {
    var bypass: Bool = true
    var thresholdDB: Double = -8
    var ratio: Double = 8
    var kneeDB: Double = 6
    var ceilingDB: Double = -1
    var makeupDB: Double = 0
    var makeupLinear: Double = 1
    var ceilingLinear: Double = 1
    /// Linear window peak at or below which `staticGainDB` is exactly 0 (Mac
    /// addition). Lets the render path skip the level→dB conversion entirely on
    /// material that cannot be reduced — an exact shortcut, not a tolerance.
    var engageLinear: Double = 1
    /// Per-sample one-pole coefficient for gain moving *down* (attack).
    var attackCoef: Double = 0.5
    /// Per-sample coefficient at the fast end of the release range.
    var releaseFastCoef: Double = 0.001
    /// Per-sample coefficient at the slow end (8× the fast time).
    var releaseSlowCoef: Double = 0.0001
    /// Coefficient for the very slow envelope that tracks *sustained* reduction.
    var sustainCoef: Double = 0.0002
    /// Release used while bypassed, so switching the limiter off returns to
    /// unity promptly instead of inheriting the program-dependent release
    /// (which stretches to seconds after a loud passage and makes the toggle
    /// feel broken). Still a ramp, not a jump, so it cannot click.
    var bypassReleaseCoef: Double = 0.001
    var lookaheadSamples: Int = 144

    /// Resolve a user-facing state against a sample rate.
    static func make(from state: LimiterState, sampleRate: Double) -> LimiterCoefficients {
        let s = state.sanitized()
        let sr = max(8_000, sampleRate.isFinite ? sampleRate : 48_000)
        var c = LimiterCoefficients()
        c.bypass = !s.isEnabled
        c.thresholdDB = s.thresholdDB
        c.ratio = max(1.0, s.ratio)
        c.kneeDB = s.kneeDB
        c.ceilingDB = s.ceilingDB
        c.ceilingLinear = pow(10.0, s.ceilingDB / 20.0)
        c.makeupDB = s.effectiveMakeupDB
        c.makeupLinear = pow(10.0, c.makeupDB / 20.0)

        // Below the knee's lower edge AND below the level where makeup would
        // project past the ceiling, `staticGainDB` returns exactly 0.
        let kneeLowDB = c.kneeDB > 0.0001 ? c.thresholdDB - c.kneeDB / 2 : c.thresholdDB
        let engageDB = min(kneeLowDB, c.ceilingDB - c.makeupDB)
        c.engageLinear = pow(10.0, engageDB / 20.0)

        let lookaheadSamples = Int((s.lookaheadMs / 1000.0 * sr).rounded())
        c.lookaheadSamples = max(1, min(lookaheadSamples, Self.maxLookaheadSamples(sampleRate: sr)))

        // Attack must complete inside the lookahead window, otherwise the gain
        // is still travelling when the peak arrives and the ceiling relies on
        // the final clamp instead of the envelope. Clamp rather than trust UI.
        let lookaheadMs = Double(c.lookaheadSamples) / sr * 1000.0
        let attackMs = min(s.attackMs, lookaheadMs)
        c.attackCoef = Self.onePole(timeMs: attackMs, sampleRate: sr)
        c.releaseFastCoef = Self.onePole(timeMs: s.releaseMs, sampleRate: sr)
        c.releaseSlowCoef = Self.onePole(timeMs: s.releaseMs * 8.0, sampleRate: sr)
        // ~300 ms window for judging "sustained" vs "transient" reduction.
        c.sustainCoef = Self.onePole(timeMs: 300, sampleRate: sr)
        c.bypassReleaseCoef = Self.onePole(timeMs: Self.bypassReleaseMs, sampleRate: sr)
        return c
    }

    /// Ramp back to unity when the stage is switched off. Fast enough to feel
    /// immediate, slow enough that 15 dB of reduction does not pop.
    static let bypassReleaseMs: Double = 30

    static func maxLookaheadSamples(sampleRate: Double) -> Int {
        max(1, Int((LimiterState.maxLookaheadMs / 1000.0 * max(8_000, sampleRate)).rounded()))
    }

    /// One-pole coefficient reaching ~63% of the target in `timeMs`.
    static func onePole(timeMs: Double, sampleRate: Double) -> Double {
        let t = max(0.02, timeMs) / 1000.0
        let n = max(1.0, t * sampleRate)
        return 1.0 - exp(-1.0 / n)
    }
}

// MARK: - Sliding maximum

/// Monotonic-deque sliding maximum over a fixed window. Amortised O(1) per
/// sample, zero allocation after `prepare`. Used so the gain target reflects
/// the loudest sample *still inside the lookahead window*.
final class SlidingPeakDetector {
    // Raw allocations, not Swift arrays: the render thread must not risk a
    // copy-on-write check or retain/release on the hot path.
    private var values: UnsafeMutablePointer<Float>
    private var indices: UnsafeMutablePointer<Int>
    private var head = 0          // front of deque (largest value)
    private var tail = 0          // one past the back
    private var capacity: Int
    private var position = 0      // absolute sample counter
    private(set) var window = 1

    init() {
        capacity = 2
        values = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        values.initialize(repeating: 0, count: capacity)
        indices = UnsafeMutablePointer<Int>.allocate(capacity: capacity)
        indices.initialize(repeating: 0, count: capacity)
    }

    deinit {
        values.deallocate()
        indices.deallocate()
    }

    func prepare(capacity: Int) {
        values.deallocate()
        indices.deallocate()
        // +1 so the ring never wraps onto its own head at full occupancy.
        self.capacity = max(2, capacity + 1)
        values = UnsafeMutablePointer<Float>.allocate(capacity: self.capacity)
        values.initialize(repeating: 0, count: self.capacity)
        indices = UnsafeMutablePointer<Int>.allocate(capacity: self.capacity)
        indices.initialize(repeating: 0, count: self.capacity)
        window = 1
        reset()
    }

    func reset() {
        head = 0
        tail = 0
        position = 0
    }

    /// Shrinking the window must drop entries that are already out of range,
    /// otherwise a stale peak keeps the gain pinned after the user lowers
    /// lookahead. Growing needs no fixup — the deque simply fills.
    func setWindow(_ w: Int) {
        let clamped = max(1, min(w, capacity - 1))
        guard clamped != window else { return }
        window = clamped
        while head != tail, indices[head] <= position - window {
            head = (head + 1) % capacity
        }
    }

    var isEmpty: Bool { head == tail }

    /// Push one sample, return the maximum across the current window.
    @inline(__always)
    func push(_ value: Float) -> Float {
        // Drop entries that can never be the maximum again.
        var back = tail
        while head != back {
            let prev = (back - 1 + capacity) % capacity
            if values[prev] <= value {
                back = prev
            } else {
                break
            }
        }
        tail = back
        values[tail] = value
        indices[tail] = position
        tail = (tail + 1) % capacity

        // Expire the front once it leaves the window.
        while head != tail, indices[head] <= position - window {
            head = (head + 1) % capacity
        }

        position &+= 1
        return values[head]
    }
}

// MARK: - DSP core

/// Pure limiter kernel. No AVFoundation / AudioToolbox dependency so it can be
/// driven directly from tests with plain `[Float]` buffers.
///
/// Stereo (and beyond) is **linked**: one detector, one gain, applied to every
/// channel, so limiting never moves the stereo image.
final class LimiterDSPCore {

    private(set) var sampleRate: Double = 48_000
    private(set) var channelCount: Int = 2

    private var coeffs = LimiterCoefficients()
    private let detector = SlidingPeakDetector()

    /// Per-channel lookahead delay lines, sized for `LimiterState.maxLookaheadMs`.
    /// One flat allocation, channel-major: channel `ch` occupies
    /// `delay[ch * delayCapacity ..< (ch + 1) * delayCapacity]`.
    private var delay: UnsafeMutablePointer<Float>?
    private var delayCapacity = 0
    private var delayChannels = 0
    private var writeIndex = 0

    /// Node-level bypass, set independently of the coefficients. ORed with
    /// `coeffs.bypass` at render time so neither source can cancel the other
    /// out. On the Mac the chain drives it from `ChainParameters.outputProtection`.
    var bypassOverride = false

    /// Smoothed gain reduction in dB (≤ 0).
    private var gainDB: Double = 0
    /// Slow envelope of |gain reduction|, drives the program-dependent release.
    private var sustainedGR: Double = 0

    /// True while the bypassed fast path is running, meaning the detector has
    /// not been fed and must be primed from the delay line before the full path
    /// can be trusted again. See `process`.
    private var detectorIdle = false

    /// Most recent gain reduction in dB, as a positive number, for metering.
    private(set) var gainReductionDB: Double = 0
    /// Peak output level (dBFS) observed during the last processed block.
    private(set) var outputPeakDB: Double = -120

    // MARK: Setup

    deinit {
        delay?.deallocate()
    }

    func prepare(sampleRate: Double, channelCount: Int) {
        self.sampleRate = max(8_000, sampleRate)
        self.channelCount = max(1, channelCount)
        delayCapacity = LimiterCoefficients.maxLookaheadSamples(sampleRate: self.sampleRate) + 2
        delayChannels = self.channelCount
        delay?.deallocate()
        let total = delayCapacity * delayChannels
        let buf = UnsafeMutablePointer<Float>.allocate(capacity: total)
        buf.initialize(repeating: 0, count: total)
        delay = buf
        detector.prepare(capacity: delayCapacity)
        reset()
    }

    func reset() {
        if let delay {
            delay.update(repeating: 0, count: delayCapacity * delayChannels)
        }
        writeIndex = 0
        gainDB = 0
        sustainedGR = 0
        gainReductionDB = 0
        outputPeakDB = -120
        detectorIdle = false
        detector.reset()
    }

    func update(_ new: LimiterCoefficients) {
        coeffs = new
        detector.setWindow(max(1, min(new.lookaheadSamples, delayCapacity - 1)))
    }

    var currentCoefficients: LimiterCoefficients { coeffs }

    /// True if any internal state has gone non-finite (the chain resets the
    /// stage if so — it should be impossible with sanitized input).
    var hasNonFiniteState: Bool { !gainDB.isFinite || !sustainedGR.isFinite }

    // MARK: Gain computer

    /// Static curve: input level (dB) → gain to apply (dB, ≤ 0).
    /// Soft knee is the standard quadratic interpolation across `kneeDB`,
    /// then a hard ceiling term guarantees the output bound.
    func staticGainDB(forInputDB inputDB: Double) -> Double {
        let c = coeffs
        let over = inputDB - c.thresholdDB
        let slope = 1.0 / c.ratio - 1.0        // ≤ 0
        var gain: Double

        if c.kneeDB > 0.0001, over > -c.kneeDB / 2, over < c.kneeDB / 2 {
            let x = over + c.kneeDB / 2
            gain = slope * x * x / (2 * c.kneeDB)
        } else if over >= c.kneeDB / 2 {
            gain = slope * over
        } else {
            gain = 0
        }

        // Enforce the ceiling *including* makeup, so makeup can never push the
        // output past it. This is what makes the stage a true brickwall.
        let projected = inputDB + gain + c.makeupDB
        if projected > c.ceilingDB {
            gain -= (projected - c.ceilingDB)
        }
        return min(0, gain)
    }

    // MARK: Processing

    /// Process `frameCount` frames in place across `channels`.
    /// Real-time safe: no allocation, no locks, no ObjC, no transcendental
    /// library calls per sample.
    func process(channels: UnsafeMutableBufferPointer<UnsafeMutablePointer<Float>>, frameCount: Int) {
        var c = coeffs
        c.bypass = c.bypass || bypassOverride
        guard let delay else { return }
        let chCount = min(channels.count, delayChannels)
        guard chCount > 0, frameCount > 0, delayCapacity > 1 else { return }

        let lookahead = max(1, min(c.lookaheadSamples, delayCapacity - 1))
        let ceilingLin = Float(c.ceilingLinear)
        let makeupLin = c.bypass ? 1.0 : c.makeupLinear
        let engage = Float(min(c.engageLinear, 1e30))
        var maxGR = 0.0
        var peakOut: Float = 0

        // ── Bypassed fast path ────────────────────────────────────────────────
        //
        // The delay line MUST keep running — latency is constant by contract, so
        // switching the limiter on and off cannot change alignment. Everything
        // else, though, provably cannot affect the output once the gain envelope
        // has unwound: `targetDB` is pinned at 0, `makeupLin` is 1, and the
        // ceiling clamp is skipped while bypassed. Measured on iOS, a bypassed
        // limiter cost ~90% of an active one before this fast path existed.
        //
        // The envelope is asymptotic, so it never reaches 0 exactly; below
        // 0.0005 dB (a linear gain within 6e-5 of unity) it is snapped so the
        // fast path is genuine bit-for-bit passthrough rather than nearly so.
        if c.bypass, gainDB > -0.0005 {
            gainDB = 0
            sustainedGR = 0
            detectorIdle = true

            for n in 0 ..< frameCount {
                let readIndex = (writeIndex - lookahead + delayCapacity) % delayCapacity
                for ch in 0 ..< chCount {
                    delay[ch * delayCapacity + writeIndex] = channels[ch][n]
                    let y = delay[ch * delayCapacity + readIndex]
                    channels[ch][n] = y
                    let a = abs(y)
                    if a > peakOut { peakOut = a }
                }
                writeIndex = (writeIndex + 1) % delayCapacity
            }

            gainReductionDB = 0
            outputPeakDB = peakOut > 0 ? 20.0 * log10(Double(peakOut)) : -120
            return
        }

        // Leaving the fast path: the detector has missed every sample that was
        // written while it was skipped, so it would under-read the peaks already
        // sitting in the delay line and let the first loud samples out past the
        // ceiling. Those samples are still in the delay line, so replay them.
        if detectorIdle {
            primeDetector(lookahead: lookahead, channelCount: chCount)
            detectorIdle = false
        }

        for n in 0 ..< frameCount {
            // --- write incoming into the delay line, find the linked peak
            var inPeak: Float = 0
            for ch in 0 ..< chCount {
                let x = channels[ch][n]
                delay[ch * delayCapacity + writeIndex] = x
                let a = abs(x)
                if a > inPeak { inPeak = a }
            }

            // --- detector runs *ahead* of the audio we are about to emit
            let windowPeak = detector.push(inPeak)

            // --- static curve. Below `engage` the curve is exactly 0 dB, so the
            //     level→dB conversion is skipped (Mac render-thread rule).
            var targetDB = 0.0
            if !c.bypass, windowPeak > engage {
                let peakDB = FastMath.linearToDB(max(Double(windowPeak), 1e-9))
                targetDB = staticGainDB(forInputDB: peakDB)
            }

            // --- program-dependent release
            // `sustainedGR` tracks how much reduction has been held recently.
            // Brief transients leave it near 0 → fast release. Loud passages
            // drive it up → release stretches toward 8× the set time, which
            // is what removes the pumping a fixed release causes.
            sustainedGR += (abs(targetDB) - sustainedGR) * c.sustainCoef
            if sustainedGR < 1e-12 { sustainedGR = 0 }            // denormal guard
            let blend = min(1.0, max(0.0, sustainedGR / 6.0))
            let releaseCoef = c.releaseFastCoef + (c.releaseSlowCoef - c.releaseFastCoef) * blend

            if targetDB < gainDB {
                gainDB += (targetDB - gainDB) * c.attackCoef
            } else {
                // While bypassed the envelope is only unwinding leftover
                // reduction, so it uses the fixed fast ramp rather than the
                // program-dependent release.
                gainDB += (targetDB - gainDB) * (c.bypass ? c.bypassReleaseCoef : releaseCoef)
                // Denormal guard + exact transparency once fully released.
                if targetDB == 0, gainDB > -1e-9 { gainDB = 0 }
            }

            let reduction = -gainDB
            if reduction > maxGR { maxGR = reduction }

            // --- emit the delayed sample with the current gain
            let readIndex = (writeIndex - lookahead + delayCapacity) % delayCapacity
            let linGain = Float((gainDB == 0 ? 1.0 : FastMath.dbToLinear(gainDB)) * makeupLin)

            for ch in 0 ..< chCount {
                var y = delay[ch * delayCapacity + readIndex] * linGain
                if !c.bypass {
                    // Final guard. With a correct attack the envelope has
                    // already arrived, so this clamps essentially nothing —
                    // it exists so the ceiling is a guarantee, not a hope.
                    if y > ceilingLin { y = ceilingLin }
                    if y < -ceilingLin { y = -ceilingLin }
                }
                channels[ch][n] = y
                let a = abs(y)
                if a > peakOut { peakOut = a }
            }

            writeIndex = (writeIndex + 1) % delayCapacity
        }

        gainReductionDB = maxGR
        outputPeakDB = peakOut > 0 ? 20.0 * log10(Double(peakOut)) : -120
    }

    /// Rebuild the sliding-peak window from the samples already in the delay
    /// line, so the detector resumes with exactly the state it would have had if
    /// it had been fed all along. O(lookahead) once per bypass→active edge —
    /// a few hundred samples, paid on a user action, never in steady state.
    private func primeDetector(lookahead: Int, channelCount chCount: Int) {
        guard let delay else { return }
        detector.reset()
        let count = min(lookahead, delayCapacity)
        var idx = (writeIndex - count + delayCapacity) % delayCapacity
        for _ in 0 ..< count {
            var linked: Float = 0
            for ch in 0 ..< chCount {
                let a = abs(delay[ch * delayCapacity + idx])
                if a > linked { linked = a }
            }
            _ = detector.push(linked)
            idx = (idx + 1) % delayCapacity
        }
    }

    /// Convenience mono path for tests.
    func process(_ samples: inout [Float]) {
        let count = samples.count
        samples.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            var ptr = base
            withUnsafeMutablePointer(to: &ptr) { p in
                let channels = UnsafeMutableBufferPointer(start: p, count: 1)
                process(channels: channels, frameCount: count)
            }
        }
    }
}
