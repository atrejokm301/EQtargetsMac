//
//  RingReaderTests.swift
//  EQTCoreTests
//
//  RingReader against a FAKE driver writer in plain allocated memory
//  (EQTRingTotalBytes()), on a deterministic simulated clock: the writer runs
//  on its own (drifting) clock with seeded IO jitter, the reader renders on the
//  output clock, and host time is simulated — no wall-clock sleeps.
//
//  Signal: a 997 Hz sine (L 0.5, R 0.25) in WRITER time, so after resampling
//  the output must be a clean sine at 997·ratio_true / f_out. Any underrun,
//  stale audio, click or PLL pitch wander shows up in the fit residual or in the
//  sample-to-sample step.
//

import XCTest

final class RingReaderTests: XCTestCase {

    private let tone = 997.0

    private func makeSim(source: Double = 48_000, output: Double = 48_000, ppm: Double = 0,
                         writerBlock: Int = 512, readerBlock: Int = 512) -> RingSimulation {
        let cps = tone / source
        return RingSimulation(sourceRate: source, outputRate: output, writerBlock: writerBlock,
                              readerBlock: readerBlock, driftPPM: ppm) { f in
            let v = sin(2 * Double.pi * cps * Double(f))
            return (Float(0.5 * v), Float(0.25 * v))
        }
    }

    /// Largest |x[n] − x[n−1]| in a range. A clean 997 Hz sine at 0.5 has
    /// 0.5·2π·997/48000 = 0.0653; a click or a step is far larger.
    private func maxStep(_ x: [Float], _ r: Range<Int>) -> Double {
        var m = 0.0
        for i in max(1, r.lowerBound) ..< min(x.count, r.upperBound) { m = max(m, abs(Double(x[i] - x[i - 1]))) }
        return m
    }

    private let cleanStep = 0.5 * 2 * Double.pi * 997 / 48_000

    /// Audio integrity of a stretch of output, measured two ways so neither
    /// hides the other:
    ///  • THD+N with the frequency also fitted, over 85 ms windows — glitches,
    ///    dropouts, aliasing, noise. (A slow PLL pitch wander of a few ppm does
    ///    not register over 85 ms; it is bounded separately in ppm.)
    ///  • the pitch offset of the stretch, in ppm.
    /// Measured: the resampler alone reaches −112 dB; with ±25 µs-equivalent IO
    /// jitter on the writer's timestamps the locked PLL leaves ±3 ppm of ratio
    /// noise → about −91 dB here. −85 dB is the bound.
    private func assertCleanTone(_ y: [Float], cyclesPerSample nu: Double, seconds: Double = 0.5,
                                 thdBound: Double = -85, pitchBoundPPM: Double = 10, label: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let n = Int(48_000 * seconds)
        let tail = Array(y[(y.count - n)...])
        var worst = -300.0
        for start in stride(from: 0, through: n - 4_096, by: 4_096) {
            let r = Fixtures.fitSineFreeFrequency(Array(tail[start ..< start + 4_096]), nominal: nu, spanPPM: 300)
            worst = max(worst, r.fit.thdPlusNoiseDB)
        }
        let whole = Fixtures.fitSineFreeFrequency(tail, nominal: nu, spanPPM: 300)
        print(String(format: "%@: worst 85 ms THD+N %.1f dB, pitch offset %+.2f ppm", label, worst, whole.offsetPPM))
        XCTAssertLessThan(worst, thdBound, "\(label): output not clean", file: file, line: line)
        XCTAssertLessThan(abs(whole.offsetPPM), pitchBoundPPM, "\(label): pitch off", file: file, line: line)
    }

    // MARK: - Drift lock

    /// Stated tolerance after lock (+5 s settling): |fill − target| ≤ 8 frames,
    /// |ratio drift − true drift| ≤ 10 ppm, zero underruns / overruns, one
    /// resync (the start), output never steps faster than the clean tone.
    private func assertLocksAndHolds(ppm: Double, file: StaticString = #filePath, line: UInt = #line) {
        let sim = makeSim(ppm: ppm)
        var lockedAt: Double?
        var worstFill = 0.0, worstPPM = 0.0
        var lostLock = 0
        sim.run(seconds: 80) { st, _ in
            if lockedAt == nil, st.lock == .locked { lockedAt = sim.time }
            if let t = lockedAt, sim.time > t + 5 {
                worstFill = max(worstFill, abs(st.fillFrames - st.targetFillFrames))
                worstPPM = max(worstPPM, abs(st.driftPPM - ppm))
                if st.lock != .locked { lostLock += 1 }
            }
        }
        let st = sim.reader.stats()
        let lockTime = lockedAt ?? -1
        print(String(format: "Ring PLL %+.0f ppm: locked after %.2f s; over the following %.0f s |fill − target| ≤ %.2f frames " +
                     "(target %.0f), |drift error| ≤ %.2f ppm; underruns %d overruns %d resyncs %d",
                     ppm, lockTime, 80 - lockTime - 5, worstFill, st.targetFillFrames, worstPPM,
                     st.underruns, st.overruns, st.resyncs))
        XCTAssertNotNil(lockedAt, "never locked", file: file, line: line)
        XCTAssertLessThan(lockTime, 15, "slow to lock", file: file, line: line)
        XCTAssertGreaterThanOrEqual(80 - lockTime - 5, 60, "need ≥ 60 s of locked audio", file: file, line: line)
        XCTAssertEqual(lostLock, 0, "lost lock", file: file, line: line)
        XCTAssertLessThanOrEqual(worstFill, 8, "fill wandered after lock", file: file, line: line)
        XCTAssertLessThanOrEqual(worstPPM, 10, "ratio wandered after lock", file: file, line: line)
        XCTAssertEqual(st.underruns, 0, file: file, line: line)
        XCTAssertEqual(st.overruns, 0, file: file, line: line)
        XCTAssertEqual(st.resyncs, 1, file: file, line: line)
        XCTAssertTrue(sim.left.allSatisfy { $0.isFinite }, file: file, line: line)
        XCTAssertLessThan(maxStep(sim.left, 0 ..< sim.left.count), cleanStep * 1.01, "a glitch / step in the output", file: file, line: line)
        assertCleanTone(sim.left, cyclesPerSample: tone / 48_000 * (1 + ppm * 1e-6),
                        label: String(format: "Ring PLL %+.0f ppm output (last 0.5 s)", ppm), file: file, line: line)
    }

    func test_plus2400ppmDrift_locksAndHoldsFillWithZeroUnderrunsFor60s() {
        assertLocksAndHolds(ppm: 2_400)
    }

    func test_minus2400ppmDrift_locksAndHoldsFillWithZeroUnderrunsFor60s() {
        assertLocksAndHolds(ppm: -2_400)
    }

    func test_44_1kSourceTo48kOutput_locksAndPlaysTheRightPitch() {
        let sim = makeSim(source: 44_100, output: 48_000, ppm: 240)
        sim.run(seconds: 20)
        let st = sim.reader.stats()
        XCTAssertEqual(st.lock, .locked)
        XCTAssertEqual(st.underruns, 0)
        XCTAssertEqual(st.sourceSampleRate, 44_100)
        XCTAssertEqual(st.ratio, 44_100.0 / 48_000 * (1 + 240e-6), accuracy: 1e-5)
        assertCleanTone(sim.left, cyclesPerSample: tone / 48_000 * (1 + 240e-6), label: "Ring 44.1 → 48 kHz")
        let fit = Fixtures.fitSine(Array(sim.left[(sim.left.count - 4_096)...]), cyclesPerSample: tone / 48_000 * (1 + 240e-6))
        XCTAssertEqual(fit.amplitude, 0.5, accuracy: 0.001)
    }

    // MARK: - Resync

    func test_generationBump_causesExactlyOneResync_withAFadeAndNoGarbage() {
        let sim = makeSim(ppm: 500)
        var discontinuities = 0
        sim.run(seconds: 8) { _, _ in if sim.reader.consumeDiscontinuity() { discontinuities += 1 } }
        XCTAssertEqual(discontinuities, 1, "initial start")
        let before = sim.reader.stats()
        let eventSample = sim.left.count
        sim.startIO()                                        // new generation, head back to 0
        sim.run(seconds: 8) { _, _ in if sim.reader.consumeDiscontinuity() { discontinuities += 1 } }
        let after = sim.reader.stats()
        XCTAssertEqual(after.resyncs - before.resyncs, 1)
        XCTAssertEqual(discontinuities, 2, "consumeDiscontinuity must fire once per restart")
        XCTAssertEqual(after.generation, before.generation + 1)
        XCTAssertEqual(after.lock, .locked)
        XCTAssertTrue(sim.left.allSatisfy { $0.isFinite })
        let step = maxStep(sim.left, (eventSample - 2_000) ..< (eventSample + 6_000))
        print(String(format: "Generation bump: max sample step %.4f (clean tone %.4f)", step, cleanStep))
        XCTAssertLessThan(step, cleanStep * 1.15, "the restart clicked")
    }

    func test_generationBump_withoutDeclick_wouldClick_negativeControlForTheStepMetric() {
        // The step metric above must be able to fail: a hard cut from a
        // full-scale sine to silence (what a resync without declick does) is
        // far above the clean-tone step.
        var x = Fixtures.sine(0.5, 997, 4_000)
        for i in 2_013 ..< 4_000 { x[i] = 0 }
        XCTAssertGreaterThan(maxStep(x, 0 ..< 4_000), cleanStep * 1.15)
    }

    func test_writerStall_goesSilentAndWaiting_countsOneUnderrun_thenResumes() {
        let sim = makeSim(ppm: -300)
        sim.run(seconds: 6)
        let before = sim.reader.stats()
        let stallSample = sim.left.count
        sim.writerEnabled = false                            // IO thread stops; ioRunning stays 1
        sim.run(seconds: 0.3)
        let stalled = sim.reader.stats()
        XCTAssertEqual(stalled.lock, .waiting)
        XCTAssertEqual(stalled.underruns - before.underruns, 1)
        XCTAssertTrue(sim.left[(sim.left.count - 4_800)...].allSatisfy { $0 == 0 }, "not silent while stalled")
        let step = maxStep(sim.left, (stallSample - 1_000) ..< sim.left.count)
        XCTAssertLessThan(step, cleanStep * 1.15, "the dropout clicked")

        sim.writerEnabled = true
        sim.run(seconds: 3)
        let resumed = sim.reader.stats()
        XCTAssertEqual(resumed.lock, .locked)
        XCTAssertEqual(resumed.resyncs - stalled.resyncs, 1)
        XCTAssertEqual(resumed.underruns, stalled.underruns)
        assertCleanTone(sim.left, cyclesPerSample: tone / 48_000 * (1 - 300e-6), label: "Ring after a writer stall")
    }

    func test_readerLapped_detectsOverrun_andResyncsToFreshAudio() {
        let sim = makeSim(ppm: 1_000)
        sim.run(seconds: 5)
        let before = sim.reader.stats()
        sim.readerEnabled = false                            // output device stalls for 1 s (> 0.68 s ring)
        sim.run(seconds: 1.0)
        sim.readerEnabled = true
        let resumeSample = sim.left.count
        sim.run(seconds: 4)
        let after = sim.reader.stats()
        print("Lapped: overruns \(after.overruns - before.overruns), resyncs \(after.resyncs - before.resyncs)")
        XCTAssertGreaterThanOrEqual(after.overruns - before.overruns, 1)
        XCTAssertEqual(after.resyncs - before.resyncs, 1)
        XCTAssertEqual(after.lock, .locked)
        XCTAssertLessThan(after.fillFrames, after.targetFillFrames + 64, "kept the stale backlog instead of jumping")
        XCTAssertLessThan(maxStep(sim.left, resumeSample ..< (resumeSample + 4_800)), cleanStep * 1.15)
        assertCleanTone(sim.left, cyclesPerSample: tone / 48_000 * (1 + 1e-3), label: "Ring after being lapped")
    }

    func test_ioRunningToggling_drainsWithoutCountingUnderruns_andRestartsEachTime() {
        let sim = makeSim(ppm: 800)
        sim.run(seconds: 5)
        for cycle in 0 ..< 3 {
            let before = sim.reader.stats()
            sim.stopIO()
            sim.run(seconds: 0.5)
            let stopped = sim.reader.stats()
            XCTAssertEqual(stopped.lock, .waiting, "cycle \(cycle)")
            XCTAssertEqual(stopped.underruns, before.underruns, "a normal stop is not an underrun")
            XCTAssertTrue(sim.left[(sim.left.count - 4_800)...].allSatisfy { $0 == 0 })
            sim.startIO()
            sim.run(seconds: 2)
            let running = sim.reader.stats()
            XCTAssertEqual(running.resyncs - stopped.resyncs, 1, "cycle \(cycle)")
            XCTAssertNotEqual(running.lock, .waiting)
        }
        XCTAssertTrue(sim.left.allSatisfy { $0.isFinite })
        XCTAssertLessThan(maxStep(sim.left, 0 ..< sim.left.count), cleanStep * 1.15, "a stop or start clicked")
    }

    func test_sourceRateChange_viaGeneration_adoptsTheNewRateAndTable() {
        let rate = UnsafeMutablePointer<Double>.allocate(capacity: 1)
        rate.initialize(to: 48_000)
        defer { rate.deallocate() }
        let sim = RingSimulation(sourceRate: 48_000, outputRate: 48_000, driftPPM: 0) { [tone] f in
            // 997 Hz in WRITER time, whatever the writer's current rate.
            let v = sin(2 * Double.pi * tone / rate.pointee * Double(f))
            return (Float(0.5 * v), Float(0.25 * v))
        }
        sim.run(seconds: 4)
        rate.pointee = 96_000
        sim.startIO(sampleRate: 96_000, writerBlock: 1_024)
        sim.run(seconds: 6)
        let st = sim.reader.stats()
        XCTAssertEqual(st.sourceSampleRate, 96_000)
        XCTAssertEqual(st.ratio, 2, accuracy: 0.001)
        XCTAssertEqual(st.lock, .locked)
        // Phase of the writer signal restarts nowhere in particular after the
        // switch; the fit only needs the frequency.
        assertCleanTone(sim.left, cyclesPerSample: tone / 48_000, label: "Ring 96 → 48 kHz after a live rate change")
        let fit = Fixtures.fitSine(Array(sim.left[(sim.left.count - 4_096)...]), cyclesPerSample: tone / 48_000)
        XCTAssertEqual(fit.amplitude, 0.5, accuracy: 0.001)
    }

    // MARK: - Edges

    func test_invalidRing_isSilentAndWaiting_untilTheMagicAppears() {
        let sim = makeSim()
        EQTRingStoreMagic(sim.writer.header, 0)
        sim.run(seconds: 1)
        XCTAssertEqual(sim.reader.stats().lock, .waiting)
        XCTAssertTrue(sim.left.allSatisfy { $0 == 0 })
        EQTRingStoreMagic(sim.writer.header, EQT_RING_MAGIC)
        sim.run(seconds: 2)
        XCTAssertEqual(sim.reader.stats().lock, .locked)
        XCTAssertGreaterThan(Fixtures.peak(sim.left[(sim.left.count - 4_800)...]), 0.4)
    }

    func test_monoDestination_getsTheLeftRightAverage() {
        let sim = makeSim()
        sim.run(seconds: 2)
        let mono = PlanarBuffer(channels: 1, frames: 4_800)
        sim.writer.write(frames: 4_800, hostTime: sim.clock.pointee)   // plenty of fresh audio
        sim.reader.render(into: mono.pointers, frameCount: 2_400)
        var y: [Float] = []
        mono.store(0, into: &y, count: 2_400)
        let fit = Fixtures.fitSine(y, cyclesPerSample: tone / 48_000)
        XCTAssertEqual(fit.amplitude, 0.375, accuracy: 0.002, "mono must be (L + R) / 2 = 0.375")
    }

    /// The header lives in shared memory another process writes. Garbage in
    /// it must give silence, never an integer-overflow trap or NaN.
    func test_corruptHeader_neverTraps_andIsSilent() {
        let sim = makeSim()
        sim.run(seconds: 1)
        let h = sim.writer.header
        for head in [Int64.max, Int64(-5), Int64.min, Int64(1) << 60] {
            let from = sim.left.count
            EQTRingStoreWriteHead(h, head)
            sim.writerEnabled = false
            sim.run(seconds: 0.1)
            XCTAssertEqual(sim.reader.stats().lock, .waiting, "head \(head)")
            // Only the 5 ms declick of what was playing may follow; a corrupt
            // head must never be trusted to read (stale) ring contents.
            XCTAssertTrue(sim.left[(from + 240 + 512)...].allSatisfy { $0 == 0 }, "played audio from a corrupt head \(head)")
        }
        EQTRingStoreSampleRate(h, .nan)
        EQTRingBumpGeneration(h)
        EQTRingStoreWriteHead(h, 0)
        EQTRingStoreLastWriteHostTime(h, .max)
        EQTRingStoreIOBufferFrames(h, .max)
        sim.run(seconds: 0.2)
        XCTAssertEqual(sim.reader.stats().lock, .waiting)
        XCTAssertTrue(sim.left.allSatisfy { $0.isFinite })
        // And it recovers once the driver writes a sane ring again.
        EQTRingStoreSampleRate(h, 48_000)
        sim.startIO()
        sim.run(seconds: 2)
        XCTAssertNotEqual(sim.reader.stats().lock, .waiting)
        XCTAssertGreaterThan(Fixtures.peak(sim.left[(sim.left.count - 4_800)...]), 0.4)
    }

    /// The engine turns `stats().sourceSampleRate` into an Int frame count for
    /// the driver's 'eqtl' report; a header rate of +inf trapped there
    /// (Int(inf)) on the main thread. A rate the reader can't run must never be
    /// published: 0 means "unknown", and the engine falls back to the HAL rate.
    func test_unusableHeaderRate_isNeverPublishedInStats_andRecovers() {
        let sim = makeSim()
        sim.run(seconds: 1)
        let h = sim.writer.header
        for bad in [Double.infinity, 1e300, -Double.infinity, .nan, -48_000, 1_000, 0] {
            EQTRingStoreSampleRate(h, bad)
            sim.startIO()                     // new generation: the reader re-reads the rate
            sim.run(seconds: 0.2)
            let st = sim.reader.stats()
            XCTAssertEqual(st.sourceSampleRate, 0, "header rate \(bad) leaked into stats")
            XCTAssertEqual(st.latencySeconds, 0, "header rate \(bad): latency must be 0, not \(st.latencySeconds)")
            XCTAssertEqual(st.lock, .waiting, "header rate \(bad): must not stream")
        }
        XCTAssertTrue(sim.left.allSatisfy { $0.isFinite })
        EQTRingStoreSampleRate(h, 48_000)
        sim.startIO(sampleRate: 48_000)
        sim.run(seconds: 2)
        XCTAssertEqual(sim.reader.stats().sourceSampleRate, 48_000)
        XCTAssertGreaterThan(Fixtures.peak(sim.left[(sim.left.count - 4_800)...]), 0.4)
    }

    func test_renderBeforeConfigure_isSilent() {
        let w = FakeRingWriter(sampleRate: 48_000) { _ in (1, 1) }
        let r = RingReader(header: w.readOnlyHeader)
        let b = PlanarBuffer(channels: 2, frames: 256)
        b.channel(0).update(repeating: 7, count: 256)
        XCTAssertFalse(r.render(into: b.pointers, frameCount: 256))
        XCTAssertTrue((0 ..< 256).allSatisfy { b.channel(0)[$0] == 0 })
        XCTAssertEqual(r.stats().lock, .waiting)
    }
}
