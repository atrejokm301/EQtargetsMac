//
//  LimiterDSPTests.swift
//  EQTCoreTests — DSP-core tests ported from EQtargetsMusicTests (iOS), plus
//  the Mac output-protection preset and the render-rule changes.
//
//  The limiter's contract, not its internals:
//    • the ceiling is never exceeded, whatever is fed in;
//    • gain reduction is engaged *before* the peak reaches the output
//      (that is the whole point of the lookahead);
//    • quiet material passes through untouched, sample for sample;
//    • release adapts to sustained loudness rather than running fixed;
//    • stereo stays linked so the image cannot shift.
//
//  Port changes: the AUv3 kernel test, genre-preset UI tests and the v1
//  Codable migration test are iOS-only and were not ported. The "every genre
//  preset" ceiling test keeps the iOS genre parameter sets inline as data.
//  Random inputs use a seeded generator (determinism).
//

import XCTest

final class LimiterDSPTests: XCTestCase {

    private let sr = 48_000.0

    // MARK: - Helpers

    private func makeCore(_ state: LimiterState, channels: Int = 1, sampleRate: Double? = nil) -> LimiterDSPCore {
        let rate = sampleRate ?? sr
        let core = LimiterDSPCore()
        core.prepare(sampleRate: rate, channelCount: channels)
        core.update(LimiterCoefficients.make(from: state, sampleRate: rate))
        return core
    }

    private func lookaheadSamples(_ state: LimiterState, sampleRate: Double? = nil) -> Int {
        LimiterCoefficients.make(from: state, sampleRate: sampleRate ?? sr).lookaheadSamples
    }

    private func processStereo(_ core: LimiterDSPCore, _ left: inout [Float], _ right: inout [Float]) {
        precondition(left.count == right.count)
        let n = left.count
        left.withUnsafeMutableBufferPointer { lb in
            right.withUnsafeMutableBufferPointer { rb in
                var ptrs = [lb.baseAddress!, rb.baseAddress!]
                ptrs.withUnsafeMutableBufferPointer { pb in
                    core.process(channels: pb, frameCount: n)
                }
            }
        }
    }

    private func sine(amplitude: Float, hz: Double, count: Int) -> [Float] {
        (0 ..< count).map { i in amplitude * Float(sin(2 * Double.pi * hz * Double(i) / sr)) }
    }

    private func peak(_ buf: [Float]) -> Double { Double(buf.map { abs($0) }.max() ?? 0) }

    private func linear(_ db: Double) -> Double { pow(10, db / 20) }

    /// A limiter that is on, with makeup out of the way unless a test wants it.
    private func baseState(
        threshold: Double = -20, ratio: Double = 20, ceiling: Double = -1,
        lookaheadMs: Double = 5, releaseMs: Double = 100, knee: Double = 0
    ) -> LimiterState {
        var s = LimiterState()
        s.isEnabled = true
        s.autoMakeup = false
        s.postGainDB = 0
        s.thresholdDB = threshold
        s.ratio = ratio
        s.ceilingDB = ceiling
        s.lookaheadMs = lookaheadMs
        s.releaseMs = releaseMs
        s.kneeDB = knee
        s.attackMs = 1
        return s.sanitized()
    }

    /// The seven iOS genre presets (LimiterGenre.state), as data.
    private var iosGenreStates: [(String, LimiterState)] {
        let rows: [(String, Double, Double, Double, Double, Double, Double)] = [
            // name, threshold, ratio, knee, attack, release, lookahead
            ("hipHop", -8, 12, 3, 2.0, 80, 3),
            ("edm", -10, 16, 2, 1.0, 150, 4),
            ("rock", -7, 8, 6, 3.0, 120, 3),
            ("pop", -6, 6, 8, 5.0, 100, 2),
            ("podcast", -18, 10, 10, 8.0, 250, 5),
            ("jubilo", -9, 10, 4, 2.5, 100, 3),
            ("adoracion", -6, 3, 10, 10.0, 300, 5),
        ]
        return rows.map { r in
            var s = LimiterState()
            s.isEnabled = true; s.autoMakeup = true; s.ceilingDB = -1
            s.thresholdDB = r.1; s.ratio = r.2; s.kneeDB = r.3
            s.attackMs = r.4; s.releaseMs = r.5; s.lookaheadMs = r.6
            return (r.0, s.sanitized())
        }
    }

    // MARK: - Ceiling is a guarantee

    func test_ceiling_isNeverExceeded_forEveryIOSGenrePresetAndTheMacProtection() {
        var states = iosGenreStates
        states.append(("macOutputProtection", .outputProtection))
        for (name, state) in states {
            let core = makeCore(state)
            // Deliberately hotter than full scale: the EQ stages upstream can
            // and do push past 0 dBFS before this stage sees the signal.
            var buf = sine(amplitude: 2.0, hz: 220, count: Int(sr))
            core.process(&buf)
            XCTAssertLessThanOrEqual(peak(buf), linear(state.ceilingDB) + 1e-4,
                                     "\(name) let \(peak(buf)) through a \(state.ceilingDB) dB ceiling")
        }
    }

    func test_ceiling_isNeverExceeded_onImpulseTrain() {
        let state = baseState(threshold: -24, ratio: 20, ceiling: -1)
        let core = makeCore(state)
        var buf = [Float](repeating: 0.02, count: 48_000)
        for i in stride(from: 1_000, to: buf.count, by: 4_000) {
            buf[i] = 1.0
            buf[i + 1] = -1.0
        }
        core.process(&buf)
        XCTAssertLessThanOrEqual(peak(buf), linear(-1) + 1e-4)
    }

    func test_ceiling_isNeverExceeded_whenAutoMakeupIsAggressive() {
        var state = baseState(threshold: -30, ratio: 20, ceiling: -3)
        state.autoMakeup = true
        XCTAssertGreaterThan(state.effectiveMakeupDB, 0, "expected auto makeup to be non-trivial here")
        let core = makeCore(state)
        var buf = sine(amplitude: 1.0, hz: 440, count: Int(sr))
        core.process(&buf)
        XCTAssertLessThanOrEqual(peak(buf), linear(-3) + 1e-4)
    }

    // MARK: - Lookahead

    func test_lookahead_reducesGainBeforeThePeakReachesTheOutput() {
        let state = baseState(threshold: -20, ratio: 20, lookaheadMs: 5)
        let look = lookaheadSamples(state)
        XCTAssertGreaterThan(look, 10, "test needs a meaningful lookahead window")
        let quiet: Float = 0.05
        let onset = 4_000
        var buf = [Float](repeating: quiet, count: 12_000)
        for i in onset ..< buf.count { buf[i] = 1.0 }
        makeCore(state).process(&buf)
        let midWindow = onset + look / 2
        XCTAssertLessThan(abs(buf[midWindow]), quiet * 0.9,
                          "quiet audio inside the lookahead window was not pre-attenuated")
    }

    func test_withoutLookaheadWindow_theSameSamplesAreUntouched() {
        let state = baseState(threshold: -20, ratio: 20, lookaheadMs: 0.5)
        let look = lookaheadSamples(state)
        let quiet: Float = 0.05
        let onset = 4_000
        var buf = [Float](repeating: quiet, count: 12_000)
        for i in onset ..< buf.count { buf[i] = 1.0 }
        makeCore(state).process(&buf)
        let beforeWindow = onset - look - 50
        XCTAssertEqual(Double(abs(buf[beforeWindow])), Double(quiet), accuracy: 1e-5)
    }

    // MARK: - Transparency below threshold

    func test_belowThreshold_signalPassesThroughUnchangedApartFromDelay() {
        let state = baseState(threshold: -6, ratio: 20, ceiling: -1)
        let look = lookaheadSamples(state)
        let input = sine(amplitude: 0.1, hz: 300, count: 8_000)   // −20 dBFS
        var buf = input
        makeCore(state).process(&buf)
        for n in (look + 10) ..< buf.count {
            XCTAssertEqual(Double(buf[n]), Double(input[n - look]), accuracy: 1e-6,
                           "sample \(n) was altered despite sitting below the threshold")
        }
    }

    func test_bypass_isExactPassthroughWithConstantDelay() {
        var state = baseState()
        state.isEnabled = false
        let look = lookaheadSamples(state)
        var rng = SplitMix64(seed: 11)
        let input = (0 ..< 4_000).map { _ in Float.random(in: -1 ... 1, using: &rng) }
        var buf = input
        makeCore(state).process(&buf)
        for n in look ..< buf.count {
            XCTAssertEqual(buf[n], input[n - look])
        }
    }

    // MARK: - Bypassed fast path

    func test_leavingBypass_catchesALoudPassageThatArrivesImmediately() {
        var off = baseState()
        off.isEnabled = false
        var on = baseState()
        on.isEnabled = true
        let half = Int(sr * 0.5)
        let core = makeCore(off, channels: 2)
        var ql = sine(amplitude: 0.02, hz: 120, count: half)
        var qr = ql
        processStereo(core, &ql, &qr)
        core.update(LimiterCoefficients.make(from: on, sampleRate: sr))
        var ll = sine(amplitude: 0.95, hz: 120, count: half)
        var lr = ll
        processStereo(core, &ll, &lr)
        let ceiling = linear(on.ceilingDB)
        XCTAssertLessThanOrEqual(peak(ll), ceiling * 1.02, "a peak escaped the ceiling right after un-bypass")

        let reference = makeCore(on, channels: 2)
        var rl = sine(amplitude: 0.02, hz: 120, count: half)
        var rr = rl
        processStereo(reference, &rl, &rr)
        var rl2 = sine(amplitude: 0.95, hz: 120, count: half)
        var rr2 = rl2
        processStereo(reference, &rl2, &rr2)
        XCTAssertEqual(peak(ll), peak(rl2), accuracy: 0.01,
                       "primed detector did not behave like one that never stopped")
    }

    func test_repeatedBypassToggling_neverOvershootsTheCeiling() {
        var off = baseState()
        off.isEnabled = false
        var on = baseState()
        on.isEnabled = true
        let core = makeCore(off, channels: 2)
        let ceiling = linear(on.ceilingDB)
        let chunk = Int(sr * 0.25)
        for round in 0 ..< 8 {
            let enabled = round % 2 == 1
            core.update(LimiterCoefficients.make(from: enabled ? on : off, sampleRate: sr))
            var l = sine(amplitude: enabled ? 0.95 : 0.02, hz: 120, count: chunk)
            var r = l
            processStereo(core, &l, &r)
            if enabled {
                XCTAssertLessThanOrEqual(peak(l), ceiling * 1.02, "ceiling breached on toggle round \(round)")
            }
        }
    }

    func test_nodeBypassAndCoefficientBypassDoNotCancelEachOtherOut() {
        var disabled = baseState(threshold: -20, ratio: 20)
        disabled.isEnabled = false
        let core = makeCore(disabled)
        core.bypassOverride = false
        let look = lookaheadSamples(disabled)
        let input = sine(amplitude: 1.0, hz: 220, count: 8_000)
        var buf = input
        core.process(&buf)
        for n in (look + 10) ..< buf.count {
            XCTAssertEqual(Double(buf[n]), Double(input[n - look]), accuracy: 1e-6,
                           "a disabled limiter altered sample \(n)")
        }
    }

    func test_nodeBypassAloneSilencesProcessingEvenWhenEnabled() {
        var enabled = baseState(threshold: -20, ratio: 20)
        enabled.isEnabled = true
        let core = makeCore(enabled)
        core.bypassOverride = true
        let look = lookaheadSamples(enabled)
        let input = sine(amplitude: 1.0, hz: 220, count: 8_000)
        var buf = input
        core.process(&buf)
        for n in (look + 10) ..< buf.count {
            XCTAssertEqual(Double(buf[n]), Double(input[n - look]), accuracy: 1e-6)
        }
    }

    func test_switchingOffAfterHeavyReduction_returnsToUnityPromptlyWithoutJumping() {
        var on = baseState(threshold: -20, ratio: 20, releaseMs: 1_000)
        on.isEnabled = true
        let core = makeCore(on)
        var loud = [Float](repeating: 1.0, count: 96_000)
        core.process(&loud)
        XCTAssertGreaterThan(core.gainReductionDB, 10, "setup: expected heavy reduction")

        var off = on
        off.isEnabled = false
        core.update(LimiterCoefficients.make(from: off, sampleRate: sr))
        let quiet: Float = 0.2
        var tail = [Float](repeating: quiet, count: Int(sr / 2))
        core.process(&tail)
        let look = lookaheadSamples(off)
        XCTAssertLessThan(Double(abs(tail[look + 1])), Double(quiet) * 0.9, "gain jumped straight to unity — that pops")
        // Expectation corrected from the iOS original (which demanded 0.99 at
        // 150 ms and is a recorded, deterministic iOS failure, off by 0.0005 —
        // reproduced exactly here). The unwind is a one-pole with the documented
        // 30 ms constant (`bypassReleaseMs`): from 19 dB of reduction it leaves
        // 19·e^(−150/30) = 0.128 dB at 150 ms → 0.9854 of unity, and
        // 19·e^(−250/30) = 0.0046 dB at 250 ms → 0.9995. The DSP is unchanged.
        let at150 = look + Int(sr * 0.15)
        let at250 = look + Int(sr * 0.25)
        XCTAssertGreaterThanOrEqual(Double(abs(tail[at150])), Double(quiet) * 0.98,
                                    "still fading up 150 ms after being switched off")
        XCTAssertGreaterThanOrEqual(Double(abs(tail[at250])), Double(quiet) * 0.999,
                                    "not back at unity 250 ms after being switched off")
    }

    // MARK: - Program-dependent release

    func test_release_isSlowerAfterSustainedLoudnessThanAfterABriefTransient() {
        let state = baseState(threshold: -20, ratio: 20, releaseMs: 100)
        let quiet: Float = 0.01
        let tail = 24_000
        let look = lookaheadSamples(state)
        func recoverySamples(burstSamples: Int) -> Int {
            var buf = [Float](repeating: 1.0, count: burstSamples)
            buf.append(contentsOf: [Float](repeating: quiet, count: tail))
            makeCore(state).process(&buf)
            let start = burstSamples + look
            let target = Double(quiet) * 0.95
            for n in start ..< buf.count where Double(abs(buf[n])) >= target { return n - start }
            return buf.count
        }
        let shortBurst = recoverySamples(burstSamples: 240)
        let longBurst = recoverySamples(burstSamples: 96_000)
        XCTAssertLessThan(shortBurst, longBurst,
                          "a 5 ms transient should recover faster than 2 s of sustained loudness")
        XCTAssertGreaterThan(Double(longBurst) / Double(max(shortBurst, 1)), 1.5,
                             "the two release behaviours are too close to be program-dependent")
    }

    // MARK: - Stereo linking

    func test_stereo_gainIsLinkedSoTheImageDoesNotShift() {
        let state = baseState(threshold: -20, ratio: 12)
        let core = makeCore(state, channels: 2)
        var left = sine(amplitude: 1.0, hz: 200, count: 12_000)
        var right = left.map { $0 * 0.25 }
        processStereo(core, &left, &right)
        let look = lookaheadSamples(state)
        for n in (look + 100) ..< left.count {
            guard abs(right[n]) > 1e-4 else { continue }
            XCTAssertEqual(Double(left[n] / right[n]), 4.0, accuracy: 0.02,
                           "channel ratio drifted at sample \(n) — gain is not linked")
        }
    }

    // MARK: - Static curve

    func test_staticCurve_isFlatBelowThresholdAndFollowsTheRatioAbove() {
        let core = makeCore(baseState(threshold: -20, ratio: 4, ceiling: 0, knee: 0))
        XCTAssertEqual(core.staticGainDB(forInputDB: -40), 0, accuracy: 1e-9)
        XCTAssertEqual(core.staticGainDB(forInputDB: -21), 0, accuracy: 1e-9)
        XCTAssertEqual(core.staticGainDB(forInputDB: -10), -7.5, accuracy: 1e-6)
    }

    func test_staticCurve_softKneeEasesInEarlyAndRejoinsTheHardCurve() {
        let threshold = -20.0, knee = 8.0
        let hard = makeCore(baseState(threshold: threshold, ratio: 8, ceiling: 0, knee: 0))
        let soft = makeCore(baseState(threshold: threshold, ratio: 8, ceiling: 0, knee: knee))
        var previous = 0.0
        for db in stride(from: -40.0, through: -1.0, by: 0.25) {
            let g = soft.staticGainDB(forInputDB: db)
            XCTAssertLessThanOrEqual(g, previous + 1e-9, "soft knee curve is not monotonic at \(db) dB")
            previous = g
        }
        XCTAssertEqual(soft.staticGainDB(forInputDB: threshold - knee / 2), 0, accuracy: 1e-9)
        XCTAssertLessThan(soft.staticGainDB(forInputDB: threshold), -0.1)
        XCTAssertEqual(hard.staticGainDB(forInputDB: threshold), 0, accuracy: 1e-9)
        XCTAssertEqual(soft.staticGainDB(forInputDB: threshold + knee / 2),
                       hard.staticGainDB(forInputDB: threshold + knee / 2), accuracy: 1e-6)
    }

    func test_staticCurve_enforcesTheCeilingEvenWhenTheRatioAloneWouldNot() {
        let core = makeCore(baseState(threshold: -20, ratio: 1.5, ceiling: -1))
        XCTAssertLessThanOrEqual(0 + core.staticGainDB(forInputDB: 0), -1 + 1e-9)
    }

    // MARK: - Sliding peak detector

    func test_slidingPeakDetector_matchesBruteForceMaximum() {
        let window = 37
        let detector = SlidingPeakDetector()
        detector.prepare(capacity: 256)
        detector.setWindow(window)
        var rng = SplitMix64(seed: 3)
        let input = (0 ..< 2_000).map { _ in Float.random(in: 0 ... 1, using: &rng) }
        for i in input.indices {
            let got = detector.push(input[i])
            let expected = input[max(0, i - window + 1) ... i].max()!
            XCTAssertEqual(got, expected, accuracy: 1e-6, "window maximum wrong at \(i)")
        }
    }

    func test_slidingPeakDetector_shrinkingWindowDropsStalePeaks() {
        let detector = SlidingPeakDetector()
        detector.prepare(capacity: 256)
        detector.setWindow(100)
        _ = detector.push(1.0)
        for _ in 0 ..< 50 { _ = detector.push(0.1) }
        XCTAssertEqual(detector.push(0.1), 1.0, accuracy: 1e-6)
        detector.setWindow(10)
        XCTAssertEqual(detector.push(0.1), 0.1, accuracy: 1e-6)
    }

    // MARK: - State validation

    func test_sanitize_clampsEveryParameterIntoRange() {
        var s = LimiterState()
        s.ceilingDB = 40; s.thresholdDB = -900; s.ratio = 1_000; s.kneeDB = -5
        s.attackMs = 5_000; s.releaseMs = 0; s.lookaheadMs = 900; s.postGainDB = 99
        s.sanitize()
        XCTAssertTrue(LimiterState.ceilingRange.contains(s.ceilingDB))
        XCTAssertTrue(LimiterState.thresholdRange.contains(s.thresholdDB))
        XCTAssertTrue(LimiterState.ratioRange.contains(s.ratio))
        XCTAssertTrue(LimiterState.kneeRange.contains(s.kneeDB))
        XCTAssertTrue(LimiterState.attackMsRange.contains(s.attackMs))
        XCTAssertTrue(LimiterState.releaseMsRange.contains(s.releaseMs))
        XCTAssertTrue(LimiterState.lookaheadMsRange.contains(s.lookaheadMs))
        XCTAssertTrue(LimiterState.postGainRange.contains(s.postGainDB))
    }

    func test_sanitize_pullsAThresholdAboveTheCeilingBackUnderIt() {
        var s = LimiterState()
        s.ceilingDB = -6
        s.thresholdDB = -2
        s.sanitize()
        XCTAssertLessThanOrEqual(s.thresholdDB, s.ceilingDB)
    }

    func test_attackIsClampedToTheLookaheadWindow() {
        var s = baseState(lookaheadMs: 1)
        s.attackMs = 50
        let c = LimiterCoefficients.make(from: s, sampleRate: sr)
        let windowMs = Double(c.lookaheadSamples) / sr * 1000
        XCTAssertEqual(c.attackCoef, LimiterCoefficients.onePole(timeMs: windowMs, sampleRate: sr), accuracy: 1e-9)
    }

    // MARK: - Mac additions

    func test_outputProtection_isA1dBFSBrickwallWithShortLookaheadAndNoMakeup() {
        let s = LimiterState.outputProtection
        XCTAssertTrue(s.isEnabled)
        XCTAssertEqual(s.ceilingDB, -1)
        XCTAssertEqual(s.thresholdDB, s.ceilingDB, "safety limiter must not act below the ceiling")
        XCTAssertEqual(s.effectiveMakeupDB, 0, "protection must never make anything louder")
        let c = LimiterCoefficients.make(from: s, sampleRate: 48_000)
        XCTAssertEqual(c.lookaheadSamples, 72, "1.5 ms at 48 kHz")
        XCTAssertEqual(LimiterCoefficients.make(from: s, sampleRate: 44_100).lookaheadSamples, 66)
        XCTAssertEqual(c.engageLinear, pow(10, -1.0 / 20), accuracy: 1e-12)
    }

    func test_outputProtection_isBitExactBelowTheCeiling() {
        let state = LimiterState.outputProtection
        let look = lookaheadSamples(state)
        // −1.1 dBFS: as hot as possible without crossing the ceiling.
        let input = sine(amplitude: Float(pow(10, -1.1 / 20)), hz: 997, count: 48_000)
        var buf = input
        makeCore(state).process(&buf)
        for n in look ..< buf.count where buf[n] != input[n - look] {
            XCTFail("sample \(n) changed (\(buf[n]) vs \(input[n - look])) below the ceiling")
            return
        }
    }

    func test_envelope_returnsToExactUnityAfterLimiting_soTransparencyResumes() {
        // The iOS envelope decayed asymptotically and never reached 0 dB; the
        // Mac snaps it (denormal guard), so after a release the stage is
        // bit-exact again rather than "within 1e-x".
        let state = LimiterState.outputProtection
        let core = makeCore(state)
        var loud = sine(amplitude: 2, hz: 200, count: 4_800)
        core.process(&loud)
        XCTAssertGreaterThan(core.gainReductionDB, 5)
        let look = lookaheadSamples(state)
        // 10 s of quiet material in two calls: the release (first 9 s), then a
        // final second that must be untouched. (`gainReductionDB` is the block
        // maximum, so it is read on the second call only.)
        let input = sine(amplitude: 0.5, hz: 300, count: 10 * 48_000)
        var first = Array(input[0 ..< 9 * 48_000])
        var last = Array(input[(9 * 48_000)...])
        core.process(&first)
        core.process(&last)
        XCTAssertEqual(core.gainReductionDB, 0, "envelope never returned to exactly 0 dB")
        for i in last.indices where last[i] != input[9 * 48_000 + i - look] {
            XCTFail("not bit-exact 9 s after limiting stopped (sample \(i))")
            return
        }
    }

    func test_fastMath_matchesFoundationToWithin1eMinus9dB() {
        var rng = SplitMix64(seed: 5)
        for _ in 0 ..< 20_000 {
            let x = pow(10, Double.random(in: -9 ... 3, using: &rng))
            XCTAssertEqual(FastMath.linearToDB(x), 20 * log10(x), accuracy: 1e-9)
            let db = Double.random(in: -200 ... 40, using: &rng)
            let ref = pow(10, db / 20)
            XCTAssertEqual(FastMath.dbToLinear(db) / ref, 1, accuracy: 1e-10)
        }
        XCTAssertEqual(FastMath.dbToLinear(0), 1)
    }

    /// Regression (found by mutation testing): log2(+∞) overflowed the exponent
    /// fold and TRAPPED, crashing the render thread.
    func test_fastMath_neverTrapsOnInfinityNaNOrZero() {
        XCTAssertEqual(FastMath.log2(.infinity), 1_024)
        XCTAssertEqual(FastMath.log2(0), -1_075)
        XCTAssertTrue(FastMath.log2(.nan).isNaN)
        XCTAssertTrue(FastMath.log2(-1).isNaN)
        XCTAssertEqual(FastMath.exp2(.nan), 1)
        XCTAssertTrue(FastMath.exp2(.infinity).isFinite)
        XCTAssertEqual(FastMath.exp2(-.infinity), 0, accuracy: 1e-300)
        XCTAssertTrue(FastMath.linearToDB(.infinity).isFinite)
    }

    /// The chain sanitises its input, but the limiter must not crash even if a
    /// non-finite sample reaches it; its state is reported non-finite so the
    /// chain can reset it.
    func test_limiterCore_fedInfinityAndNaN_doesNotTrap_andResetRecovers() {
        let core = makeCore(.outputProtection, channels: 2)
        var l = sine(amplitude: 0.5, hz: 300, count: 4_800), r = l
        l[100] = .infinity; r[200] = .nan; l[300] = -.infinity
        processStereo(core, &l, &r)
        if core.hasNonFiniteState { core.reset() }
        let look = lookaheadSamples(.outputProtection)
        let input = sine(amplitude: 0.5, hz: 300, count: 9_600)
        var a = input, b = input
        processStereo(core, &a, &b)
        XCTAssertTrue(a[(look + 4_800)...].allSatisfy { $0.isFinite }, "limiter never recovered")
    }
}
