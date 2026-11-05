//
//  RTSupport.swift
//  EQtargets (macOS)
//
//  Small helpers shared by the render-thread DSP: transcendental-free log2 /
//  exp2 and a lock-free "peak since last read" cell.
//
//  WHY FAST MATH EXISTS HERE
//  ------------------------------------------------------------------
//  The render-thread rules (docs/ARCHITECTURE.md) forbid log/exp/pow per
//  sample. The ported iOS limiter needs a level→dB and a dB→gain conversion
//  per sample while it is limiting, so it uses these instead. They are not
//  "approximations" in any audible sense: both are accurate to ~1e-11 relative
//  (≈1e-10 dB), far below Float resolution, and cost a handful of multiplies.
//

import Foundation
import Synchronization

enum FastMath {
    /// log2(x) for finite x > 0.
    ///
    /// Splits x into 2^e · m with m folded into [√½, √2), then uses the
    /// atanh series log2(m) = (2/ln2)·(z + z³/3 + z⁵/5 + …), z = (m−1)/(m+1).
    /// |z| ≤ 0.1716, so the first omitted term is below 1e-12.
    ///
    /// Never traps: +∞ → 1024, 0 → −1075, NaN / negative → NaN. (Before this
    /// guard, +∞ overflowed the exponent fold and crashed the render thread —
    /// found by mutation-testing the chain's input sanitiser.)
    @inline(__always)
    static func log2(_ x: Double) -> Double {
        guard x.isFinite, x > 0 else { return x == .infinity ? 1_024 : (x == 0 ? -1_075 : .nan) }
        var e = x.exponent
        var m = x.significand                 // [1, 2)
        if m > 1.4142135623730951 { m *= 0.5; e += 1 }
        let z = (m - 1) / (m + 1)
        let z2 = z * z
        let series = z * (1 + z2 * (1.0 / 3 + z2 * (1.0 / 5 + z2 * (1.0 / 7 + z2 * (1.0 / 9 + z2 * (1.0 / 11))))))
        return Double(e) + series * 2.885_390_081_777_926_8   // 2 / ln 2
    }

    /// 2^y. Integer part goes straight into the exponent; the fractional part
    /// uses a 12-term Taylor series of e^(f·ln2) on [0, ln2) (error < 2e-12).
    /// Never traps: NaN → 1 (unity gain), ±∞ clamp to 2^±1000.
    @inline(__always)
    static func exp2(_ y: Double) -> Double {
        let yc = y.isNaN ? 0 : Swift.min(Swift.max(y, -1_000), 1_000)
        let n = yc.rounded(.down)
        let t = (yc - n) * 0.693_147_180_559_945_3
        let p = 1 + t * (1 + t * (1.0 / 2 + t * (1.0 / 6 + t * (1.0 / 24 + t * (1.0 / 120
            + t * (1.0 / 720 + t * (1.0 / 5_040 + t * (1.0 / 40_320 + t * (1.0 / 362_880
            + t * (1.0 / 3_628_800 + t * (1.0 / 39_916_800)))))))))))
        return Double(sign: .plus, exponent: Int(n), significand: p)
    }

    /// 20·log10(x) for x > 0.
    @inline(__always)
    static func linearToDB(_ x: Double) -> Double {
        log2(x) * 6.020_599_913_279_624      // 20 · log10(2)
    }

    /// 10^(dB/20).
    @inline(__always)
    static func dbToLinear(_ db: Double) -> Double {
        exp2(db * 0.166_096_404_744_368_12)  // log2(10) / 20
    }
}

/// A gain / mix ramp with a C2-continuous shape (quintic "smootherstep").
///
/// WHY NOT LINEAR: a linear ramp has slope corners at both ends. On a tone the
/// corner is a step in the signal's derivative, which is broadband — measured
/// −58 dB re the tone above 8 kHz for a 10 ms bypass crossfade, −74 dB for a
/// 20 ms mute. Smootherstep has zero first AND second derivative at both ends,
/// which pushes those artefacts below −100 dB for the same ramp length, at the
/// cost of a few multiplies per sample — only while a ramp is running.
///
/// Render-thread value type: copy it into a local, advance it per sample, store
/// it back. Every channel of a block walks an identical copy, so they stay
/// sample-identical.
struct SmoothRamp {
    private(set) var value: Double
    private var from: Double
    private(set) var goal: Double
    private var progress: Double = 1
    private var step: Double = 0

    init(_ v: Double) { value = v; from = v; goal = v }

    var isSettled: Bool { progress >= 1 }

    /// Samples until the ramp lands (≥ 1 while running, 0 when settled).
    var remainingSamples: Int {
        progress >= 1 ? 0 : max(1, Int(((1 - progress) / step).rounded(.up)))
    }

    /// Start a ramp from wherever the value is now. `samples == 0` jumps.
    mutating func retarget(_ newGoal: Double, samples: Int) {
        guard newGoal != goal else { return }
        goal = newGoal
        from = value
        if samples <= 0 {
            value = newGoal
            progress = 1
        } else {
            progress = 0
            step = 1 / Double(samples)
        }
    }

    /// Jump to the goal (prepare / reset).
    mutating func settle() { value = goal; from = goal; progress = 1 }

    /// Value for the next sample.
    @inline(__always)
    mutating func next() -> Double {
        if progress < 1 {
            progress += step
            if progress >= 1 {
                progress = 1
                value = goal
            } else {
                let p = progress
                value = from + (goal - from) * (p * p * p * (p * (p * 6 - 15) + 10))
            }
        }
        return value
    }
}

/// A non-negative Double the render thread can raise and any thread can read
/// and clear, lock-free.
///
/// Non-negative IEEE-754 doubles order exactly like their bit patterns read as
/// unsigned integers, so "raise to at least x" is one atomic integer `max` —
/// no compare-and-swap loop on the render thread.
final class AtomicPeak: @unchecked Sendable {
    private let bits = Atomic<UInt64>(0)

    /// Render thread. `value` must be ≥ 0 and finite.
    @inline(__always)
    func raise(to value: Double) {
        guard value > 0 else { return }
        bits.max(value.bitPattern, ordering: .relaxed)
    }

    /// Any thread: returns the peak since the previous `take` and clears it.
    func take() -> Double {
        Double(bitPattern: bits.exchange(0, ordering: .relaxed))
    }

    func store(_ value: Double) {
        bits.store(max(0, value).bitPattern, ordering: .relaxed)
    }

    func load() -> Double {
        Double(bitPattern: bits.load(ordering: .relaxed))
    }
}
