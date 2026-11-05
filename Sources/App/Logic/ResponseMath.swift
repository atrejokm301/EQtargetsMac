//
//  ResponseMath.swift
//  EQtargets (macOS)
//
//  Frequency-response curves for the graph (DESIGN §7.1, "Graph == DSP").
//
//  WHY NOT `FrequencyResponse.curves`: that ported helper samples 96 points at a
//  fixed 48 kHz. A +12 dB, Q 10 peak is only ~0.14 octave wide while the grid
//  steps 0.105 octave, so its apex can be drawn ~4 dB low; and near Nyquist the
//  bilinear-transform shapes differ between 44.1 / 48 / 96 kHz. Here we:
//    • evaluate the exact `EQBiquad` RBJ coefficients at the RUNNING sample rate;
//    • use max(256, width/2) log-spaced points (≤ 1024) PLUS every enabled
//      band's exact centre frequency, so no apex falls between samples;
//    • mirror `ProcessingChain.layerSections` rules: a bypassed layer contributes
//      nothing (not even its preamp), bands under 0.001 dB are identity, and the
//      band frequency is clamped to 0.49 · fs like the DSP does.
//  cos/sin of ω and 2ω are computed once per grid point and shared by all 20
//  biquads, so a 1024-point evaluation is ~20 k cheap complex divisions.
//

import Foundation

struct ResponseCurves: Equatable {
    var frequencies: [Double] = []
    /// dB including the layer preamp; all zeros when the layer is bypassed.
    var target: [Double] = []
    var fine: [Double] = []
    var total: [Double] = []
    var sampleRate: Double = 48_000

    var isEmpty: Bool { frequencies.isEmpty }
}

enum ResponseMath {
    static let minPoints = 256
    static let maxPoints = 1024
    static let fallbackSampleRate: Double = 48_000

    static func pointCount(plotWidth: Double) -> Int {
        min(maxPoints, max(minPoints, Int(plotWidth / 2)))
    }

    /// Rate the graph should use: the device's running rate, else 48 kHz.
    static func displaySampleRate(_ running: Double) -> Double {
        running.isFinite && running >= 8_000 ? running : fallbackSampleRate
    }

    /// Log-spaced 20 Hz…20 kHz grid with `centres` merged in (sorted, de-duplicated).
    static func grid(count: Int, centres: [Double]) -> [Double] {
        let n = max(2, count)
        let a = log10(20.0), b = log10(20_000.0)
        let step = (b - a) / Double(n - 1)
        var g = (0 ..< n).map { pow(10, a + Double($0) * step) }
        let extra = centres.filter { $0.isFinite && $0 > 20 && $0 < 20_000 }
        guard !extra.isEmpty else { return g }
        g.append(contentsOf: extra)
        g.sort()
        var out: [Double] = []
        out.reserveCapacity(g.count)
        for f in g where out.last.map({ f - $0 > $0 * 1e-9 }) ?? true { out.append(f) }
        return out
    }

    /// Trig terms of one grid at one sample rate, shared by every biquad.
    struct Trig {
        let cosW: [Double], cos2W: [Double], sinW: [Double], sin2W: [Double]
        init(frequencies: [Double], sampleRate: Double) {
            var c1 = [Double](), c2 = [Double](), s1 = [Double](), s2 = [Double]()
            c1.reserveCapacity(frequencies.count); c2.reserveCapacity(frequencies.count)
            s1.reserveCapacity(frequencies.count); s2.reserveCapacity(frequencies.count)
            for f in frequencies {
                let w = 2 * Double.pi * f / sampleRate
                c1.append(cos(w)); c2.append(cos(2 * w)); s1.append(sin(w)); s2.append(sin(2 * w))
            }
            cosW = c1; cos2W = c2; sinW = s1; sin2W = s2
        }
    }

    /// Magnitude of one layer (preamp + enabled bands) in dB on `trig`'s grid.
    static func layerDB(_ layer: EQLayerState, trig: Trig, sampleRate: Double) -> [Double] {
        let n = trig.cosW.count
        guard !layer.isBypassed else { return [Double](repeating: 0, count: n) }
        let preamp = layer.preamp.isFinite
            ? min(max(layer.preamp, EQLayerState.preampRange.lowerBound), EQLayerState.preampRange.upperBound)
            : 0
        var out = [Double](repeating: preamp, count: n)
        for band in layer.bands.prefix(EQLayerState.bandCount) where band.isEnabled {
            let gain = min(max(band.gain, EQBand.gainRange.lowerBound), EQBand.gainRange.upperBound)
            guard gain.isFinite, abs(gain) >= 0.001 else { continue }
            let f = min(max(band.frequency, EQBand.frequencyRange.lowerBound),
                        min(EQBand.frequencyRange.upperBound, sampleRate * 0.49))
            let q = min(max(band.q, EQBand.qRange.lowerBound), EQBand.qRange.upperBound)
            let bq = EQBiquad(type: band.filterType, frequency: f, gainDB: gain, q: q, sampleRate: sampleRate)
            for i in 0 ..< n {
                let numRe = bq.b0 + bq.b1 * trig.cosW[i] + bq.b2 * trig.cos2W[i]
                let numIm = -(bq.b1 * trig.sinW[i] + bq.b2 * trig.sin2W[i])
                let denRe = bq.a0 + bq.a1 * trig.cosW[i] + bq.a2 * trig.cos2W[i]
                let denIm = -(bq.a1 * trig.sinW[i] + bq.a2 * trig.sin2W[i])
                let n2 = numRe * numRe + numIm * numIm
                let d2 = denRe * denRe + denIm * denIm
                if d2 > 1e-30, n2 > 0 { out[i] += 10 * log10(n2 / d2) }
            }
        }
        return out
    }

    /// Centre frequencies of every enabled band in the non-bypassed layers.
    static func centres(of dual: DualEQState) -> [Double] {
        var c: [Double] = []
        for layer in [dual.target, dual.fineTune] where !layer.isBypassed {
            for b in layer.bands where b.isEnabled { c.append(b.frequency) }
        }
        return c
    }

    static func curves(dual: DualEQState, sampleRate: Double, count: Int) -> ResponseCurves {
        let sr = displaySampleRate(sampleRate)
        let freqs = grid(count: count, centres: centres(of: dual))
        let trig = Trig(frequencies: freqs, sampleRate: sr)
        // `dual.isBypassed` bypasses both layers in the DSP; mirror it.
        var t = dual.target, f = dual.fineTune
        if dual.isBypassed { t.isBypassed = true; f.isBypassed = true }
        let tc = layerDB(t, trig: trig, sampleRate: sr)
        let fc = layerDB(f, trig: trig, sampleRate: sr)
        let total = zip(tc, fc).map { $0 + $1 }
        return ResponseCurves(frequencies: freqs, target: tc, fine: fc, total: total, sampleRate: sr)
    }

    /// One layer alone (import preview mini curve).
    static func layerCurve(_ layer: EQLayerState, sampleRate: Double, count: Int) -> (freqs: [Double], db: [Double]) {
        let sr = displaySampleRate(sampleRate)
        let freqs = grid(count: count, centres: layer.isBypassed ? [] : layer.bands.filter(\.isEnabled).map(\.frequency))
        let trig = Trig(frequencies: freqs, sampleRate: sr)
        return (freqs, layerDB(layer, trig: trig, sampleRate: sr))
    }

    struct Peak: Equatable { let frequency: Double; let db: Double }

    /// Highest boost of a curve; nil when it never rises 0.05 dB above 0 (same
    /// "flat → no marker" rule as `FrequencyResponse.peak`).
    static func peak(frequencies: [Double], values: [Double]) -> Peak? {
        guard let i = values.indices.max(by: { values[$0] < values[$1] }) else { return nil }
        guard values[i] >= 0.05 else { return nil }
        return Peak(frequency: frequencies[i], db: values[i])
    }

    /// Highest point of a curve that is NOT flat — including an all-cut curve,
    /// whose highest point is below 0 dB. Calling such a curve "Flat" (what the
    /// boost-only `peak` would imply) is untrue; its highest point is also the
    /// honest headroom figure. nil only when |curve| < 0.05 dB everywhere.
    static func highest(frequencies: [Double], values: [Double]) -> Peak? {
        guard maxAbs(values) >= 0.05, let i = values.indices.max(by: { values[$0] < values[$1] }) else { return nil }
        return Peak(frequency: frequencies[i], db: values[i])
    }

    /// Largest |value| in a curve (drives the Auto ±12 / ±24 dB scale).
    static func maxAbs(_ values: [Double]) -> Double {
        values.reduce(0) { max($0, abs($1)) }
    }
}
