//
//  SelfTestSupport.swift
//  eqt-engine
//
//  PASS/FAIL bookkeeping, a deterministic PRNG, and the tone analysis the
//  offline simulation uses (single-bin windowed DFT + phase-slope frequency
//  estimate). Not real-time code.
//

import Foundation

final class SelfTestReport {
    private(set) var passed = 0
    private(set) var failed = 0
    private(set) var failures: [String] = []

    func section(_ title: String) {
        print("\n== \(title)")
    }

    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        let line = "\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  [\(detail)]")"
        print(line)
        if ok { passed += 1 } else { failed += 1; failures.append(line) }
        fflush(stdout)
    }

    func note(_ text: String) {
        print("      \(text)")
        fflush(stdout)
    }

    func summary() {
        print("\n\(failed == 0 ? "ALL PASS" : "FAILURES"): \(passed) passed, \(failed) failed")
        for f in failures { print("  \(f)") }
    }
}

/// SplitMix64: deterministic, seedable, good enough for timing jitter.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Uniform in [0, 1).
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

enum ToneAnalysis {

    /// 4-term Blackman-Harris (−92 dB sidelobes): tones and kicks in other
    /// bins cannot leak into the one being measured.
    static func blackmanHarris(_ n: Int) -> [Double] {
        let a0 = 0.35875, a1 = 0.48829, a2 = 0.14128, a3 = 0.01168
        return (0 ..< n).map { i in
            let x = 2 * Double.pi * Double(i) / Double(n - 1)
            return a0 - a1 * cos(x) + a2 * cos(2 * x) - a3 * cos(3 * x)
        }
    }

    struct Bin { var amplitude: Double; var phase: Double }

    /// Windowed DFT of x[start ..< start+window.count] at `frequency`, with the
    /// phase referenced to ABSOLUTE sample index (so phases of successive
    /// windows line up and their slope is the frequency error).
    static func bin(_ x: [Float], start: Int, window: [Double], frequency f: Double, sampleRate fs: Double) -> Bin {
        let n = window.count
        guard start >= 0, start + n <= x.count, n > 1 else { return Bin(amplitude: 0, phase: 0) }
        let cyclesPerSample = f / fs
        let startCycles = (cyclesPerSample * Double(start)).truncatingRemainder(dividingBy: 1)
        var c = cos(-2 * Double.pi * startCycles), s = sin(-2 * Double.pi * startCycles)
        let dc = cos(-2 * Double.pi * cyclesPerSample), ds = sin(-2 * Double.pi * cyclesPerSample)
        var re = 0.0, im = 0.0, wsum = 0.0
        x.withUnsafeBufferPointer { p in
            for i in 0 ..< n {
                let v = Double(p[start + i]) * window[i]
                re += v * c
                im += v * s
                wsum += window[i]
                let nc = c * dc - s * ds
                s = c * ds + s * dc
                c = nc
            }
        }
        return Bin(amplitude: 2 * (re * re + im * im).squareRoot() / wsum, phase: atan2(im, re))
    }

    struct ToneFit {
        var amplitude: Double          // mean over windows
        var amplitudeSpreadDB: Double  // max − min over windows
        var frequencyErrorHz: Double   // true − assumed
        var windows: Int
    }

    /// Tone at (approximately) `frequency`, over consecutive windows from
    /// `start` to the end of `x`.
    static func fit(_ x: [Float], from start: Int, windowSize: Int, frequency: Double, sampleRate fs: Double) -> ToneFit {
        let w = blackmanHarris(windowSize)
        var amps: [Double] = []
        var phases: [Double] = []
        var times: [Double] = []
        var s = start
        while s + windowSize <= x.count {
            let b = bin(x, start: s, window: w, frequency: frequency, sampleRate: fs)
            amps.append(b.amplitude)
            phases.append(b.phase)
            times.append((Double(s) + Double(windowSize) / 2) / fs)
            s += windowSize
        }
        guard !amps.isEmpty else { return ToneFit(amplitude: 0, amplitudeSpreadDB: 0, frequencyErrorHz: .nan, windows: 0) }
        // Unwrap and regress phase on time: slope / 2π = frequency error.
        var unwrapped = [phases[0]]
        for i in 1 ..< phases.count {
            var d = phases[i] - phases[i - 1]
            while d > .pi { d -= 2 * .pi }
            while d < -.pi { d += 2 * .pi }
            unwrapped.append(unwrapped[i - 1] + d)
        }
        var slope = 0.0
        if times.count >= 2 {
            let mt = times.reduce(0, +) / Double(times.count)
            let mp = unwrapped.reduce(0, +) / Double(unwrapped.count)
            var num = 0.0, den = 0.0
            for i in 0 ..< times.count {
                num += (times[i] - mt) * (unwrapped[i] - mp)
                den += (times[i] - mt) * (times[i] - mt)
            }
            slope = den > 0 ? num / den : 0
        }
        let mean = amps.reduce(0, +) / Double(amps.count)
        let lo = amps.min() ?? mean, hi = amps.max() ?? mean
        let spread = lo > 0 ? 20 * log10(hi / lo) : .infinity
        return ToneFit(amplitude: mean, amplitudeSpreadDB: spread, frequencyErrorHz: slope / (2 * .pi), windows: amps.count)
    }

    static func dB(_ x: Double) -> Double { x > 0 ? 20 * log10(x) : -400 }
}

extension Double {
    func f(_ digits: Int) -> String { String(format: "%.\(digits)f", self) }
}
