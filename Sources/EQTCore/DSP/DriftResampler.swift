//
//  DriftResampler.swift
//  EQtargets (macOS)
//
//  Band-limited fractional resampler used by RingReader: it plays the driver's
//  ring at the output device's rate AND absorbs the clock drift between the two
//  devices (the PLL nudges `ratio` by up to ±1 %).
//
//  DESIGN
//  ------------------------------------------------------------------
//  Windowed sinc, Kaiser window (β = 10 → ~100 dB stopband), 32 taps at the
//  base rate, polyphase table with 1024 phases and linear interpolation
//  between adjacent phases. Every row is normalised to exactly unity DC gain.
//
//  Cutoff is defined against the LOWER of the two rates: passband to 0.4·fs,
//  stopband from 0.6·fs (−6 dB at Nyquist). For upsampling and ≈1:1 (the
//  normal case — the engine matches device rates, so the ratio is 1 ± drift)
//  the base table is used as-is. For downsampling by r > 1.02 the kernel is
//  stretched by r — cutoff 0.5/r and r× the taps — so the transition band
//  keeps its width relative to the OUTPUT rate and nothing above the output
//  Nyquist can fold back. Tables are built off the render thread (configure)
//  and cached process-wide; the render path only indexes them.
//
//  Measured (Tests/EQTCoreTests/DriftResamplerTests): passband, THD+N and
//  alias rejection targets — see those tests for the numbers.
//
//  WHY ROW + NEXT-ROW INTERPOLATION
//  ------------------------------------------------------------------
//  y = (1−α)·Σ x·h[j] + α·Σ x·h[j+1]. Interpolating between phases rather than
//  snapping to the nearest one turns the phase-quantisation error (which shows
//  up as noise on any drifting ratio) from first order into second order in
//  1/phases; at 1024 phases that is below the Float noise floor of the dot
//  products themselves.
//

import Foundation
import os

// MARK: - Table

/// One immutable polyphase kernel. Row j (0…phases) holds the taps for a
/// fractional position of j/phases; row `phases` equals row 0 advanced by one
/// source sample, which makes the "next row" lookup branch-free.
final class ResamplerTable: @unchecked Sendable {
    let taps: Int           // multiple of 8
    let phases: Int
    /// Cutoff in cycles per SOURCE sample (−6 dB point).
    let cutoff: Double
    let beta: Double
    /// (phases + 1) × taps Floats, 32-byte aligned.
    let coefficients: UnsafeMutablePointer<Float>

    static let baseTaps = 32
    static let defaultPhases = 1024
    static let kaiserBeta = 10.0

    init(taps: Int, phases: Int, cutoff: Double, beta: Double) {
        precondition(taps % 8 == 0 && taps >= 8 && phases >= 2)
        self.taps = taps
        self.phases = phases
        self.cutoff = cutoff
        self.beta = beta
        let count = (phases + 1) * taps
        let raw = UnsafeMutableRawPointer.allocate(byteCount: count * MemoryLayout<Float>.stride, alignment: 32)
        coefficients = raw.bindMemory(to: Float.self, capacity: count)

        let half = Double(taps) / 2
        let i0Beta = Self.besselI0(beta)
        var row = [Double](repeating: 0, count: taps)
        for j in 0 ... phases {
            let frac = Double(j) / Double(phases)
            var sum = 0.0
            for m in 0 ..< taps {
                // Distance from source tap m to the output position, in source samples.
                let t = frac + (half - 1) - Double(m)
                let x = 2 * cutoff * t
                let sinc = abs(x) < 1e-12 ? 1.0 : sin(Double.pi * x) / (Double.pi * x)
                let r = t / half
                let w = abs(r) >= 1 ? 0 : Self.besselI0(beta * (1 - r * r).squareRoot()) / i0Beta
                row[m] = 2 * cutoff * sinc * w
                sum += row[m]
            }
            // Exact unity DC gain for every phase: no gain ripple as the
            // fractional position sweeps, which a drifting ratio does constantly.
            let norm = sum != 0 ? 1 / sum : 1
            for m in 0 ..< taps {
                coefficients[j * taps + m] = Float(row[m] * norm)
            }
        }
    }

    deinit {
        UnsafeMutableRawPointer(coefficients).deallocate()
    }

    /// Zeroth-order modified Bessel function of the first kind (power series).
    static func besselI0(_ x: Double) -> Double {
        var sum = 1.0, term = 1.0
        let q = x * x / 4
        var k = 1.0
        while term > 1e-17 * sum {
            term *= q / (k * k)
            sum += term
            k += 1
        }
        return sum
    }

    // MARK: Selection + cache

    /// Table geometry for a nominal ratio (source frames per output frame).
    static func geometry(forRatio ratio: Double) -> (taps: Int, cutoff: Double) {
        guard ratio > 1.02 else { return (baseTaps, 0.5) }
        let taps = Int((Double(baseTaps) * ratio / 8).rounded(.up)) * 8
        return (taps, 0.5 / ratio)
    }

    private static let cacheLock = OSAllocatedUnfairLock<[String: ResamplerTable]>(initialState: [:])

    /// Process-wide cache: tables are immutable, so readers on any number of
    /// RingReaders (and tests) share them. Never call from the render thread.
    static func table(forRatio ratio: Double, phases: Int = defaultPhases) -> ResamplerTable {
        let g = geometry(forRatio: ratio)
        let key = "\(g.taps)|\(phases)|\(g.cutoff.bitPattern)"
        return cacheLock.withLock { cache in
            if let t = cache[key] { return t }
            let t = ResamplerTable(taps: g.taps, phases: phases, cutoff: g.cutoff, beta: kaiserBeta)
            cache[key] = t
            return t
        }
    }
}

// MARK: - Kernel

/// Plain-value view of a table for the render thread (no ARC).
struct ResamplerKernel {
    var coefficients: UnsafePointer<Float>
    var taps: Int
    var phases: Int

    init(_ table: ResamplerTable) {
        coefficients = UnsafePointer(table.coefficients)
        taps = table.taps
        phases = table.phases
    }

    /// Frames of history needed before / after the integer position.
    var before: Int { taps / 2 - 1 }
    var after: Int { taps / 2 }
}

enum DriftResampler {

    /// Render-thread kernel. Interpolates `count` output frames from planar
    /// source history.
    ///
    /// - Parameters:
    ///   - left/right: source planes; `right == nil` → mono source.
    ///   - index: integer source position (history index) of the first output.
    ///   - frac: fractional part, [0, 1).
    ///   - ratio: source frames advanced per output frame.
    ///   The taps for position p read history[floor(p) − before … floor(p) + after].
    /// - Returns: the integer index / fraction of the frame after the last one.
    @inline(__always)
    static func render(
        kernel k: ResamplerKernel,
        left: UnsafePointer<Float>, right: UnsafePointer<Float>?,
        index: Int, frac: Double, ratio: Double, count: Int,
        outLeft: UnsafeMutablePointer<Float>, outRight: UnsafeMutablePointer<Float>?
    ) -> (index: Int, frac: Double) {
        var idx = index
        var f = frac
        let taps = k.taps
        let chunks = taps / 8
        let phasesD = Double(k.phases)
        let table = UnsafeRawPointer(k.coefficients)
        let rowBytes = taps * MemoryLayout<Float>.stride
        let before = k.before

        for o in 0 ..< count {
            let ph = f * phasesD
            var j = Int(ph)
            if j >= k.phases { j = k.phases - 1 }
            let alpha = Float(ph - Double(j))
            let h0 = table + j * rowBytes
            let h1 = h0 + rowBytes
            let xl = UnsafeRawPointer(left + (idx - before))

            if let right, let outRight {
                let xr = UnsafeRawPointer(right + (idx - before))
                var l0 = SIMD8<Float>(), l1 = SIMD8<Float>(), r0 = SIMD8<Float>(), r1 = SIMD8<Float>()
                for c in 0 ..< chunks {
                    let off = c * 32
                    let a = h0.load(fromByteOffset: off, as: SIMD8<Float>.self)
                    let b = h1.load(fromByteOffset: off, as: SIMD8<Float>.self)
                    let vl = xl.loadUnaligned(fromByteOffset: off, as: SIMD8<Float>.self)
                    let vr = xr.loadUnaligned(fromByteOffset: off, as: SIMD8<Float>.self)
                    l0 += vl * a; l1 += vl * b
                    r0 += vr * a; r1 += vr * b
                }
                let sl0 = l0.sum(), sl1 = l1.sum(), sr0 = r0.sum(), sr1 = r1.sum()
                outLeft[o] = sl0 + alpha * (sl1 - sl0)
                outRight[o] = sr0 + alpha * (sr1 - sr0)
            } else {
                var l0 = SIMD8<Float>(), l1 = SIMD8<Float>()
                for c in 0 ..< chunks {
                    let off = c * 32
                    let a = h0.load(fromByteOffset: off, as: SIMD8<Float>.self)
                    let b = h1.load(fromByteOffset: off, as: SIMD8<Float>.self)
                    let vl = xl.loadUnaligned(fromByteOffset: off, as: SIMD8<Float>.self)
                    l0 += vl * a; l1 += vl * b
                }
                let sl0 = l0.sum(), sl1 = l1.sum()
                outLeft[o] = sl0 + alpha * (sl1 - sl0)
            }

            f += ratio
            let adv = Int(f)
            idx += adv
            f -= Double(adv)
        }
        return (idx, f)
    }

    /// Number of outputs (≤ `limit`) whose taps stay below history index
    /// `available` (exclusive), starting at (index, frac).
    @inline(__always)
    static func producible(kernel k: ResamplerKernel, index: Int, frac: Double, ratio: Double,
                           available: Int, limit: Int) -> Int {
        // Output j needs floor(index + frac + j·ratio) + after < available.
        let room = Double(available - k.after - index) - frac
        guard room > 0 else { return 0 }
        let n = Int((room / ratio).rounded(.up))
        return max(0, min(limit, n))
    }
}
