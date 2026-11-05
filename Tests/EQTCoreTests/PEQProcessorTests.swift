//
//  PEQProcessorTests.swift
//  EQTCoreTests
//
//  The PEQ stages through the real ProcessingChain:
//    • graph == DSP — the response MEASURED with steady sines equals the
//      `EQBiquad` math the graph draws, within 0.05 dB;
//    • dragging a band never clicks (glide), and the click metric is proven
//      sensitive by switching the glide off (negative control);
//    • extreme settings stay stable, including in the middle of a glide;
//    • flat / bypassed / 0 dB is bit-exact passthrough (delayed by the
//      constant output-protection lookahead).
//

import XCTest

extension Fixtures {

    /// 40 log-spaced integer frequencies 20 Hz…20 kHz. Integer Hz over a 1 s
    /// window are exactly orthogonal, so all tones are measured in ONE run.
    static let responseFrequencies: [Double] = {
        var out: [Double] = []
        let n = 40
        for i in 0 ..< n {
            let f = (20 * pow(1_000, Double(i) / Double(n - 1))).rounded()
            if out.last != f { out.append(f) }
        }
        return out
    }()

    /// Measured magnitude response of a configured chain (dB per frequency).
    /// Multi-tone input, `settle` seconds discarded, then a 1 s rectangular DFT
    /// per tone (exact for integer-cycle tones).
    static func measuredResponseDB(chain: ProcessingChain, frequencies: [Double], settle: Double,
                                   sampleRate: Double = 48_000, toneAmplitude: Double = 1e-3,
                                   rightScale: Float = 1) -> (left: [Double], right: [Double]) {
        let total = Int((settle + 1) * sampleRate)
        var x = [Float](repeating: 0, count: total)
        var phases: [Double] = []
        var rng = SplitMix64(seed: 99)
        for _ in frequencies { phases.append(Double.random(in: 0 ..< 2 * .pi, using: &rng)) }
        for i in 0 ..< total {
            var v = 0.0
            let t = Double(i) / sampleRate
            for (k, f) in frequencies.enumerated() { v += toneAmplitude * sin(2 * .pi * f * t + phases[k]) }
            x[i] = Float(v)
        }
        let channels = chain.channelCount
        var input = [x]
        if channels > 1 { input.append(x.map { $0 * rightScale }) }
        let out = chain.run(input)
        let start = total - Int(sampleRate)
        func level(_ y: [Float], _ f: Double) -> Double {
            var re = 0.0, im = 0.0
            let w = 2 * Double.pi * f / sampleRate
            for i in start ..< total {
                let k = Double(i - start)
                re += Double(y[i]) * cos(w * k)
                im += Double(y[i]) * sin(w * k)
            }
            return 2 * (re * re + im * im).squareRoot() / sampleRate
        }
        let left = frequencies.map { db(level(out[0], $0) / toneAmplitude) }
        let right = channels > 1
            ? frequencies.map { db(level(out[1], $0) / (toneAmplitude * Double(rightScale))) }
            : left
        return (left, right)
    }

    /// The graph's prediction: preamp + Σ EQBiquad magnitudes (enabled bands).
    static func graphDB(_ layer: EQLayerState, at f: Double, sampleRate: Double = 48_000) -> Double {
        guard !layer.isBypassed else { return 0 }
        var m = layer.preamp
        for b in layer.bands where b.isEnabled {
            m += EQBiquad(type: b.filterType, frequency: b.frequency, gainDB: b.gain, q: b.q, sampleRate: sampleRate)
                .magnitudeDB(at: f, sampleRate: sampleRate)
        }
        return m
    }

    static func layer(preamp: Double = 0, _ bands: [EQBand]) -> EQLayerState {
        var b = bands
        let d = EQBand.defaultTenBands()
        while b.count < 10 { var x = d[b.count]; x.gain = 0; x.isEnabled = false; b.append(x) }
        return EQLayerState(preamp: preamp, bands: b)
    }

    static func chain(_ p: ChainParameters, sampleRate: Double = 48_000, channels: Int = 2,
                      tuning: ChainTuning = ChainTuning()) -> ProcessingChain {
        let c = ProcessingChain(maxFrames: 4_096, maxChannels: channels)
        c.tuning = tuning
        c.prepare(sampleRate: sampleRate, channelCount: channels)
        c.setParameters(p)
        // Snap: these tests measure steady state, not the glide.
        c.reset()
        return c
    }

    static let airPodsMaxPreset = """
    Preamp: -8.9 dB
    Filter 1: ON PK Fc 30 Hz Gain 1.0 dB Q 1.700
    Filter 2: ON PK Fc 100 Hz Gain 3.3 dB Q 0.600
    Filter 3: ON PK Fc 110 Hz Gain 0.9 dB Q 2.900
    Filter 4: ON PK Fc 210 Hz Gain -0.9 dB Q 2.800
    Filter 5: ON PK Fc 320 Hz Gain -2.5 dB Q 0.700
    Filter 6: ON PK Fc 1200 Hz Gain -1.5 dB Q 2.200
    Filter 7: ON PK Fc 2700 Hz Gain 2.6 dB Q 3.000
    Filter 8: ON PK Fc 4900 Hz Gain 9.4 dB Q 3.000
    Filter 9: ON PK Fc 8200 Hz Gain 5.7 dB Q 3.000
    Filter 10: ON PK Fc 8500 Hz Gain -4.7 dB Q 1.400
    """
}

final class PEQProcessorTests: XCTestCase {

    private let sr = 48_000.0

    private func assertResponseMatchesGraph(_ target: EQLayerState, _ fine: EQLayerState = .flat,
                                            settle: Double, channels: Int = 1, label: String,
                                            file: StaticString = #filePath, line: UInt = #line) {
        var p = ChainParameters()
        p.outputProtection = false        // measure the EQ, not the limiter
        p.dual.target = target
        p.dual.fineTune = fine
        let chain = Fixtures.chain(p, channels: channels)
        let freqs = Fixtures.responseFrequencies
        let measured = Fixtures.measuredResponseDB(chain: chain, frequencies: freqs, settle: settle,
                                                   rightScale: 0.5)
        var worst = 0.0
        for (i, f) in freqs.enumerated() {
            let expected = Fixtures.graphDB(target, at: f) + Fixtures.graphDB(fine, at: f)
            for m in [measured.left[i], measured.right[i]] {
                worst = max(worst, abs(m - expected))
                XCTAssertEqual(m, expected, accuracy: 0.05,
                               "\(label): \(Int(f)) Hz measured \(m) dB, graph says \(expected) dB",
                               file: file, line: line)
            }
        }
        print("PEQ graph==DSP [\(label)]: \(freqs.count) freqs, worst |measured−graph| = \(String(format: "%.5f", worst)) dB")
    }

    // MARK: - Graph == DSP

    func test_measuredResponse_equalsGraph_forRealAutoEQImport() throws {
        let target = try AutoEQParser.parse(text: Fixtures.airPodsMaxPreset)
        assertResponseMatchesGraph(target, settle: 1.0, channels: 2, label: "AirPods Max AutoEQ, stereo")
    }

    func test_measuredResponse_equalsGraph_forPeaksAtQAndGainExtremes() {
        let layer = Fixtures.layer(preamp: -6, [
            EQBand(frequency: 20, gain: 20, q: 10),        // the hardest case for stability
            EQBand(frequency: 1_000, gain: 20, q: 0.1),
            EQBand(frequency: 3_000, gain: -20, q: 10),
            EQBand(frequency: 150, gain: -20, q: 0.1),
            EQBand(frequency: 12_000, gain: 15, q: 4),
            EQBand(frequency: 19_000, gain: -12, q: 2),
        ])
        // 20 Hz / Q 10 rings with τ = Q/(π·f) = 0.16 s: 3 s settle → e^-19.
        assertResponseMatchesGraph(layer, settle: 3.0, label: "peaks, Q 0.1…10, ±20 dB")
    }

    func test_measuredResponse_equalsGraph_forShelves() {
        let layer = Fixtures.layer([
            EQBand(frequency: 105, gain: 12, q: 0.7, filterType: .lowShelf),
            EQBand(frequency: 8_000, gain: -15, q: 2, filterType: .highShelf),
            EQBand(frequency: 300, gain: -20, q: 0.1, filterType: .lowShelf),
            EQBand(frequency: 16_000, gain: 20, q: 10, filterType: .highShelf),
            EQBand(frequency: 40, gain: 20, q: 4, filterType: .lowShelf),
        ])
        assertResponseMatchesGraph(layer, settle: 2.0, label: "low/high shelves, Q 0.1…10, ±20 dB")
    }

    func test_measuredResponse_targetAndFineTuneSumInDB() throws {
        let target = try AutoEQParser.parse(text: Fixtures.airPodsMaxPreset)
        let fine = Fixtures.layer(preamp: -3, [
            EQBand(frequency: 63, gain: 6, q: 0.8, filterType: .lowShelf),
            EQBand(frequency: 4_900, gain: -6, q: 3),            // fights Target's +9.4 dB band
            EQBand(frequency: 12_000, gain: 3, q: 0.7, filterType: .highShelf),
        ])
        assertResponseMatchesGraph(target, fine, settle: 1.0, label: "Target + Fine-Tune")
    }

    // MARK: - Glide

    /// A dragged band, updated at 60 Hz, sweeping a +12 dB / Q 2 peak from
    /// 200 Hz to 2 kHz straight through a 500 Hz tone while its gain wobbles.
    private func dragClickLevel(glideMs: Double) -> (drag: Double, reference: Double) {
        var t = ChainTuning()
        t.parameterGlideMs = glideMs
        var p = ChainParameters()
        p.outputProtection = false
        p.dual.fineTune = Fixtures.layer([EQBand(frequency: 200, gain: 12, q: 2)])
        let amp = 0.25
        let x = Fixtures.sine(amp, 500, Int(sr * 1.5))

        let reference = Fixtures.chain(p, tuning: t).run([x, x])[0]
        let chain = Fixtures.chain(p, tuning: t)
        let blocksPerUpdate = 1   // 800-sample blocks → one update per 16.7 ms (60 Hz)
        var step = 0
        let out = chain.run([x, x], block: 800) { blockIndex in
            guard blockIndex % blocksPerUpdate == 0 else { return }
            step += 1
            let frac = min(1, Double(step) / 60)
            var q = p
            q.dual.fineTune.bands[0].frequency = 200 * pow(10, frac)
            q.dual.fineTune.bands[0].gain = 12 - 8 * sin(Double(step) * 0.7)
            chain.setParameters(q)
        }[0]
        return (Fixtures.clickLevelDB(out, reference: amp), Fixtures.clickLevelDB(reference, reference: amp))
    }

    func test_bandDrag_atUIRate_producesNoClickAboveTheStaticReference() {
        let glide = dragClickLevel(glideMs: 20)
        let instant = dragClickLevel(glideMs: 0)
        print("PEQ drag click level (≥8 kHz, re 500 Hz tone): glide \(String(format: "%.1f", glide.drag)) dB, " +
              "no-glide \(String(format: "%.1f", instant.drag)) dB, static reference \(String(format: "%.1f", glide.reference)) dB")
        // Justification: the static reference has no broadband content at all
        // (numerical floor). A click is broadband; the 8th-order HP at 8 kHz
        // passes it while removing the tone and its slow AM sidebands. −90 dB
        // re the tone is ~15 dB under 16-bit dither relative to a full-scale
        // tone — inaudible. The negative control proves the metric sees clicks.
        XCTAssertLessThan(glide.drag, -90, "dragging a band clicks or zips")
        XCTAssertGreaterThan(instant.drag, -70, "negative control: without the glide the metric must see clicks")
        XCTAssertLessThan(glide.reference, -120, "sanity: a static filter has no broadband content")
    }

    // MARK: - Stability

    func test_extremeSettings_areStableAtEverySupportedRate() {
        for rate in [44_100.0, 48_000, 88_200, 96_000, 176_400, 192_000] {
            for type in EQFilterType.allCases {
                for (f, q, g) in [(20.0, 10.0, 20.0), (20, 10, -20), (20_000, 0.1, 20), (20_000, 10, -20), (20, 0.1, 20)] {
                    let c = BiquadCoefficients(type: type, frequency: min(f, rate * 0.49), gainDB: g, q: q, sampleRate: rate)
                    XCTAssertTrue(c.isFinite && c.isStable, "\(type) f \(f) Q \(q) g \(g) unstable at \(rate)")
                }
            }
        }
    }

    func test_20HzQ10Plus20dB_onNoise_staysBoundedAndFinite() {
        var p = ChainParameters()
        p.outputProtection = false
        p.dual.target = Fixtures.layer([EQBand(frequency: 20, gain: 20, q: 10)])
        let chain = Fixtures.chain(p)
        var rng = SplitMix64(seed: 1)
        let n = Int(sr * 10)
        var x = (0 ..< n).map { _ in Float.random(in: -0.1 ... 0.1, using: &rng) }
        for i in (n / 2) ..< n { x[i] += 0.1 }            // plus a DC step: excites the resonance
        let y = chain.run([x, x])[0]
        XCTAssertTrue(y.allSatisfy { $0.isFinite })
        // Max possible gain is +20 dB (×10); a 0.2 peak input can't exceed ~2.
        XCTAssertLessThan(Fixtures.peak(y), 2.5)
    }

    func test_glideBetweenExtremeFilters_staysInsideTheStabilityTriangleThroughout() {
        let a = BiquadCoefficients(type: .peak, frequency: 20, gainDB: 20, q: 10, sampleRate: sr)
        let b = BiquadCoefficients(type: .highShelf, frequency: 19_000, gainDB: -20, q: 0.1, sampleRate: sr)
        let peq = PEQProcessor(sectionCount: 1, channelCount: 2, glideSamples: 960)
        peq.setTarget(0, .filter(a))
        peq.snapToTargets()
        peq.setTarget(0, .filter(b))
        let buf = UnsafeMutablePointer<Double>.allocate(capacity: 2 * 16)
        buf.initialize(repeating: 0, count: 32)
        defer { buf.deallocate() }
        var ptrs = [buf, buf + 16]
        var checked = 0
        // 16-sample blocks; reversal at block 30 (sample 496) starts a fresh
        // 960-sample glide, which ends at sample 1456 < 100 × 16.
        for blk in 0 ..< 100 {
            for i in 0 ..< 32 { buf[i] = sin(Double(blk * 16 + i) * 0.3) * 0.5 }
            ptrs.withUnsafeBufferPointer { peq.process($0.baseAddress!, frames: 16) }
            let c = peq.currentCoefficients(0)
            XCTAssertTrue(c.isStable, "unstable mid-glide at block \(blk): \(c)")
            if blk == 30 { peq.setTarget(0, .filter(a)) }   // reverse mid-glide
            checked += 1
        }
        XCTAssertEqual(peq.currentCoefficients(0), a, "glide did not land exactly on the target")
        XCTAssertEqual(checked, 100)
    }

    // MARK: - Bit-exact paths

    private func assertBitExactDelayed(_ chain: ProcessingChain, amplitude: Float = 0.85, seconds: Double = 0.5,
                                       file: StaticString = #filePath, line: UInt = #line) {
        var rng = SplitMix64(seed: 21)
        let n = Int(sr * seconds)
        let l = (0 ..< n).map { _ in Float.random(in: -amplitude ... amplitude, using: &rng) }
        let r = (0 ..< n).map { _ in Float.random(in: -amplitude ... amplitude, using: &rng) }
        let out = chain.run([l, r], block: 333)
        let d = chain.latencyFrames
        XCTAssertGreaterThan(d, 0)
        var mismatches = 0
        for i in d ..< n where out[0][i] != l[i - d] || out[1][i] != r[i - d] { mismatches += 1 }
        XCTAssertEqual(mismatches, 0, "output is not the input delayed by \(d) frames, bit for bit", file: file, line: line)
    }

    func test_flatChain_isBitExactPassthrough() {
        assertBitExactDelayed(Fixtures.chain(ChainParameters()))
    }

    func test_enabledBandsAtZeroDB_areBitExactPassthrough() {
        var p = ChainParameters()
        p.dual.target = EQLayerState(preamp: 0, bands: EQBand.defaultTenBands())   // all enabled, 0 dB
        p.dual.fineTune = Fixtures.layer([EQBand(frequency: 1_000, gain: 0, q: 10, filterType: .highShelf)])
        assertBitExactDelayed(Fixtures.chain(p))
    }

    func test_layerAndDualBypass_areBitExactPassthrough() throws {
        var p = ChainParameters()
        p.dual.target = try AutoEQParser.parse(text: Fixtures.airPodsMaxPreset)
        p.dual.target.isBypassed = true
        p.dual.fineTune = Fixtures.layer(preamp: 4, [EQBand(frequency: 500, gain: 6, q: 1)])
        p.dual.fineTune.isBypassed = true
        assertBitExactDelayed(Fixtures.chain(p))

        var q = ChainParameters()
        q.dual.target = p.dual.target
        q.dual.target.isBypassed = false
        q.dual.isBypassed = true
        assertBitExactDelayed(Fixtures.chain(q))
    }

    func test_returningToFlatAfterAnEQ_becomesBitExactAgainOnceTheTailHasDecayed() {
        var p = ChainParameters()
        p.dual.fineTune = Fixtures.layer(preamp: -2, [EQBand(frequency: 120, gain: 9, q: 3)])
        let chain = Fixtures.chain(p)
        _ = chain.run([Fixtures.sine(0.3, 120, 24_000), Fixtures.sine(0.3, 120, 24_000)])
        chain.setParameters(ChainParameters())                 // glide back to flat
        _ = chain.run([[Float](repeating: 0, count: 48_000), [Float](repeating: 0, count: 48_000)])
        assertBitExactDelayed(chain)
    }
}
