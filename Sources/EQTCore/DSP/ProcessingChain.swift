//
//  ProcessingChain.swift
//  EQtargets (macOS)
//
//  CONTRACT FILE — the signatures below are frozen (other modules build
//  against them). Replace the stub bodies; do not rename or re-shape the API
//  without updating docs/ARCHITECTURE.md and every caller.
//
//  The whole DSP chain, run inside ONE render callback on the output device's
//  real-time thread:
//
//    ring (system mix) → Target PEQ (preamp + 10 biquads)
//                      → Fine-Tune PEQ (preamp + 10 biquads)
//                      → Bass Style static shape (4 biquads + loudness-matched gain)
//                      → Punch / Rumble dynamic stage (TransientPunchDSPCore)
//                      → Output protection (lookahead safety limiter, −1 dBFS)
//                      → output gain / mute (digital volume fallback)
//
//  Layer rules (product invariants, from the iOS app):
//   • Target and Fine-Tune are independent layers; Fine-Tune never overwrites Target.
//   • Bass Style never mutates Target / Fine-Tune; it runs after both.
//   • Graph == DSP: the PEQ stages use the same RBJ formulas as `EQBiquad`.
//
//  IMPLEMENTATION NOTES
//  ------------------------------------------------------------------
//  Parameter hand-off. `setParameters` (main thread) computes every coefficient
//  into a complete snapshot — plain values in preallocated slots, no Swift
//  arrays — and publishes it through a classic triple buffer whose middle slot
//  index lives in one `Atomic<Int>`. The render thread adopts the newest
//  snapshot at block start with a single atomic exchange; it never waits and
//  never sees a half-written snapshot. A writer-side lock serialises concurrent
//  `setParameters` calls; the render thread never touches it.
//
//  Everything glides:
//   • PEQ / Bass biquads interpolate coefficients over 20 ms (PEQProcessor).
//   • Preamps, Bass gain and output gain/mute ramp over 20 ms.
//   • Punch / Rumble switching on or off crossfades with its own input over
//     20 ms, and its crossover follows the cutoff slider in 8-sample steps
//     (the kernel itself is the verbatim iOS one; the chain only decides which
//     coefficients it gets and when).
//   • masterBypass crossfades 10 ms between processed and dry.
//
//  Latency is constant: the limiter's 1.5 ms lookahead delays the processed
//  path whether protection is on or off (its delay line keeps running), and the
//  dry path runs through a delay line of the same length. Bypassed output is
//  therefore the input, bit for bit, `latencyFrames` later — so toggling bypass
//  never shifts timing and the crossfade never combs.
//
//  The processed path keeps running while bypassed, so A/B toggling resumes
//  with warm filter / envelope state instead of a cold start.
//
//  Digital output gain / mute applies in bypass too: it is the volume control
//  for outputs without hardware volume, and the volume keys must keep working
//  when the EQ is bypassed. At 0 dB / unmuted it is skipped (bit-exact).
//

import Foundation
import Synchronization
import os

/// Everything the render thread needs, as one value. Built on the main thread.
struct ChainParameters: Equatable {
    var dual: DualEQState = .flat
    var bass: BassProcessorState = .flat
    /// Transparent lookahead safety limiter at the end of the chain (ceiling
    /// −1 dBFS). On by default; it only acts on overs.
    var outputProtection: Bool = true
    /// Everything off: audio keeps flowing through the same route, samples untouched.
    var masterBypass: Bool = false
    /// Digital output gain in dB, applied last. Used when the real output
    /// device has no hardware volume control (volume mirroring falls back to it).
    var outputGainDB: Double = 0
    var outputMuted: Bool = false
}

/// Live values for the UI. All magnitudes in dB.
struct ChainMeters: Equatable {
    /// Punch attack boost / Rumble sustain lift currently applied (≥ 0).
    var punchBoostDB: Double = 0
    /// Punch sustain trim / Rumble attack softening currently applied (≥ 0).
    var punchTrimDB: Double = 0
    /// Safety limiter gain reduction (≥ 0).
    var limiterReductionDB: Double = 0
    /// Peak |x| entering the chain since the last `meters()` call, dBFS (−120 = silence).
    var inputPeakDB: Double = -120
    /// Peak |x| leaving the chain since the last `meters()` call, dBFS.
    var outputPeakDB: Double = -120
    /// Count of blocks where the chain output would have exceeded 0 dBFS
    /// without output protection (lifetime counter; UI shows "clipping" when it moves).
    var overCount: Int = 0
}

/// Timing constants of the chain's smoothing. Internal: tests shorten them to
/// zero to prove each one is what removes a click (negative controls).
/// Read at `prepare`.
struct ChainTuning: Equatable {
    /// Biquad coefficient / preamp / bass gain / output gain glide.
    var parameterGlideMs: Double = 20
    /// masterBypass crossfade.
    var bypassCrossfadeMs: Double = 10
    /// Punch / Rumble engage ↔ disengage crossfade, and crossover glide length.
    var stageCrossfadeMs: Double = 20
    /// `requestReset` fades out, clears state, fades back in over this each way.
    var resetDuckMs: Double = 3
}

/// Real-time DSP chain. One instance per output stream.
///
/// Threading: `prepare` / `reset` on a non-RT thread with rendering stopped;
/// `setParameters` on the main thread at any time; `process` on the render
/// thread; `meters` from any thread. `process` must never allocate, lock,
/// call into the ObjC runtime, or touch a Swift array / class reference in a
/// way that retains.
final class ProcessingChain: @unchecked Sendable {

    // MARK: Configuration

    private let maxFrames: Int
    private var maxChannels: Int
    private(set) var sampleRate: Double = 48_000
    private(set) var channelCount: Int = 2
    var tuning = ChainTuning()

    // MARK: Main-thread side (guarded by writerLock)

    private let writerLock: UnsafeMutablePointer<os_unfair_lock>
    private var lastParameters = ChainParameters()
    private var backSlot = 2

    // MARK: Snapshot triple buffer

    private static let sectionsPerSlot = 24     // Target 10 + Fine-Tune 10 + Bass 4
    private static let freshBit = 4
    private let snapshots: UnsafeMutablePointer<ChainSnapshot>        // 3 slots
    private let sectionPool: UnsafeMutablePointer<PEQSectionTarget>   // 3 × 24
    /// Middle slot index | freshBit.
    private let middle = Atomic<Int>(1)
    private var frontSlot = 0                                          // render thread

    // MARK: Render-thread state

    // `let`: reconfigured in place by `prepare`, so render-thread calls never
    // retain / release them.
    private let targetPEQ = PEQProcessor(sectionCount: 10, channelCount: 2, glideSamples: 0)
    private let finePEQ = PEQProcessor(sectionCount: 10, channelCount: 2, glideSamples: 0)
    private let bassPEQ = PEQProcessor(sectionCount: BassProcessorState.bandCount, channelCount: 2, glideSamples: 0)
    private let punch = TransientPunchDSPCore()
    private let limiter = LimiterDSPCore()

    /// Planar Double scratch for the linear section, maxChannels × maxFrames.
    private var linear: UnsafeMutablePointer<Double>
    private var linearPtrs: UnsafeMutablePointer<UnsafeMutablePointer<Double>>
    /// Channel pointer table for one sub-block (offset into the caller's buffers).
    private var blockPtrs: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    /// Pointer table for the punch kernel's 32-sample sub-blocks.
    private var subPtrs: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    /// Punch stage dry copy while it crossfades, maxChannels × maxFrames.
    private var punchDry: UnsafeMutablePointer<Float>
    /// Dry delay line (same length as the limiter lookahead), per channel
    /// laid out [latency history][current block] so the delayed block is contiguous.
    private var dryLine: UnsafeMutablePointer<Float>
    private var dryStride = 0
    private var latency = 0

    private var glideSamples = 960
    private var stageFadeSamples = 960
    private var bypassFadeSamples = 480
    private var duckSamples = 144

    // Punch stage driver
    private var punchApplied = TransientPunchCoefficients()   // what the kernel runs now
    private var punchGoal = TransientPunchCoefficients()      // latest from the snapshot
    private var punchEngaged = false
    /// 0 = the punch stage's own input (dry), 1 = its output.
    private var punchMix = SmoothRamp(0)
    private var xoverLeft = 0
    private var xoverStep = Crossover()
    /// Where the crossover glide ends. Kept separately from `punchGoal`: when
    /// the style is switched off mid-glide, `punchGoal` becomes the bypass
    /// coefficients (all zeros) — landing on those collapsed the crossover and
    /// clicked (caught by the Bass Style switching test).
    private var xoverGoal = Crossover()

    /// The eight LR4 crossover coefficients of TransientPunchCoefficients.
    private struct Crossover: Equatable {
        var lpB0 = 0.0, lpB1 = 0.0, lpB2 = 0.0, hpB0 = 0.0, hpB1 = 0.0, hpB2 = 0.0, a1 = 0.0, a2 = 0.0

        init() {}
        init(_ c: TransientPunchCoefficients) {
            lpB0 = c.lpB0; lpB1 = c.lpB1; lpB2 = c.lpB2
            hpB0 = c.hpB0; hpB1 = c.hpB1; hpB2 = c.hpB2
            a1 = c.a1; a2 = c.a2
        }
        func apply(to c: inout TransientPunchCoefficients) {
            c.lpB0 = lpB0; c.lpB1 = lpB1; c.lpB2 = lpB2
            c.hpB0 = hpB0; c.hpB1 = hpB1; c.hpB2 = hpB2
            c.a1 = a1; c.a2 = a2
        }
    }

    /// The punch kernel reads its crossover once per call, so a crossover glide
    /// runs the kernel in sub-blocks of this many samples and steps the
    /// coefficients between them. 8 → 120 steps over 20 ms: switching Punch →
    /// Rumble (crossover moves an octave) measured −73 dB of ≥8 kHz splatter at
    /// 32-sample steps and stays under −80 dB at 8. Only during the glide.
    static let crossoverStepSamples = 8

    /// Kernel coefficients in force right now (tests / diagnostics).
    var punchCoefficientsInForce: TransientPunchCoefficients { punch.currentCoefficients }

    // Master bypass + output gain + reset duck
    /// masterBypass: 0 = dry (delayed input), 1 = processed.
    private var wetMix = SmoothRamp(1)
    private var outGain = SmoothRamp(1)
    /// requestReset: the OUTPUT fades out, every state is cleared while the
    /// output is silent, then the INPUT fades back in — so the restarted filters
    /// never see a step (an onset under a running signal is itself a click), and
    /// the lookahead delay lines are emptied while nothing is audible.
    private var duckOut = SmoothRamp(1)
    private var duckIn = SmoothRamp(1)
    private var duckPending = false

    // MARK: Cross-thread flags and meters

    private let resetRequested = Atomic<Bool>(false)
    private let latencyAtomic = Atomic<Int>(0)
    private let inPeak = AtomicPeak()
    private let outPeak = AtomicPeak()
    private let punchBoostMax = AtomicPeak()
    private let punchTrimMax = AtomicPeak()
    private let reductionMax = AtomicPeak()
    private let punchBoostLatest = AtomicPeak()
    private let punchTrimLatest = AtomicPeak()
    private let reductionLatest = AtomicPeak()
    private let blocksSinceRead = Atomic<Int>(0)
    private let overs = Atomic<Int>(0)

    // MARK: - Lifecycle

    init(maxFrames: Int = 4096, maxChannels: Int = 2) {
        self.maxFrames = max(32, maxFrames)
        self.maxChannels = max(1, maxChannels)
        writerLock = .allocate(capacity: 1)
        writerLock.initialize(to: os_unfair_lock())
        snapshots = .allocate(capacity: 3)
        snapshots.initialize(repeating: ChainSnapshot(), count: 3)
        sectionPool = .allocate(capacity: 3 * Self.sectionsPerSlot)
        sectionPool.initialize(repeating: .identity, count: 3 * Self.sectionsPerSlot)

        // Placeholders; `prepare` replaces them.
        linear = .allocate(capacity: 1)
        linearPtrs = .allocate(capacity: 1)
        blockPtrs = .allocate(capacity: 1)
        subPtrs = .allocate(capacity: 1)
        punchDry = .allocate(capacity: 1)
        dryLine = .allocate(capacity: 1)

        // Usable immediately (48 kHz, maxChannels) even before `prepare`.
        prepare(sampleRate: 48_000, channelCount: self.maxChannels)
    }

    deinit {
        freeBuffers()
        writerLock.deinitialize(count: 1)
        writerLock.deallocate()
        snapshots.deallocate()
        sectionPool.deallocate()
    }

    private func freeBuffers() {
        linear.deallocate()
        linearPtrs.deallocate()
        blockPtrs.deallocate()
        subPtrs.deallocate()
        punchDry.deallocate()
        dryLine.deallocate()
    }

    /// Non-RT. (Re)allocates all state for this format.
    func prepare(sampleRate: Double, channelCount: Int) {
        os_unfair_lock_lock(writerLock)
        defer { os_unfair_lock_unlock(writerLock) }

        let sr = sampleRate.isFinite && sampleRate >= 8_000 ? sampleRate : 48_000
        self.sampleRate = sr
        self.channelCount = max(1, channelCount)
        maxChannels = max(maxChannels, self.channelCount)
        let nCh = self.channelCount

        func samples(_ ms: Double) -> Int {
            guard ms.isFinite, ms > 0 else { return 0 }
            return Int((min(ms, 1_000) / 1000 * sr).rounded())
        }
        glideSamples = samples(tuning.parameterGlideMs)
        stageFadeSamples = samples(tuning.stageCrossfadeMs)
        bypassFadeSamples = samples(tuning.bypassCrossfadeMs)
        duckSamples = samples(tuning.resetDuckMs)

        // Stages
        targetPEQ.configure(channelCount: nCh, glideSamples: glideSamples)
        finePEQ.configure(channelCount: nCh, glideSamples: glideSamples)
        bassPEQ.configure(channelCount: nCh, glideSamples: glideSamples)
        punch.prepare(sampleRate: sr, channelCount: nCh)
        limiter.prepare(sampleRate: sr, channelCount: nCh)
        let lc = LimiterCoefficients.make(from: .outputProtection, sampleRate: sr)
        limiter.update(lc)
        latency = lc.lookaheadSamples
        latencyAtomic.store(latency, ordering: .relaxed)

        // Buffers
        freeBuffers()
        linear = .allocate(capacity: nCh * maxFrames)
        linear.initialize(repeating: 0, count: nCh * maxFrames)
        linearPtrs = .allocate(capacity: nCh)
        for ch in 0 ..< nCh { (linearPtrs + ch).initialize(to: linear + ch * maxFrames) }
        punchDry = .allocate(capacity: nCh * maxFrames)
        punchDry.initialize(repeating: 0, count: nCh * maxFrames)
        blockPtrs = .allocate(capacity: nCh)
        blockPtrs.initialize(repeating: punchDry, count: nCh)
        subPtrs = .allocate(capacity: nCh)
        subPtrs.initialize(repeating: punchDry, count: nCh)
        dryStride = latency + maxFrames
        dryLine = .allocate(capacity: nCh * dryStride)
        dryLine.initialize(repeating: 0, count: nCh * dryStride)

        // Parameters → slot 0, adopted instantly (no glide from stale state).
        frontSlot = 0
        backSlot = 2
        middle.store(1, ordering: .releasing)
        snapshots[0] = Self.buildSnapshot(lastParameters, sampleRate: sr, sections: sectionPool)
        adopt(slot: 0, instant: true)
        hardResetStages()
        clearMeters()
    }

    /// Main thread. Computes every coefficient HERE (never on the render
    /// thread) and hands the result to the render thread lock-free. Parameter
    /// changes must glide — dragging a band or a slider never clicks or zips.
    func setParameters(_ parameters: ChainParameters) {
        os_unfair_lock_lock(writerLock)
        defer { os_unfair_lock_unlock(writerLock) }
        lastParameters = parameters
        let slot = backSlot
        snapshots[slot] = Self.buildSnapshot(
            parameters, sampleRate: sampleRate,
            sections: sectionPool + slot * Self.sectionsPerSlot
        )
        let old = middle.exchange(slot | Self.freshBit, ordering: .acquiringAndReleasing)
        backSlot = old & 3
    }

    /// Non-RT: clear all filter / envelope / limiter state.
    func reset() {
        os_unfair_lock_lock(writerLock)
        defer { os_unfair_lock_unlock(writerLock) }
        adoptFreshSnapshot()
        targetPEQ.snapToTargets()
        finePEQ.snapToTargets()
        bassPEQ.snapToTargets()
        wetMix.settle()
        outGain.settle()
        punchApplied = punchGoal
        punchEngaged = !punchGoal.bypass
        punchMix = SmoothRamp(punchEngaged ? 1 : 0)
        xoverGoal = Crossover(punchGoal)
        duckOut = SmoothRamp(1)
        duckIn = SmoothRamp(1)
        duckPending = false
        punch.update(punchApplied)
        xoverLeft = 0
        hardResetStages()
        clearMeters()
        _ = resetRequested.exchange(false, ordering: .relaxed)
    }

    /// RT-safe: clear filter state at the start of the next `process` call
    /// (used after the input stream jumps, so stale filter memory can't ring).
    ///
    /// Clearing state under a running signal is itself a discontinuity, so the
    /// chain ducks the output for `resetDuckMs` (3 ms), clears everything at
    /// the bottom of the duck, and fades back in — the clear lands in silence.
    func requestReset() {
        resetRequested.store(true, ordering: .releasing)
    }

    /// Latency the chain adds (the safety limiter's lookahead), in frames.
    var latencyFrames: Int { latencyAtomic.load(ordering: .relaxed) }

    // MARK: - Meters

    /// Any thread, lock-free. Peak fields reset on read.
    ///
    /// Punch / limiter values report the largest value since the previous
    /// read (so a punch between two UI polls is not lost); if no block was
    /// processed in between they report the most recent block's value.
    func meters() -> ChainMeters {
        var m = ChainMeters()
        let blocks = blocksSinceRead.exchange(0, ordering: .acquiring)
        if blocks > 0 {
            m.punchBoostDB = punchBoostMax.take()
            m.punchTrimDB = punchTrimMax.take()
            m.limiterReductionDB = reductionMax.take()
        } else {
            m.punchBoostDB = punchBoostLatest.load()
            m.punchTrimDB = punchTrimLatest.load()
            m.limiterReductionDB = reductionLatest.load()
        }
        m.inputPeakDB = Self.peakDB(inPeak.take())
        m.outputPeakDB = Self.peakDB(outPeak.take())
        m.overCount = overs.load(ordering: .relaxed)
        return m
    }

    private static func peakDB(_ linear: Double) -> Double {
        linear > 1e-6 ? max(-120, 20 * log10(linear)) : -120
    }

    private func clearMeters() {
        _ = inPeak.take(); _ = outPeak.take()
        _ = punchBoostMax.take(); _ = punchTrimMax.take(); _ = reductionMax.take()
        punchBoostLatest.store(0); punchTrimLatest.store(0); reductionLatest.store(0)
        blocksSinceRead.store(0, ordering: .relaxed)
    }

    // MARK: - Snapshot (main thread)

    /// Plain values only: copied wholesale by the render thread.
    struct ChainSnapshot {
        var targetGain = 1.0
        var fineGain = 1.0
        var bassGain = 1.0
        var outputGain = 1.0
        var masterBypass = false
        var outputProtection = true
        var punch = TransientPunchCoefficients()
    }

    /// Builds a complete snapshot: sanitises every parameter (NaN / Inf / out of
    /// range never reach the render thread) and computes all coefficients.
    static func buildSnapshot(_ p: ChainParameters, sampleRate sr: Double,
                              sections: UnsafeMutablePointer<PEQSectionTarget>) -> ChainSnapshot {
        var s = ChainSnapshot()
        let dualOff = p.dual.isBypassed
        s.targetGain = layerSections(p.dual.target, bypassed: dualOff, sampleRate: sr, into: sections)
        s.fineGain = layerSections(p.dual.fineTune, bypassed: dualOff, sampleRate: sr, into: sections + 10)

        let bass = sanitizedBass(p.bass)
        let unit = BassProcessorDSP.unitParams(from: bass, sampleRate: sr)
        let bassSections = sections + 20
        for i in 0 ..< BassProcessorState.bandCount {
            guard !unit.unitBypass, i < unit.bands.count else { bassSections[i] = .identity; continue }
            let b = unit.bands[i]
            if b.bypass || !b.gainDB.isFinite || abs(b.gainDB) < 0.001 {
                bassSections[i] = .identity
            } else {
                let c = BiquadCoefficients(type: b.type, frequency: clampFrequency(b.frequency, sr),
                                           gainDB: b.gainDB, q: max(0.05, b.q), sampleRate: sr)
                bassSections[i] = c.isFinite && c.isStable ? .filter(c) : .identity
            }
        }
        let bassDB = unit.unitBypass || !unit.globalGainDB.isFinite ? 0 : unit.globalGainDB
        s.bassGain = pow(10, min(max(bassDB, -40), 40) / 20)

        s.punch = TransientPunchCoefficients.make(from: bass, sampleRate: sr)
        s.masterBypass = p.masterBypass
        s.outputProtection = p.outputProtection
        if p.outputMuted {
            s.outputGain = 0
        } else {
            // Volume fallback: attenuation only. A boost here would land after
            // the limiter and defeat output protection, so it is clamped to 0 dB.
            let db = p.outputGainDB.isFinite ? min(p.outputGainDB, 0) : 0
            s.outputGain = db <= -120 ? 0 : pow(10, db / 20)
        }
        return s
    }

    private static func layerSections(_ layer: EQLayerState, bypassed: Bool, sampleRate sr: Double,
                                      into out: UnsafeMutablePointer<PEQSectionTarget>) -> Double {
        for i in 0 ..< 10 { out[i] = .identity }
        guard !bypassed, !layer.isBypassed else { return 1 }
        for i in 0 ..< min(10, layer.bands.count) {
            let b = layer.bands[i]
            guard b.isEnabled else { continue }
            let gain = b.gain.isFinite ? min(max(b.gain, EQBand.gainRange.lowerBound), EQBand.gainRange.upperBound) : 0
            guard abs(gain) >= 0.001 else { continue }
            let q = b.q.isFinite ? min(max(b.q, EQBand.qRange.lowerBound), EQBand.qRange.upperBound) : 1
            let f = b.frequency.isFinite ? clampFrequency(b.frequency, sr) : 1_000
            let c = BiquadCoefficients(type: b.filterType, frequency: f, gainDB: gain, q: q, sampleRate: sr)
            out[i] = c.isFinite && c.isStable ? .filter(c) : .identity
        }
        let pre = layer.preamp.isFinite
            ? min(max(layer.preamp, EQLayerState.preampRange.lowerBound), EQLayerState.preampRange.upperBound)
            : 0
        return pow(10, pre / 20)
    }

    private static func clampFrequency(_ f: Double, _ sr: Double) -> Double {
        min(max(f, EQBand.frequencyRange.lowerBound), min(EQBand.frequencyRange.upperBound, sr * 0.49))
    }

    /// `BassProcessorState.sanitize` clamps with min/max, which let NaN through.
    private static func sanitizedBass(_ b: BassProcessorState) -> BassProcessorState {
        var s = b
        let d = BassProcessorState()
        if !s.strength.isFinite { s.strength = d.strength }
        if !s.cutoff.isFinite { s.cutoff = d.cutoff }
        if !s.postGain.isFinite { s.postGain = d.postGain }
        if !s.punchAttack.isFinite { s.punchAttack = d.punchAttack }
        if !s.punchSustain.isFinite { s.punchSustain = d.punchSustain }
        if !s.rumbleSustain.isFinite { s.rumbleSustain = d.rumbleSustain }
        if !s.rumbleSoften.isFinite { s.rumbleSoften = d.rumbleSoften }
        s.sanitize()
        return s
    }

    // MARK: - Snapshot adoption (render thread)

    private func adoptFreshSnapshot() {
        guard middle.load(ordering: .relaxed) & Self.freshBit != 0 else { return }
        let old = middle.exchange(frontSlot, ordering: .acquiringAndReleasing)
        frontSlot = old & 3
        adopt(slot: frontSlot, instant: false)
    }

    private func adopt(slot: Int, instant: Bool) {
        let s = snapshots[slot]
        let sec = sectionPool + slot * Self.sectionsPerSlot
        targetPEQ.setGain(s.targetGain)
        finePEQ.setGain(s.fineGain)
        bassPEQ.setGain(s.bassGain)
        for i in 0 ..< 10 {
            targetPEQ.setTarget(i, sec[i])
            finePEQ.setTarget(i, sec[10 + i])
        }
        for i in 0 ..< BassProcessorState.bandCount { bassPEQ.setTarget(i, sec[20 + i]) }

        limiter.bypassOverride = !s.outputProtection
        wetMix.retarget(s.masterBypass ? 0 : 1, samples: bypassFadeSamples)
        outGain.retarget(s.outputGain, samples: glideSamples)
        adoptPunch(s.punch)

        if instant {
            targetPEQ.snapToTargets()
            finePEQ.snapToTargets()
            bassPEQ.snapToTargets()
            wetMix.settle()
            outGain.settle()
            punchApplied = punchGoal
            punchEngaged = !punchGoal.bypass
            punchMix = SmoothRamp(punchEngaged ? 1 : 0)
            xoverGoal = Crossover(punchGoal)
            xoverLeft = 0
            punch.update(punchApplied)
        }
    }

    /// Decide what the Punch / Rumble kernel runs. The kernel is verbatim iOS:
    /// an instant coefficient swap would switch its crossover (and, on
    /// engage/disengage, switch between the allpass-phased crossover sum and the
    /// dry signal) mid-waveform, which clicks on bass. So:
    ///   off → on:  reset the kernel, engage, crossfade dry → wet;
    ///   on → off:  keep running, crossfade wet → dry, then disengage;
    ///   on → on:   gains / ballistics switch now (the kernel smooths its own
    ///              gain); the crossover glides in 32-sample steps.
    private func adoptPunch(_ goal: TransientPunchCoefficients) {
        punchGoal = goal
        if goal.bypass {
            // Keep running on the current coefficients while fading out.
            if punchEngaged { punchMix.retarget(0, samples: stageFadeSamples) }
            return
        }
        if !punchEngaged {
            punch.reset()
            punchApplied = goal
            punch.update(goal)
            punchEngaged = true
            xoverLeft = 0
            xoverGoal = Crossover(goal)
            punchMix = SmoothRamp(0)
            punchMix.retarget(1, samples: stageFadeSamples)
            return
        }
        punchMix.retarget(1, samples: stageFadeSamples)
        // Gains, amounts, mode and ballistics switch now (the kernel smooths its
        // own gain); the crossover keeps its current position…
        var next = goal
        Crossover(punchApplied).apply(to: &next)
        // …and glides toward the goal's — restarted only if that goal MOVED.
        // Re-sending identical parameters (the UI does, at drag rate) must not
        // restart the glide, or it never lands.
        let target = Crossover(goal)
        if target != xoverGoal {
            xoverGoal = target
            let steps = stageFadeSamples / Self.crossoverStepSamples
            if steps > 0 {
                let a = Crossover(punchApplied)
                let inv = 1.0 / Double(steps)
                xoverStep = Crossover()
                xoverStep.lpB0 = (target.lpB0 - a.lpB0) * inv
                xoverStep.lpB1 = (target.lpB1 - a.lpB1) * inv
                xoverStep.lpB2 = (target.lpB2 - a.lpB2) * inv
                xoverStep.hpB0 = (target.hpB0 - a.hpB0) * inv
                xoverStep.hpB1 = (target.hpB1 - a.hpB1) * inv
                xoverStep.hpB2 = (target.hpB2 - a.hpB2) * inv
                xoverStep.a1 = (target.a1 - a.a1) * inv
                xoverStep.a2 = (target.a2 - a.a2) * inv
                xoverLeft = steps
            } else {
                target.apply(to: &next)
                xoverLeft = 0
            }
        }
        punchApplied = next
        punch.update(next)
    }

    // MARK: - Processing (render thread)

    /// Render thread. Processes `frameCount` frames in place, non-interleaved float.
    func process(_ channels: UnsafeMutableBufferPointer<UnsafeMutablePointer<Float>>, frameCount: Int) {
        let nCh = min(channels.count, channelCount)
        guard nCh > 0, frameCount > 0, let base = channels.baseAddress else { return }

        adoptFreshSnapshot()
        if resetRequested.exchange(false, ordering: .acquiring) {
            if duckSamples == 0 {
                hardResetStages()
            } else {
                duckPending = true
                duckOut.retarget(0, samples: duckSamples)
            }
        }

        var stats = BlockStats()
        var offset = 0
        while offset < frameCount {
            var n = min(maxFrames, frameCount - offset)
            if duckPending { n = min(n, duckOut.remainingSamples) }   // reset lands on a block edge
            for ch in 0 ..< nCh { blockPtrs[ch] = base[ch] + offset }
            renderBlock(n, nCh, &stats)
            if duckPending, duckOut.isSettled {
                // Output is silent now: clear everything, then let the input back in.
                hardResetStages()
                duckPending = false
                duckOut = SmoothRamp(1)
                duckIn = SmoothRamp(0)
                duckIn.retarget(1, samples: duckSamples)
            }
            offset += n
        }

        // Publish meters.
        inPeak.raise(to: stats.inPeak)
        outPeak.raise(to: stats.outPeak)
        let audibleWet = wetMix.value > 0 || wetMix.goal > 0
        let boost = audibleWet && punchEngaged ? stats.punchBoost : 0
        let trim = audibleWet && punchEngaged ? stats.punchTrim : 0
        let gr = audibleWet ? stats.reduction : 0
        punchBoostLatest.store(boost); punchTrimLatest.store(trim); reductionLatest.store(gr)
        punchBoostMax.raise(to: boost); punchTrimMax.raise(to: trim); reductionMax.raise(to: gr)
        if stats.over { overs.add(1, ordering: .relaxed) }
        blocksSinceRead.add(1, ordering: .releasing)
    }

    private struct BlockStats {
        var inPeak = 0.0
        var outPeak = 0.0
        var punchBoost = 0.0
        var punchTrim = 0.0
        var reduction = 0.0
        var over = false
    }

    private func renderBlock(_ n: Int, _ nCh: Int, _ stats: inout BlockStats) {
        let io = UnsafeMutableBufferPointer(start: blockPtrs, count: nCh)

        // 1. Sanitise input (a NaN from any app would poison every filter state),
        //    measure its peak, and push it through the dry delay line.
        var inPk: Float = 0
        let ducking = !(duckIn.isSettled && duckIn.value == 1)
        var dIn = duckIn
        for ch in 0 ..< nCh {
            let x = blockPtrs[ch]
            let line = dryLine + ch * dryStride + latency
            dIn = duckIn
            for i in 0 ..< n {
                var v = x[i]
                let a = abs(v)
                if !(a <= 1e30) { v = 0 } else if a > inPk { inPk = a }
                if ducking { v *= Float(dIn.next()) }
                x[i] = v
                line[i] = v
            }
        }
        duckIn = dIn
        stats.inPeak = max(stats.inPeak, Double(inPk))

        // 2. Linear section: Target → Fine-Tune → Bass static shape, in Double.
        if !(targetPEQ.isTransparent && finePEQ.isTransparent && bassPEQ.isTransparent) {
            for ch in 0 ..< nCh {
                let x = blockPtrs[ch], d = linearPtrs[ch]
                for i in 0 ..< n { d[i] = Double(x[i]) }
            }
            targetPEQ.process(linearPtrs, frames: n)
            finePEQ.process(linearPtrs, frames: n)
            bassPEQ.process(linearPtrs, frames: n)
            if !targetPEQ.isFinite { targetPEQ.snapToTargets() }
            if !finePEQ.isFinite { finePEQ.snapToTargets() }
            if !bassPEQ.isFinite { bassPEQ.snapToTargets() }
            for ch in 0 ..< nCh {
                let x = blockPtrs[ch], d = linearPtrs[ch]
                for i in 0 ..< n { x[i] = Float(d[i]) }
            }
        }

        // 3. Punch / Rumble dynamic stage.
        runPunch(n, nCh, &stats)

        // 4. Over detection: would the output clip without protection?
        let gainCeiling = max(outGain.value, outGain.goal)
        if gainCeiling > 0 {
            var pre: Float = 0
            if wetMix.value > 0 || wetMix.goal > 0 {
                for ch in 0 ..< nCh {
                    let x = blockPtrs[ch]
                    for i in 0 ..< n { let a = abs(x[i]); if a > pre { pre = a } }
                }
            }
            if wetMix.value < 1 || wetMix.goal < 1 { pre = max(pre, inPk) }
            if Double(pre) * gainCeiling > 1.0 { stats.over = true }
        }

        // 5. Output protection (delay line always runs → constant latency).
        limiter.process(channels: io, frameCount: n)
        stats.reduction = max(stats.reduction, limiter.gainReductionDB)
        if limiter.hasNonFiniteState { limiter.reset() }

        // 6. Master bypass crossfade against the equally delayed dry signal.
        if !(wetMix.isSettled && wetMix.value == 1) {
            var w = wetMix
            for ch in 0 ..< nCh {
                let x = blockPtrs[ch]
                let dry = dryLine + ch * dryStride
                w = wetMix
                if w.isSettled, w.value == 0 {
                    x.update(from: dry, count: n)          // bit-exact dry
                    continue
                }
                for i in 0 ..< n {
                    let g = w.next()
                    if g == 0 { x[i] = dry[i] } else if g != 1 { x[i] = dry[i] + Float(g) * (x[i] - dry[i]) }
                }
            }
            wetMix = w
        }

        // 7. Output gain / mute, then the reset duck's fade-out.
        applyRamp(&outGain, n, nCh)
        if duckPending || !(duckOut.isSettled && duckOut.value == 1) { applyRamp(&duckOut, n, nCh) }

        // 8. Final guard + output peak. Anything non-finite here means a stage
        //    blew up: silence those samples and restart every stage clean.
        var outPk: Float = 0
        var blewUp = false
        for ch in 0 ..< nCh {
            let x = blockPtrs[ch]
            for i in 0 ..< n {
                let a = abs(x[i])
                if !(a <= 1e30) { x[i] = 0; blewUp = true } else if a > outPk { outPk = a }
            }
        }
        stats.outPeak = max(stats.outPeak, Double(outPk))
        if blewUp { hardResetStages() }

        // 9. Slide the dry delay line: keep the newest `latency` samples.
        if latency > 0 {
            for ch in 0 ..< nCh {
                let line = dryLine + ch * dryStride
                line.update(from: line + n, count: latency)
            }
        }
    }

    private func runPunch(_ n: Int, _ nCh: Int, _ stats: inout BlockStats) {
        guard punchEngaged else { return }
        let crossfading = !(punchMix.isSettled && punchMix.value == 1)
        if crossfading {
            for ch in 0 ..< nCh { (punchDry + ch * maxFrames).update(from: blockPtrs[ch], count: n) }
        }

        if xoverLeft > 0 {
            // Walk the crossover toward the goal in control-rate steps.
            let chunk = Self.crossoverStepSamples
            var i = 0
            while i < n {
                let m = min(chunk, n - i)
                if xoverLeft > 0 {
                    xoverLeft -= 1
                    var c = punchApplied
                    if xoverLeft == 0 {
                        xoverGoal.apply(to: &c)              // land exactly
                    } else {
                        c.lpB0 += xoverStep.lpB0; c.lpB1 += xoverStep.lpB1; c.lpB2 += xoverStep.lpB2
                        c.hpB0 += xoverStep.hpB0; c.hpB1 += xoverStep.hpB1; c.hpB2 += xoverStep.hpB2
                        c.a1 += xoverStep.a1; c.a2 += xoverStep.a2
                    }
                    punchApplied = c
                    punch.update(c)
                }
                for ch in 0 ..< nCh { subPtrs[ch] = blockPtrs[ch] + i }
                punch.process(channels: UnsafeMutableBufferPointer(start: subPtrs, count: nCh), frameCount: m)
                stats.punchBoost = max(stats.punchBoost, punch.attackBoostDB)
                stats.punchTrim = max(stats.punchTrim, punch.sustainTrimDB)
                i += m
            }
        } else {
            punch.process(channels: UnsafeMutableBufferPointer(start: blockPtrs, count: nCh), frameCount: n)
            stats.punchBoost = max(stats.punchBoost, punch.attackBoostDB)
            stats.punchTrim = max(stats.punchTrim, punch.sustainTrimDB)
        }
        // Envelopes are the only kernel state it exposes; a non-finite one means
        // the stage must restart. (Its output, if non-finite, is silenced by the
        // final guard in `renderBlock`.)
        if !punch.fastEnv.isFinite || !punch.slowEnv.isFinite { punch.reset() }

        if crossfading {
            var w = punchMix
            for ch in 0 ..< nCh {
                let x = blockPtrs[ch], dry = punchDry + ch * maxFrames
                w = punchMix
                for i in 0 ..< n {
                    let g = w.next()
                    if g != 1 { x[i] = dry[i] + Float(g) * (x[i] - dry[i]) }
                }
            }
            punchMix = w
            if punchMix.isSettled, punchMix.value == 0 {
                // Fully faded out: stop the kernel. It is reset on the next engage.
                punchEngaged = false
                punchApplied = punchGoal
                punch.update(punchGoal)
                xoverLeft = 0
            }
        }
    }

    /// Multiply every channel by a (possibly ramping) gain.
    private func applyRamp(_ ramp: inout SmoothRamp, _ n: Int, _ nCh: Int) {
        if ramp.isSettled {
            let g = ramp.value
            guard g != 1 else { return }
            let f = Float(g)
            for ch in 0 ..< nCh {
                let x = blockPtrs[ch]
                for i in 0 ..< n { x[i] *= f }
            }
            return
        }
        var r = ramp
        for ch in 0 ..< nCh {
            r = ramp
            let x = blockPtrs[ch]
            for i in 0 ..< n { x[i] *= Float(r.next()) }
        }
        ramp = r
    }

    /// Clear every stage's state (filters, envelopes, limiter + dry delay lines).
    private func hardResetStages() {
        targetPEQ.snapToTargets()
        finePEQ.snapToTargets()
        bassPEQ.snapToTargets()
        punch.reset()
        limiter.reset()          // keeps its coefficients; clears delay line + envelope
        dryLine.update(repeating: 0, count: channelCount * dryStride)
    }
}
