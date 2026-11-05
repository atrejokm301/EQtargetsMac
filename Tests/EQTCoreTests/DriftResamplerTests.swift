//
//  DriftResamplerTests.swift
//  EQTCoreTests
//
//  Measured quality of the ring resampler (DriftResampler + ResamplerTable),
//  driven directly with long planar test signals:
//    • passband flat within 0.05 dB up to 0.4·fs_out (48 kHz, ratio 1.0024);
//    • THD+N of a 1 kHz sine at ratio 1.0024 below −100 dB;
//    • alias / image rejection better than −80 dB for a 19 kHz tone, 48 → 44.1;
//    • sane at the ends of the supported ratio range (0.25 and 4).
//
//  Measurement: a least-squares sine fit at the exactly known output frequency
//  (ν_out = ν_in · ratio); whatever is not that sine is distortion + noise.
//

import XCTest

final class DriftResamplerTests: XCTestCase {

    /// Resample a mono source at a fixed ratio; returns the output.
    private func resample(_ source: [Float], ratio: Double, table: ResamplerTable? = nil, outputs: Int? = nil) -> [Float] {
        let t = table ?? ResamplerTable.table(forRatio: ratio)
        let k = ResamplerKernel(t)
        let usable = Double(source.count - k.taps - 2) / ratio
        let count = min(outputs ?? Int(usable), Int(usable))
        var out = [Float](repeating: 0, count: count)
        source.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                // Render in blocks, carrying (index, frac) like the reader does.
                var idx = k.before
                var frac = 0.0
                var o = 0
                while o < count {
                    let m = min(512, count - o)
                    let r = DriftResampler.render(kernel: k, left: src.baseAddress!, right: nil,
                                                  index: idx, frac: frac, ratio: ratio, count: m,
                                                  outLeft: dst.baseAddress! + o, outRight: nil)
                    idx = r.index; frac = r.frac
                    o += m
                }
            }
        }
        return out
    }

    private func tone(_ hz: Double, rate: Double, seconds: Double, amp: Double = 0.5) -> [Float] {
        Fixtures.sine(amp, hz, Int(rate * seconds), sampleRate: rate, phase: 0.3)
    }

    // MARK: - Targets

    func test_passband_isFlatWithin0_05dB_to0_4fsOut_atDriftRatio() {
        let rate = 48_000.0, ratio = 1.0024
        var worst = 0.0
        var f = 20.0
        while f <= 0.4 * rate / ratio {
            let y = resample(tone(f, rate: rate, seconds: 0.5), ratio: ratio)
            let seg = y[200 ..< (y.count - 200)]
            let fit = Fixtures.fitSine(Array(seg), cyclesPerSample: f / rate * ratio)
            let gain = Fixtures.db(fit.amplitude / 0.5)
            worst = max(worst, abs(gain))
            XCTAssertEqual(gain, 0, accuracy: 0.05, "\(Int(f)) Hz passband gain \(gain) dB")
            f *= 1.25
        }
        print("Resampler passband (48 kHz, ratio 1.0024, ≤ 0.4·fs_out): worst |gain| = \(String(format: "%.5f", worst)) dB")
    }

    func test_thdPlusNoise_of1kHzAtRatio1_0024_isBelowMinus100dB() {
        let rate = 48_000.0, ratio = 1.0024
        let y = resample(tone(1_000, rate: rate, seconds: 1.0), ratio: ratio)
        let fit = Fixtures.fitSine(Array(y[1_000 ..< 41_000]), cyclesPerSample: 1_000 / rate * ratio)
        print("Resampler THD+N, 1 kHz @ −6 dBFS, ratio 1.0024: \(String(format: "%.1f", fit.thdPlusNoiseDB)) dB")
        XCTAssertLessThan(fit.thdPlusNoiseDB, -100)
    }

    func test_thdPlusNoise_1kHz_44_1to48_isBelowMinus100dB() {
        let ratio = 44_100.0 / 48_000.0
        let y = resample(tone(1_000, rate: 44_100, seconds: 1.0), ratio: ratio)
        let fit = Fixtures.fitSine(Array(y[1_000 ..< 41_000]), cyclesPerSample: 1_000 / 48_000)
        print("Resampler THD+N, 1 kHz, 44.1 → 48 kHz: \(String(format: "%.1f", fit.thdPlusNoiseDB)) dB")
        XCTAssertLessThan(fit.thdPlusNoiseDB, -100)
    }

    func test_aliasRejection_19kHzTone_48to44_1_isBetterThanMinus80dB() {
        let ratio = 48_000.0 / 44_100.0
        let amp = 0.5
        let y = resample(tone(19_000, rate: 48_000, seconds: 1.0, amp: amp), ratio: ratio)
        let seg = Array(y[1_000 ..< 40_000])
        // The image of 19 kHz at 48 kHz sits at 29 kHz; if it leaked it would
        // fold to 44.1 − 29 = 15.1 kHz in the output.
        let alias = Fixtures.toneAmplitude(seg, cyclesPerSample: 15_100 / 44_100)
        let fit = Fixtures.fitSine(seg, cyclesPerSample: 19_000 / 44_100)
        let aliasDB = Fixtures.db(alias / amp)
        let residualDB = Fixtures.db(fit.residualRMS * 2.0.squareRoot() / amp)
        print("Resampler 48 → 44.1, 19 kHz: alias @15.1 kHz \(String(format: "%.1f", aliasDB)) dB, " +
              "all non-19 kHz content \(String(format: "%.1f", residualDB)) dB, 19 kHz level \(String(format: "%.2f", Fixtures.db(fit.amplitude / amp))) dB")
        XCTAssertLessThan(aliasDB, -80)
        XCTAssertLessThan(residualDB, -80, "something other than the tone (any alias/image) is above −80 dB")
    }

    func test_aliasMeasurement_detectsAPoorKernel_negativeControl() {
        // Same 19 kHz measurement through a rectangular-window kernel (β = 0,
        // ~−21 dB sidelobes) of the same geometry: the image must now show.
        // Proves the −80 dB assertion above can fail.
        let ratio = 48_000.0 / 44_100.0
        let g = ResamplerTable.geometry(forRatio: ratio)
        let poor = ResamplerTable(taps: g.taps, phases: 1_024, cutoff: g.cutoff, beta: 0)
        let y = resample(tone(19_000, rate: 48_000, seconds: 1.0), ratio: ratio, table: poor)
        let fit = Fixtures.fitSine(Array(y[1_000 ..< 40_000]), cyclesPerSample: 19_000 / 44_100)
        let residualDB = Fixtures.db(fit.residualRMS * 2.0.squareRoot() / 0.5)
        XCTAssertGreaterThan(residualDB, -80, "negative control did not degrade (\(residualDB) dB)")
    }

    func test_downsampling2to1_rejectsContentAboveTheOutputNyquist() {
        // 96 → 48 kHz: a 30 kHz source tone has no place in the output and
        // would fold to 18 kHz. The stretched kernel (cutoff 0.5/r, r× taps)
        // must remove it; the 1:1 kernel (no cutoff scaling) must not — that
        // second half is the negative control for the scaling itself.
        let ratio = 2.0
        let x = tone(30_000, rate: 96_000, seconds: 0.5)
        let scaled = resample(x, ratio: ratio)
        let unscaled = resample(x, ratio: ratio, table: ResamplerTable.table(forRatio: 1))
        let a = Fixtures.db(Fixtures.toneAmplitude(Array(scaled[500 ..< 20_000]), cyclesPerSample: 18_000 / 48_000) / 0.5)
        let b = Fixtures.db(Fixtures.toneAmplitude(Array(unscaled[500 ..< 20_000]), cyclesPerSample: 18_000 / 48_000) / 0.5)
        print("Resampler 96 → 48 kHz, 30 kHz tone: alias @18 kHz \(String(format: "%.1f", a)) dB (scaled kernel), \(String(format: "%.1f", b)) dB (unscaled)")
        XCTAssertLessThan(a, -80)
        XCTAssertGreaterThan(b, -20, "negative control: an unscaled kernel must alias")
    }

    func test_extremeRatios_0_25and4_resampleCleanly() {
        for (ratio, inRate) in [(0.25, 48_000.0), (4.0, 192_000.0)] {
            let outRate = inRate / ratio
            let y = resample(tone(1_000, rate: inRate, seconds: ratio > 1 ? 0.6 : 0.3), ratio: ratio)
            let n = min(y.count - 1_000, 20_000)
            let fit = Fixtures.fitSine(Array(y[500 ..< (500 + n)]), cyclesPerSample: 1_000 / outRate)
            print("Resampler ratio \(ratio): 1 kHz THD+N \(String(format: "%.1f", fit.thdPlusNoiseDB)) dB, gain \(String(format: "%.4f", Fixtures.db(fit.amplitude / 0.5))) dB")
            XCTAssertLessThan(fit.thdPlusNoiseDB, -95, "ratio \(ratio)")
            XCTAssertEqual(Fixtures.db(fit.amplitude / 0.5), 0, accuracy: 0.05, "ratio \(ratio)")
        }
    }

    // MARK: - Table construction

    func test_everyPhaseRow_hasExactlyUnityDCGain() {
        for ratio in [1.0, 48_000.0 / 44_100, 4.0] {
            let t = ResamplerTable.table(forRatio: ratio)
            for j in stride(from: 0, through: t.phases, by: 7) {
                var s = 0.0
                for m in 0 ..< t.taps { s += Double(t.coefficients[j * t.taps + m]) }
                XCTAssertEqual(s, 1, accuracy: 2e-6, "row \(j) of ratio \(ratio)")
            }
        }
    }

    func test_downsamplingTables_scaleCutoffAndTaps() {
        XCTAssertEqual(ResamplerTable.geometry(forRatio: 1.0024).taps, 32)
        XCTAssertEqual(ResamplerTable.geometry(forRatio: 0.25).taps, 32)
        let g = ResamplerTable.geometry(forRatio: 4)
        XCTAssertEqual(g.taps, 128)
        XCTAssertEqual(g.cutoff, 0.125, accuracy: 1e-12)
        XCTAssertTrue(ResamplerTable.table(forRatio: 2) === ResamplerTable.table(forRatio: 2), "cache miss")
    }
}
