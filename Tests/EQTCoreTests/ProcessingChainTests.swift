//
//  ProcessingChainTests.swift
//  EQTCoreTests
//
//  ProcessingChain end to end:
//    • layer order — Target and Fine-Tune sum in dB, the Bass static shape adds
//      on top, and the Bass DYNAMIC stage sees the signal after both layers;
//    • masterBypass is bit-exact (after its 10 ms crossfade) and click-free;
//    • output protection holds a +12 dB burst at −1 dBFS with a constant,
//      reported latency;
//    • meters: punch boost on a kick, limiter GR on overs, peaks reset on read;
//    • requestReset clears state without clicking;
//    • switching Bass Style / Punch / Rumble and muting never click;
//    • garbage in (NaN / Inf samples, NaN parameters, parameters hammered from
//      another thread) never produces garbage out.
//
//  Click metric: peak of an 8th-order 8 kHz high-pass of the output relative to
//  the test tone (see Fixtures.clickLevelDB). Each click test carries a negative
//  control with the relevant smoothing set to 0 ms, which must fail the bound.
//

import XCTest
import Synchronization

final class ProcessingChainTests: XCTestCase {

    private let sr = 48_000.0

    private func kickPattern(seconds: Double, scale: Double = 1) -> [Float] {
        let n = Int(sr * seconds)
        return (0 ..< n).map { i in
            let t = Double(i) / sr
            var v = 0.05 * sin(2 * .pi * 55 * t)
            let inBeat = t.truncatingRemainder(dividingBy: 0.5)
            if inBeat < 0.12 { v += 0.6 * exp(-inBeat * 30) * sin(2 * .pi * 60 * inBeat) }
            return Float(v * scale)
        }
    }

    private func punchParams(attack: Double = 1, strength: Double = 1) -> ChainParameters {
        var p = ChainParameters()
        p.bass.selectStyle(.transientPunch)
        p.bass.strength = strength
        p.bass.punchAttack = attack
        return p
    }

    // MARK: - Layer order

    func test_staticBassShape_addsToTargetAndFineTune_inDB() throws {
        var p = ChainParameters()
        p.outputProtection = false
        p.dual.target = try AutoEQParser.parse(text: Fixtures.airPodsMaxPreset)
        p.dual.fineTune = Fixtures.layer(preamp: -2, [EQBand(frequency: 3_000, gain: 4, q: 1.5)])
        p.bass.selectStyle(.naturalClean)          // static only: no dynamics to disturb a steady-state measurement
        p.bass.strength = 0.8
        p.bass.postGain = -1.5
        let unit = BassProcessorDSP.unitParams(from: p.bass, sampleRate: sr)
        XCTAssertFalse(unit.unitBypass)

        let chain = Fixtures.chain(p)
        let freqs = Fixtures.responseFrequencies
        let measured = Fixtures.measuredResponseDB(chain: chain, frequencies: freqs, settle: 1.0).left
        for (i, f) in freqs.enumerated() {
            var bass = unit.globalGainDB
            for b in unit.bands where !b.bypass {
                bass += Fixtures.RefBiquad(type: b.type, frequency: b.frequency, gainDB: b.gainDB, q: b.q)
                    .magnitudeDB(at: f)
            }
            let expected = Fixtures.graphDB(p.dual.target, at: f) + Fixtures.graphDB(p.dual.fineTune, at: f) + bass
            XCTAssertEqual(measured[i], expected, accuracy: 0.05, "\(Int(f)) Hz")
        }
    }

    /// The punch detector is level dependent (activity floor ≈ −60 dBFS on the
    /// low band). A kick that punches with flat layers must stop punching when
    /// EITHER layer's preamp pulls it under the floor — which can only happen
    /// if the dynamic stage runs after both layers.
    func test_bassDynamicStage_seesTheSignalAfterBothLayers() {
        let kick = kickPattern(seconds: 2, scale: 0.01)
        func boost(_ p: ChainParameters) -> Double {
            let chain = Fixtures.chain(p)
            _ = chain.meters()
            _ = chain.run([kick, kick])
            return chain.meters().punchBoostDB
        }
        let flat = boost(punchParams())
        var quietTarget = punchParams()
        quietTarget.dual.target.preamp = -20
        var quietFine = punchParams()
        quietFine.dual.fineTune.preamp = -20
        let afterTarget = boost(quietTarget), afterFine = boost(quietFine)
        print("Punch boost on a −44 dBFS kick: flat layers \(String(format: "%.2f", flat)) dB, " +
              "Target −20 dB \(String(format: "%.2f", afterTarget)) dB, Fine-Tune −20 dB \(String(format: "%.2f", afterFine)) dB")
        XCTAssertGreaterThan(flat, 1.0, "setup: the kick should punch with flat layers")
        XCTAssertEqual(afterTarget, 0, accuracy: 0.01, "punch saw the signal before the Target layer")
        XCTAssertEqual(afterFine, 0, accuracy: 0.01, "punch saw the signal before the Fine-Tune layer")
    }

    // MARK: - Master bypass

    func test_masterBypass_isBitExactAfterTheCrossfade_evenForOversAndAnActiveChain() throws {
        var p = punchParams()
        p.dual.target = try AutoEQParser.parse(text: Fixtures.airPodsMaxPreset)
        p.dual.fineTune = Fixtures.layer(preamp: 6, [EQBand(frequency: 100, gain: 12, q: 1)])
        let chain = Fixtures.chain(p)
        var rng = SplitMix64(seed: 8)
        let n = Int(sr)
        let l = (0 ..< n).map { _ in Float.random(in: -1.2 ... 1.2, using: &rng) }   // overs on purpose
        let r = (0 ..< n).map { _ in Float.random(in: -1.2 ... 1.2, using: &rng) }
        var q = p
        q.masterBypass = true
        let out = chain.run([l, r], block: 256) { b in if b == 4 { chain.setParameters(q) } }
        let d = chain.latencyFrames
        let settled = 4 * 256 + Int(sr * 0.012) + d
        var mismatches = 0
        for i in settled ..< n where out[0][i] != l[i - d] || out[1][i] != r[i - d] { mismatches += 1 }
        XCTAssertEqual(mismatches, 0, "bypassed output differs from the delayed input")
        // And it really was processing before the toggle.
        XCTAssertNotEqual(out[0][900], l[900 - d])
    }

    private func toggleClickLevel(fadeMs: Double) -> Double {
        var t = ChainTuning()
        t.bypassCrossfadeMs = fadeMs
        var p = ChainParameters()
        p.outputProtection = false
        p.dual.fineTune = Fixtures.layer([EQBand(frequency: 500, gain: 12, q: 1)])
        let chain = Fixtures.chain(p, tuning: t)
        let x = Fixtures.sine(0.2, 500, Int(sr))
        var bypassed = false
        let out = chain.run([x, x], block: 480) { b in
            if b > 2, b % 10 == 0 { bypassed.toggle(); var q = p; q.masterBypass = bypassed; chain.setParameters(q) }
        }[0]
        return Fixtures.clickLevelDB(out, reference: 0.2)
    }

    func test_masterBypassToggling_isClickFree() {
        let faded = toggleClickLevel(fadeMs: 10), instant = toggleClickLevel(fadeMs: 0)
        print("Bypass toggle click level: crossfade \(String(format: "%.1f", faded)) dB, instant \(String(format: "%.1f", instant)) dB")
        XCTAssertLessThan(faded, -90)
        XCTAssertGreaterThan(instant, -70, "negative control: an instant switch must register as a click")
    }

    // MARK: - Output protection + latency

    func test_outputProtection_holdsAPlus12dBBurstAtTheCeiling_andMetersIt() {
        let chain = Fixtures.chain(ChainParameters())
        _ = chain.meters()
        var x = Fixtures.sine(0.1, 1_000, Int(sr))                       // −20 dBFS bed
        let burst = Fixtures.sine(4.0, 1_000, Int(sr * 0.2))              // +12 dBFS
        for i in burst.indices { x[24_000 + i] = burst[i] }
        let out = chain.run([x, x])
        let m = chain.meters()
        let ceiling = Float(pow(10, -1.0 / 20))
        let peak = max(Fixtures.peak(out[0]), Fixtures.peak(out[1]))
        print("Protection: +12 dBFS burst → output peak \(String(format: "%.4f", Fixtures.db(peak))) dBFS, GR meter \(String(format: "%.2f", m.limiterReductionDB)) dB, overs \(m.overCount)")
        XCTAssertLessThanOrEqual(peak, Double(ceiling) + 1e-6)
        XCTAssertGreaterThan(m.limiterReductionDB, 10)
        XCTAssertGreaterThanOrEqual(m.overCount, 1)
        XCTAssertEqual(m.inputPeakDB, Fixtures.db(4.0), accuracy: 0.01)
    }

    func test_outputProtectionOff_letsTheBurstThrough_butStillCountsTheOver() {
        var p = ChainParameters()
        p.outputProtection = false
        let chain = Fixtures.chain(p)
        let x = Fixtures.sine(4.0, 1_000, 9_600)
        let out = chain.run([x, x])
        let m = chain.meters()
        XCTAssertGreaterThan(Fixtures.peak(out[0]), 3.9)
        XCTAssertEqual(m.limiterReductionDB, 0)
        XCTAssertGreaterThanOrEqual(m.overCount, 1)
    }

    func test_latency_isTheLookahead_andTheImpulseLandsExactlyThere() {
        for (rate, expected) in [(48_000.0, 72), (44_100.0, 66), (96_000.0, 144)] {
            let chain = Fixtures.chain(ChainParameters(), sampleRate: rate)
            XCTAssertEqual(chain.latencyFrames, expected, "\(rate)")
            var x = [Float](repeating: 0, count: 4_096)
            x[1_000] = 0.5
            let out = chain.run([x, x])[0]
            let nonZero = out.indices.filter { out[$0] != 0 }
            XCTAssertEqual(nonZero, [1_000 + expected], "\(rate): impulse moved or smeared")
            XCTAssertEqual(out[1_000 + expected], 0.5)
        }
    }

    func test_latency_isIdenticalWithProtectionOnOffAndBypassed() {
        func impulsePosition(_ p: ChainParameters) -> Int? {
            let chain = Fixtures.chain(p)
            var x = [Float](repeating: 0, count: 2_048)
            x[500] = 0.5
            let out = chain.run([x, x])[0]
            return out.firstIndex { $0 != 0 }
        }
        var off = ChainParameters(); off.outputProtection = false
        var byp = ChainParameters(); byp.masterBypass = true
        let a = impulsePosition(ChainParameters()), b = impulsePosition(off), c = impulsePosition(byp)
        XCTAssertEqual(a, 572); XCTAssertEqual(b, 572); XCTAssertEqual(c, 572)
    }

    // MARK: - Meters

    func test_meters_punchBoostAppearsOnAKick_withinTheKernelCeiling() {
        let chain = Fixtures.chain(punchParams())
        let kick = kickPattern(seconds: 3)
        var maxBoost = 0.0
        _ = chain.run([kick, kick], block: 512) { _ in maxBoost = max(maxBoost, chain.meters().punchBoostDB) }
        print("Punch meter on a kick pattern: max \(String(format: "%.2f", maxBoost)) dB")
        XCTAssertGreaterThan(maxBoost, 1.0)
        XCTAssertLessThanOrEqual(maxBoost, TransientPunchTuning.maxAttackBoostDB + 1e-6)
    }

    func test_meters_rumbleSustainLiftAppearsOnADecayingNote_andIsZeroWhenStyleIsStatic() {
        var p = ChainParameters()
        p.bass.selectStyle(.sustainRumble)
        p.bass.strength = 1
        p.bass.rumbleSustain = 1
        let note: [Float] = (0 ..< Int(sr * 2)).map { i in
            let t = Double(i) / sr
            return Float(0.5 * exp(-t * 3) * sin(2 * .pi * 55 * t))
        }
        let chain = Fixtures.chain(p)
        _ = chain.run([note, note])
        XCTAssertGreaterThan(chain.meters().punchBoostDB, 1.0, "Rumble lift did not reach the meter")

        var clean = ChainParameters()
        clean.bass.selectStyle(.naturalClean)
        let c2 = Fixtures.chain(clean)
        _ = c2.run([note, note])
        let m = c2.meters()
        XCTAssertEqual(m.punchBoostDB, 0)
        XCTAssertEqual(m.punchTrimDB, 0)
    }

    func test_meters_peaksResetOnRead() {
        let chain = Fixtures.chain(ChainParameters())
        _ = chain.run([Fixtures.sine(0.5, 440, 4_800), Fixtures.sine(0.25, 440, 4_800)])
        let first = chain.meters()
        XCTAssertEqual(first.inputPeakDB, Fixtures.db(0.5), accuracy: 0.01)
        XCTAssertEqual(first.outputPeakDB, Fixtures.db(0.5), accuracy: 0.01)
        let second = chain.meters()
        XCTAssertEqual(second.inputPeakDB, -120)
        XCTAssertEqual(second.outputPeakDB, -120)
        XCTAssertEqual(second.overCount, first.overCount, "overCount is a lifetime counter")
    }

    // MARK: - requestReset

    func test_requestReset_clearsRingingFilterState() {
        var p = ChainParameters()
        p.outputProtection = false
        p.dual.target = Fixtures.layer([EQBand(frequency: 20, gain: 20, q: 10)])
        let chain = Fixtures.chain(p)
        var x = [Float](repeating: 0, count: Int(sr * 0.3))
        x[0] = 1
        let rung = chain.run([x, x])[0]
        XCTAssertGreaterThan(Fixtures.peak(rung[(rung.count - 2_000)...]), 1e-4, "setup: the 20 Hz Q10 band should still ring")

        chain.requestReset()
        let after = chain.run([[Float](repeating: 0, count: 4_800), [Float](repeating: 0, count: 4_800)])[0]
        // Duck (3 ms = 144 frames) + the lookahead still holding pre-reset audio.
        XCTAssertTrue(after[(144 + chain.latencyFrames + 1)...].allSatisfy { $0 == 0 }, "state survived requestReset")
    }

    private func resetClickLevel(duckMs: Double) -> Double {
        var t = ChainTuning(); t.resetDuckMs = duckMs
        var p = ChainParameters()
        p.outputProtection = false
        p.dual.fineTune = Fixtures.layer([EQBand(frequency: 500, gain: 12, q: 1)])
        let chain = Fixtures.chain(p, tuning: t)
        let x = Fixtures.sine(0.2, 500, Int(sr * 0.5))
        let out = chain.run([x, x], block: 512) { b in if b == 20 { chain.requestReset() } }[0]
        return Fixtures.clickLevelDB(out, reference: 0.2)
    }

    func test_requestReset_underARunningSignal_doesNotClick() {
        let ducked = resetClickLevel(duckMs: 3), hard = resetClickLevel(duckMs: 0)
        print("requestReset click level: duck \(String(format: "%.1f", ducked)) dB, hard reset \(String(format: "%.1f", hard)) dB")
        XCTAssertLessThan(ducked, -60)
        XCTAssertGreaterThan(hard, -40, "negative control: clearing state under signal must click")
    }

    // MARK: - Bass Style switching

    /// Bass-heavy material while the user flips Off → Punch → Rumble → Clean →
    /// Off and drags the cutoff with Punch engaged.
    private func styleSwitchClickLevel(_ t: ChainTuning) -> Double {
        let n = Int(sr * 2.4)
        let x: [Float] = (0 ..< n).map { i in
            let s = Double(i) / sr
            return Float(0.3 * sin(2 * .pi * 60 * s) + 0.3 * sin(2 * .pi * 95 * s + 1) + 0.1 * sin(2 * .pi * 500 * s))
        }
        var p = ChainParameters()
        p.outputProtection = false
        let chain = Fixtures.chain(p, tuning: t)
        let out = chain.run([x, x], block: 512) { b in
            var q = p
            switch b {
            case 10 ..< 40: q.bass.selectStyle(.transientPunch); q.bass.punchSustain = 0.6
                q.bass.cutoff = 85 + Double(max(0, b - 20)) * 4          // cutoff drag, ~90 Hz updates
            case 40 ..< 70: q.bass.selectStyle(.sustainRumble); q.bass.rumbleSoften = 0.5
            case 70 ..< 90: q.bass.selectStyle(.naturalClean)
            default: q.bass.selectStyle(.none)
            }
            q.bass.strength = 1
            chain.setParameters(q)
        }[0]
        return Fixtures.clickLevelDB(out, reference: 0.3)
    }

    func test_bassStyleSwitchingAndCutoffDrag_areClickFree() {
        let smooth = styleSwitchClickLevel(ChainTuning())
        var none = ChainTuning(); none.parameterGlideMs = 0; none.stageCrossfadeMs = 0
        let instant = styleSwitchClickLevel(none)
        print("Bass Style switching click level: smoothed \(String(format: "%.1f", smooth)) dB, instant \(String(format: "%.1f", instant)) dB")
        XCTAssertLessThan(smooth, -80)
        XCTAssertGreaterThan(instant, -70, "negative control: unsmoothed switching must register as clicks")
    }

    /// Regression: re-adopting an unchanged snapshot used to restart the
    /// crossover glide, so with a UI re-sending parameters every block it never
    /// landed (and a later switch-off then landed it on all-zero coefficients).
    func test_punchCrossover_landsExactlyOnItsGoal_whenTheSameParametersArriveEveryBlock() {
        let p = punchParams()
        let chain = Fixtures.chain(p)
        var q = p
        q.bass.cutoff = 150
        let x = Fixtures.sine(0.3, 70, Int(sr))
        _ = chain.run([x, x], block: 512) { _ in chain.setParameters(q) }
        XCTAssertEqual(chain.punchCoefficientsInForce, TransientPunchCoefficients.make(from: q.bass, sampleRate: sr),
                       "crossover glide never landed")
    }

    // MARK: - Output gain / mute

    func test_outputGain_rampsMuteSmoothly_andClampsBoostsToUnity() {
        var p = ChainParameters()
        p.outputGainDB = 6                     // clamped: a boost would land after the limiter
        let chain = Fixtures.chain(p)
        var rng = SplitMix64(seed: 2)
        let l = (0 ..< 9_600).map { _ in Float.random(in: -0.8 ... 0.8, using: &rng) }
        let out = chain.run([l, l])[0]
        let d = chain.latencyFrames
        XCTAssertTrue((d ..< l.count).allSatisfy { out[$0] == l[$0 - d] }, "+6 dB was not clamped to unity")

        p.outputGainDB = -6
        let c2 = Fixtures.chain(p)
        let y = c2.run([Fixtures.sine(0.5, 300, 9_600), Fixtures.sine(0.5, 300, 9_600)])[0]
        XCTAssertEqual(Fixtures.peak(y[2_000...]), 0.5 * pow(10, -6.0 / 20), accuracy: 1e-4)

        // Mute toggling on a tone: click-free and exactly silent once ramped.
        var q = ChainParameters()
        let c3 = Fixtures.chain(q)
        let x = Fixtures.sine(0.5, 500, Int(sr))
        let muted = c3.run([x, x], block: 480) { b in
            if b == 20 { q.outputMuted = true; c3.setParameters(q) }
            if b == 60 { q.outputMuted = false; c3.setParameters(q) }
        }[0]
        XCTAssertTrue(muted[(25 * 480) ..< (60 * 480)].allSatisfy { $0 == 0 }, "mute is not silent")
        XCTAssertLessThan(Fixtures.clickLevelDB(muted, reference: 0.5), -90, "mute clicks")
    }

    // MARK: - Garbage in

    func test_nonFiniteInputSamples_neverReachTheOutput_andTheChainRecovers() throws {
        var p = punchParams()
        p.dual.target = try AutoEQParser.parse(text: Fixtures.airPodsMaxPreset)
        let chain = Fixtures.chain(p)
        var x = Fixtures.sine(0.3, 80, 24_000)
        x[1_000] = .nan; x[5_000] = .infinity; x[5_001] = -.infinity; x[9_000] = .signalingNaN
        let out = chain.run([x, x])
        XCTAssertTrue(out[0].allSatisfy { $0.isFinite } && out[1].allSatisfy { $0.isFinite })
        let tail = chain.run([Fixtures.sine(0.3, 80, 24_000), Fixtures.sine(0.3, 80, 24_000)])[0]
        XCTAssertGreaterThan(Fixtures.rms(tail[12_000...]), 0.05, "chain did not recover after bad input")
    }

    func test_nonFiniteParameters_areSanitizedOnTheMainThread() {
        var p = ChainParameters()
        p.dual.target = Fixtures.layer(preamp: .nan, [EQBand(frequency: 100, gain: 3, q: 1)])
        p.dual.target.bands[0].gain = .infinity
        p.dual.target.bands[1].isEnabled = true
        p.dual.target.bands[1].frequency = .nan
        p.dual.target.bands[1].gain = 6
        p.dual.target.bands[2].isEnabled = true
        p.dual.target.bands[2].q = -.infinity
        p.dual.target.bands[2].gain = -6
        p.bass.selectStyle(.sustainRumble)
        p.bass.strength = .nan
        p.bass.cutoff = .infinity
        p.outputGainDB = .nan
        let chain = Fixtures.chain(p)
        let out = chain.run([Fixtures.sine(0.3, 70, 48_000), Fixtures.sine(0.3, 70, 48_000)])
        XCTAssertTrue(out[0].allSatisfy { $0.isFinite })
        XCTAssertGreaterThan(Fixtures.rms(out[0][24_000...]), 0.01)
    }

    /// The main thread can publish while the render thread processes; this
    /// hammers that (plus garbage values) from a second thread.
    func test_parameterChangesFromAnotherThread_whileProcessing_neverCrashOrProduceNaN() {
        let chain = Fixtures.chain(ChainParameters())
        let flags = StressFlags()
        let done = DispatchSemaphore(value: 0)
        // Same QoS as the waiting test thread (no priority inversion on `done.wait()`).
        let writer = Thread {
            var rng = SplitMix64(seed: 77)
            let styles = BassStyle.allCases
            while !flags.stop.load(ordering: .acquiring) {
                var p = ChainParameters()
                for i in 0 ..< 10 {
                    p.dual.target.bands[i].gain = Double.random(in: -20 ... 20, using: &rng)
                    p.dual.target.bands[i].q = Double.random(in: 0.1 ... 10, using: &rng)
                    p.dual.fineTune.bands[i].frequency = Double.random(in: 20 ... 20_000, using: &rng)
                    p.dual.fineTune.bands[i].gain = Double.random(in: -20 ... 20, using: &rng)
                    p.dual.fineTune.bands[i].filterType = EQFilterType.allCases[Int(rng.next() % 3)]
                }
                if rng.next() % 7 == 0 { p.dual.target.bands[3].gain = .nan }
                if rng.next() % 11 == 0 { p.dual.fineTune.preamp = .infinity }
                p.dual.target.preamp = Double.random(in: -20 ... 20, using: &rng)
                p.bass.selectStyle(styles[Int(rng.next() % UInt64(styles.count))])
                p.bass.strength = Double.random(in: 0 ... 1, using: &rng)
                p.bass.cutoff = Double.random(in: 40 ... 250, using: &rng)
                p.masterBypass = rng.next() % 5 == 0
                p.outputMuted = rng.next() % 13 == 0
                p.outputGainDB = Double.random(in: -30 ... 0, using: &rng)
                chain.setParameters(p)
                flags.published.add(1, ordering: .relaxed)
            }
            done.signal()
        }
        writer.qualityOfService = .userInteractive
        writer.start()

        var rng = SplitMix64(seed: 4)
        let buf = PlanarBuffer(channels: 2, frames: 512)
        let ceiling = Float(pow(10, -1.0 / 20))
        var worst: Float = 0
        var nonFinite = 0
        for _ in 0 ..< 3_000 {                     // 32 s of audio
            for ch in 0 ..< 2 {
                let d = buf.channel(ch)
                for i in 0 ..< 512 { d[i] = Float.random(in: -1 ... 1, using: &rng) }
            }
            chain.process(buf.pointers, frameCount: 512)
            for ch in 0 ..< 2 {
                let d = buf.channel(ch)
                for i in 0 ..< 512 {
                    if !d[i].isFinite { nonFinite += 1 } else { worst = max(worst, abs(d[i])) }
                }
            }
        }
        flags.stop.store(true, ordering: .releasing)
        done.wait()
        print("Stress: \(flags.published.load(ordering: .relaxed)) parameter sets published during 3000 blocks; output peak \(worst)")
        XCTAssertEqual(nonFinite, 0)
        // Bypassed blocks pass the (±1) dry input; everything else is limited.
        XCTAssertLessThanOrEqual(worst, max(ceiling + 1e-6, 1.0))
        XCTAssertGreaterThan(flags.published.load(ordering: .relaxed), 100, "the writer thread barely ran")
    }
}

private final class StressFlags: @unchecked Sendable {
    let stop = Atomic<Bool>(false)
    let published = Atomic<Int>(0)
}
