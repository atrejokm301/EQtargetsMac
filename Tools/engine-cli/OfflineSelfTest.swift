//
//  OfflineSelfTest.swift
//  eqt-engine --offline-selftest
//
//  Runs LogicChecks, then four simulated 60/30/45-second sessions through the
//  real render callback (see OfflineSimulation.swift) and judges them:
//
//   A. flat EQ, writer clock +2400 ppm, 48 k → 48 k
//   B. AutoEQ Target + 10-band Fine-Tune preset, writer −2400 ppm
//   C. 44.1 k virtual device → 48 k real device, +2400 ppm
//   D. driver restart (StartIO / generation bump) mid-stream
//
//  "Expected frequency": the writer's clock runs (1 + ppm) fast in host time,
//  so a tone of f Hz in writer samples is f·(1 + ppm) Hz in real time — and
//  that is what a perfect asynchronous resampler must hand the device. Any
//  residual pitch error is the PLL's.
//

import Foundation

enum OfflineSelfTest {

    static func run(_ r: SelfTestReport, seconds: Double?) {
        LogicChecks.run(r)

        let flat = ChainParameters()
        let stereoTones = SimSignal(left: [SimTone(frequency: 1_000, amplitude: 0.25)],
                                    right: [SimTone(frequency: 1_500, amplitude: 0.25)], rate: 48_000)

        // A
        var a = SimCase(name: "A  flat EQ, writer +2400 ppm, 48 kHz → 48 kHz", writerPPM: 2_400,
                        seconds: seconds ?? 60, parameters: flat, signal: stereoTones)
        a.seed = 1
        evaluate(r, a, toneChecks: .flatStereo)

        // B
        let (presetParams, presetName) = preset()
        let grid = FrequencyResponse.curves(dual: presetParams.dual).combined
        let picks = [40, 50, 60, 66, 72, 80, 88].map { grid[$0] }
        let multitone = picks.map { SimTone(frequency: $0.frequency, amplitude: 0.04) }
        var bSignal = SimSignal(left: multitone, right: multitone, rate: 48_000)
        bSignal.kickAmplitude = 0.25
        var b = SimCase(name: "B  \(presetName), writer −2400 ppm", writerPPM: -2_400,
                        seconds: seconds ?? 60, parameters: presetParams, signal: bSignal)
        b.seed = 2
        evaluate(r, b, toneChecks: .preset(picks))

        // C
        var c = SimCase(name: "C  44.1 kHz virtual device → 48 kHz output, writer +2400 ppm", sourceRate: 44_100,
                        writerPPM: 2_400, seconds: min(seconds ?? 30, 30),
                        parameters: flat,
                        signal: SimSignal(left: [SimTone(frequency: 1_000, amplitude: 0.25)],
                                          right: [SimTone(frequency: 1_500, amplitude: 0.25)], rate: 44_100))
        c.seed = 3
        evaluate(r, c, toneChecks: .flatStereo)

        // D
        var d = SimCase(name: "D  driver restart (generation bump) at 25 s, writer +2400 ppm", writerPPM: 2_400,
                        seconds: 45, parameters: flat, signal: stereoTones, restartAt: 25)
        d.seed = 4
        evaluate(r, d, toneChecks: .flatStereo)
    }

    /// Target from an AutoEQ ParametricEQ.txt (parsed by the app's parser) +
    /// the built-in 10-band "Vocal Focus" Fine-Tune.
    static func preset() -> (ChainParameters, String) {
        let autoEQ = """
        Preamp: -6.4 dB
        Filter 1: ON LSC Fc 105 Hz Gain 6.0 dB Q 0.70
        Filter 2: ON PK Fc 180 Hz Gain -2.1 dB Q 0.80
        Filter 3: ON PK Fc 950 Hz Gain 1.2 dB Q 1.40
        Filter 4: ON PK Fc 2100 Hz Gain 2.8 dB Q 2.10
        Filter 5: ON PK Fc 3400 Hz Gain -1.9 dB Q 3.00
        Filter 6: ON PK Fc 5600 Hz Gain -3.5 dB Q 4.00
        Filter 7: ON PK Fc 7400 Hz Gain 2.4 dB Q 3.50
        Filter 8: ON PK Fc 9800 Hz Gain -2.2 dB Q 2.80
        Filter 9: ON PK Fc 13200 Hz Gain 1.5 dB Q 1.50
        Filter 10: ON HSC Fc 10000 Hz Gain -1.0 dB Q 0.70
        """
        var p = ChainParameters()
        if let target = try? AutoEQParser.parse(text: autoEQ) { p.dual.target = target }
        if let vocal = BuiltinPresets.fineTunes.first(where: { $0.name == "Vocal Focus" }) { p.dual.fineTune = vocal.layer }
        return (p, "AutoEQ Target (10 filters) + 10-band \"Vocal Focus\" Fine-Tune")
    }

    enum ToneChecks {
        case flatStereo
        case preset([FrequencyResponse.Point])
    }

    static func evaluate(_ r: SelfTestReport, _ c: SimCase, toneChecks: ToneChecks) {
        r.section("Simulation \(c.name) — \(Int(c.seconds)) s")
        let res = Simulation.run(c)
        let ppm = c.writerPPM * 1e-6
        r.note("ran \(Int(c.seconds)) s of audio in \(res.wallSeconds.f(2)) s wall; \(res.renderCalls) callbacks")

        // Lock / continuity.
        let lockedAt = c.restartAt == nil ? res.lockTime : res.relockTime
        r.check("PLL locks (\(c.restartAt == nil ? "cold start" : "after restart"))", lockedAt.map { $0 < (c.restartAt ?? 0) + 20 } ?? false,
                lockedAt.map { "locked at \($0.f(2)) s" } ?? "never locked")
        let after = res.final.underruns - res.underrunsAtLock
        r.check("zero underruns after lock", res.lockTime != nil && after == 0,
                "after lock \(after), total \(res.final.underruns)")
        r.check("zero overruns", res.final.overruns == 0, "\(res.final.overruns)")
        let expectedStarts: UInt64 = c.restartAt == nil ? 1 : 2
        r.check("stream starts → chain resets: \(expectedStarts) (consumeDiscontinuity → requestReset)",
                res.discontinuities == expectedStarts && res.final.resyncs == Int(expectedStarts),
                "discontinuities \(res.discontinuities), resyncs \(res.final.resyncs)")
        r.check("callback wrote every frame (no NaN left, no rejects, no silence flag)",
                res.nonFinite == 0 && res.rejected == 0 && res.silenceFlags == 0,
                "nonFinite \(res.nonFinite), rejected \(res.rejected), silence \(res.silenceFlags)")

        // Latency.
        let target = res.targetFill
        r.check("fill holds the target after lock (|fill − target| ≤ 10 frames)", res.measureFrom != nil && res.maxFillError <= 10,
                "max \(res.maxFillError.f(2)) frames of target \(target.f(0))")
        let targetSeconds = target / c.sourceRate
        let latOK = res.latencyRange.min >= targetSeconds - 0.0005 && res.latencyRange.max <= targetSeconds + 0.0005
        r.check("ring latency within target (±0.5 ms)", res.measureFrom != nil && latOK,
                "\((res.latencyRange.min * 1000).f(3))…\((res.latencyRange.max * 1000).f(3)) ms, target \((targetSeconds * 1000).f(3)) ms")
        let shown = LatencyMath.engineLatencyMs(ringSeconds: res.final.latencySeconds, chainFrames: res.chainLatencyFrames,
                                                deviceFrames: 0, outputRate: c.outputRate)
        r.note("EngineStats.latencyMs (device latency 0 here) = \(shown.f(2)) ms = ring \((res.final.latencySeconds * 1000).f(2)) + chain \(res.chainLatencyFrames) frames; drift absorbed \(res.final.driftPPM.f(1)) ppm (writer \(c.writerPPM.f(0)))")

        // Output sanity.
        r.check("output never above the −1 dBFS protection ceiling", res.peak <= 0.8913 + 1e-4, "peak \(res.peak)")
        r.check("limiter idle during measurement (linear path)", res.meters.limiterReductionDB == 0
                    && res.meters.overCount == res.overCountAtMeasure, "GR \(res.meters.limiterReductionDB.f(2)) dB")

        if res.busyTicks > 0, res.periodTicks > 0 {
            let us = Double(res.busyTicks) / RingReader.hostTicksPerSecond / Double(res.renderCalls) * 1e6
            r.note("render cost: \(us.f(2)) µs per \(c.outFrames)-frame callback = \((Double(res.busyTicks) / Double(res.periodTicks) * 100).f(3)) % of real time (reader + chain + glue)")
        }

        guard let from = res.measureFrom else {
            r.check("steady-state analysis possible", false, "no lock")
            return
        }
        let fs = c.outputRate
        let window = Int(fs)            // 1 s windows → 1 Hz bins, BH4
        switch toneChecks {
        case .flatStereo:
            for (ch, tone, other, out) in [("L", c.signal.left[0], c.signal.right[0], res.outL),
                                           ("R", c.signal.right[0], c.signal.left[0], res.outR)] {
                let expectedHz = tone.frequency * (1 + ppm)
                let fit = ToneAnalysis.fit(out, from: from, windowSize: window, frequency: expectedHz, sampleRate: fs)
                let ppmErr = fit.frequencyErrorHz / expectedHz * 1e6
                let levelErr = ToneAnalysis.dB(fit.amplitude / tone.amplitude)
                r.check("\(ch) \(Int(tone.frequency)) Hz: frequency = input × (1 + drift) within 5 ppm", abs(ppmErr) <= 5,
                        "error \(ppmErr.f(2)) ppm over \(fit.windows) s")
                r.check("\(ch) \(Int(tone.frequency)) Hz: level = input within 0.05 dB, steady", abs(levelErr) <= 0.05 && fit.amplitudeSpreadDB <= 0.05,
                        "error \(levelErr.f(4)) dB, spread \(fit.amplitudeSpreadDB.f(4)) dB")
                // Crosstalk: the other channel's tone frequency in THIS channel.
                // The kick bursts (on both channels) have some energy there
                // themselves, so the reference is the same bin measured on this
                // channel's INPUT; a crosstalk path would add to it.
                let leak = ToneAnalysis.fit(out, from: from, windowSize: window, frequency: other.frequency * (1 + ppm), sampleRate: fs)
                let leakDB = ToneAnalysis.dB(leak.amplitude / tone.amplitude)
                let floorDB = ToneAnalysis.dB(inputBin(c.signal, left: ch == "L", frequency: other.frequency,
                                                       windows: max(1, leak.windows)) / tone.amplitude)
                r.check("\(ch): no crosstalk from the other channel (≤ input's own content there + 1 dB, or ≤ −110 dB)",
                        leakDB <= max(-110, floorDB + 1), "\(leakDB.f(1)) dB at \(Int(other.frequency)) Hz; input itself up to \(floorDB.f(1)) dB")
            }
        case .preset(let points):
            var worstGrid = 0.0, worstExact = 0.0
            var maxPredicted = 0.0
            for p in points {
                let fOut = p.frequency * (1 + ppm)
                let exact = exactResponseDB(c.parameters, at: fOut, sampleRate: fs)
                maxPredicted = max(maxPredicted, abs(p.magnitudeDB))
                for (ch, out) in [("L", res.outL), ("R", res.outR)] {
                    let fit = ToneAnalysis.fit(out, from: from, windowSize: window, frequency: fOut, sampleRate: fs)
                    let measured = ToneAnalysis.dB(fit.amplitude / 0.04)
                    worstGrid = max(worstGrid, abs(measured - p.magnitudeDB))
                    worstExact = max(worstExact, abs(measured - exact))
                    if ch == "L" {
                        r.note("\(p.frequency.f(1)) Hz: measured \(measured.f(3)) dB, FrequencyResponse \(p.magnitudeDB.f(3)) dB, exact @\(fOut.f(1)) Hz \(exact.f(3)) dB")
                    }
                }
            }
            r.check("preset actually shapes the spectrum (|predicted| reaches ≥ 2 dB)", maxPredicted >= 2, "max \(maxPredicted.f(2)) dB")
            r.check("measured gain = FrequencyResponse curve within 0.1 dB (\(points.count) tones × 2 ch)", worstGrid <= 0.1,
                    "worst \(worstGrid.f(4)) dB (includes the 2400 ppm frequency shift)")
            r.check("measured gain = exact RBJ response at the shifted frequency within 0.02 dB", worstExact <= 0.02,
                    "worst \(worstExact.f(4)) dB")
        }
    }

    /// Windowed-DFT amplitude of the INPUT signal (one channel, at the source
    /// rate, before any processing) at `frequency` — the WORST over window
    /// alignments across one kick period. The kicks' energy in a bin depends on
    /// where they fall inside the window, and the output's alignment drifts
    /// (2400 ppm × 48 s ≈ 115 ms), so the input reference must cover them all.
    static func inputBin(_ signal: SimSignal, left: Bool, frequency: Double, windows: Int) -> Double {
        let n = Int(signal.rate)
        let total = n * (windows + 2)
        let stereo = UnsafeMutablePointer<Float>.allocate(capacity: 2 * total)
        defer { stereo.deallocate() }
        signal.render(first: 0, count: total, into: stereo)
        let x = (0 ..< total).map { stereo[2 * $0 + (left ? 0 : 1)] }
        let period = Int(signal.kickPeriodSeconds * signal.rate)
        return (0 ..< 10).map { k in
            ToneAnalysis.fit(Array(x.prefix(n * (windows + 1))), from: k * period / 10, windowSize: n,
                             frequency: frequency, sampleRate: signal.rate).amplitude
        }.max() ?? 0
    }

    /// Target + Fine-Tune (preamps + RBJ biquads) at exactly `f` — the same
    /// formula FrequencyResponse plots, evaluated off its grid.
    static func exactResponseDB(_ p: ChainParameters, at f: Double, sampleRate fs: Double) -> Double {
        var db = 0.0
        for layer in [p.dual.target, p.dual.fineTune] where !layer.isBypassed {
            db += layer.preamp
            for b in layer.bands where b.isEnabled && abs(b.gain) >= 0.001 {
                db += EQBiquad(type: b.filterType, frequency: b.frequency, gainDB: b.gain, q: b.q, sampleRate: fs)
                    .magnitudeDB(at: f, sampleRate: fs)
            }
        }
        return db
    }
}
