//
//  PEQProcessor.swift
//  EQtargets (macOS)
//
//  One parametric EQ layer as it runs on the render thread: a preamp plus a
//  fixed number of RBJ biquad sections (Target and Fine-Tune use 10, the Bass
//  Style static shape uses 4), any channel count, transposed direct form II
//  with Double state.
//
//  GRAPH == DSP
//  ------------------------------------------------------------------
//  Coefficients come from `EQBiquad` — the exact struct the frequency-response
//  plot evaluates — divided through by a0. There is no second formula to drift.
//  They are computed on the main thread (ProcessingChain.setParameters); this
//  file only ever moves between coefficient sets it was handed.
//
//  WHY COEFFICIENTS GLIDE, AND WHY LINEARLY
//  ------------------------------------------------------------------
//  The UI updates a dragged band ~60×/s. Switching a biquad's coefficients
//  instantly leaves its state variables describing a different filter, and the
//  mismatch comes out as a click (or, repeated at 60 Hz, as zipper noise).
//  Recomputing the RBJ formulas per sample would cost sin/cos/pow on the render
//  thread, which the rules forbid. So each section walks from its current
//  coefficients to the new ones in equal per-sample steps over `glideSamples`
//  (20 ms by default) — a few adds per sample, only while a glide runs.
//
//  Stability during a glide is guaranteed, not hoped for: a 2nd-order
//  denominator 1 + a1 z⁻¹ + a2 z⁻² is stable iff (a1, a2) lies inside the
//  triangle |a2| < 1, |a1| < 1 + a2. That triangle is convex, so every point on
//  the straight line between two stable filters is stable. A new target that
//  arrives mid-glide starts from the current point, which is itself on such a
//  line, so the argument holds for any sequence of drags.
//
//  SWITCHING A BAND OFF (and skipping idle bands)
//  ------------------------------------------------------------------
//  A disabled / 0 dB band becomes the identity *with its current poles*:
//  b = a, so only the zeros move — the peak shrinks into the flat line at the
//  same frequency instead of morphing through an unrelated filter. Once the
//  glide has finished and the leftover state has decayed below 1e-10 the
//  section is dropped from processing entirely, so a flat layer costs nothing
//  and is bit-exact passthrough. Turning a band on starts from that identity,
//  so it fades in rather than switching in.
//

import Foundation

// MARK: - Coefficients

/// Biquad coefficients normalised by a0:
///   y[n] = b0·x[n] + b1·x[n−1] + b2·x[n−2] − a1·y[n−1] − a2·y[n−2]
struct BiquadCoefficients: Equatable {
    var b0: Double = 1
    var b1: Double = 0
    var b2: Double = 0
    var a1: Double = 0
    var a2: Double = 0

    static let identity = BiquadCoefficients()

    init() {}

    init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
    }

    /// The graph's own RBJ math (`EQBiquad`), normalised by a0.
    init(_ q: EQBiquad) {
        let inv = 1 / q.a0
        b0 = q.b0 * inv
        b1 = q.b1 * inv
        b2 = q.b2 * inv
        a1 = q.a1 * inv
        a2 = q.a2 * inv
    }

    init(type: EQFilterType, frequency: Double, gainDB: Double, q: Double, sampleRate: Double) {
        self.init(EQBiquad(type: type, frequency: frequency, gainDB: gainDB, q: q, sampleRate: sampleRate))
    }

    var isFinite: Bool {
        b0.isFinite && b1.isFinite && b2.isFinite && a1.isFinite && a2.isFinite
    }

    /// Poles strictly inside the unit circle (the stability triangle).
    var isStable: Bool {
        abs(a2) < 1 && abs(a1) < 1 + a2
    }
}

/// What the main thread asks one section to become.
struct PEQSectionTarget: Equatable {
    /// True → unity passthrough (band disabled, 0 dB, or layer bypassed).
    var isIdentity: Bool = true
    var coefficients: BiquadCoefficients = .identity

    static let identity = PEQSectionTarget()

    static func filter(_ c: BiquadCoefficients) -> PEQSectionTarget {
        PEQSectionTarget(isIdentity: false, coefficients: c)
    }
}

// MARK: - Processor

/// Preamp + N gliding biquad sections over planar Double buffers.
///
/// Threading: created / `snapToTargets` / `reset` off the render thread (or on
/// it, between blocks); `setTarget`, `setGain`, `process` on the render thread.
/// Nothing in the render path allocates, locks or touches a Swift array.
final class PEQProcessor {

    let sectionCount: Int
    private(set) var channelCount: Int
    /// Glide length in samples. 0 = switch instantly (used by tests as a
    /// negative control to prove the glide is what removes the click).
    private(set) var glideSamples: Int

    private static let words = 5   // b0 b1 b2 a1 a2

    private let current: UnsafeMutablePointer<Double>   // coefficients in force
    private let step: UnsafeMutablePointer<Double>      // per-sample increment while gliding
    private let goal: UnsafeMutablePointer<Double>      // where the glide ends
    private let glideLeft: UnsafeMutablePointer<Int>
    private let running: UnsafeMutablePointer<Bool>     // must be processed
    private let goalIsIdentity: UnsafeMutablePointer<Bool>
    /// Filter memory, [section][channel][s1, s2].
    private var memory: UnsafeMutablePointer<Double>

    /// Preamp. Ramps with a C2-continuous shape (see `SmoothRamp`).
    private var gain = SmoothRamp(1)

    /// Below this the leftover state of an identity section is dropped
    /// (−200 dBFS — far under Float resolution of any audible signal).
    private static let idleStateFloor = 1e-10
    /// Denormal guard for decaying state (flushed once per block).
    private static let denormalFloor = 1e-30

    init(sectionCount: Int, channelCount: Int, glideSamples: Int) {
        self.sectionCount = max(0, sectionCount)
        self.channelCount = max(1, channelCount)
        self.glideSamples = max(0, glideSamples)
        let w = Self.words * max(1, self.sectionCount)
        current = .allocate(capacity: w)
        step = .allocate(capacity: w)
        goal = .allocate(capacity: w)
        glideLeft = .allocate(capacity: max(1, self.sectionCount))
        running = .allocate(capacity: max(1, self.sectionCount))
        goalIsIdentity = .allocate(capacity: max(1, self.sectionCount))
        let m = max(1, self.sectionCount) * self.channelCount * 2
        memory = .allocate(capacity: m)
        memory.initialize(repeating: 0, count: m)
        step.initialize(repeating: 0, count: w)
        resetToIdentity()
    }

    /// Non-RT. New format: (re)allocates filter memory if the channel count
    /// changed and returns every section to an idle identity. Lets the owner
    /// keep this object in a `let`, so the render thread never retains it.
    func configure(channelCount newChannels: Int, glideSamples newGlide: Int) {
        let n = max(1, newChannels)
        if n != channelCount {
            memory.deallocate()
            channelCount = n
            let m = max(1, sectionCount) * n * 2
            memory = .allocate(capacity: m)
            memory.initialize(repeating: 0, count: m)
        }
        glideSamples = max(0, newGlide)
        resetToIdentity()
    }

    private func resetToIdentity() {
        for s in 0 ..< max(1, sectionCount) {
            let c = current + s * Self.words, g = goal + s * Self.words
            c[0] = 1; c[1] = 0; c[2] = 0; c[3] = 0; c[4] = 0
            g[0] = 1; g[1] = 0; g[2] = 0; g[3] = 0; g[4] = 0
            glideLeft[s] = 0
            running[s] = false
            goalIsIdentity[s] = true
        }
        gain = SmoothRamp(1)
        clearMemory()
    }

    deinit {
        current.deallocate(); step.deallocate(); goal.deallocate()
        glideLeft.deallocate(); running.deallocate(); goalIsIdentity.deallocate()
        memory.deallocate()
    }

    // MARK: Targets

    /// Render thread. Starts a glide toward `target` (no-op if unchanged).
    func setTarget(_ s: Int, _ target: PEQSectionTarget) {
        guard s >= 0, s < sectionCount else { return }
        let g = goal + s * Self.words
        let c = current + s * Self.words

        if target.isIdentity {
            // Already heading for (or sitting at) unity: keep that glide.
            if goalIsIdentity[s] { return }
            // Identity with the CURRENT poles: only the zeros move.
            g[0] = 1; g[1] = c[3]; g[2] = c[4]; g[3] = c[3]; g[4] = c[4]
            goalIsIdentity[s] = true
        } else {
            let k = target.coefficients
            if !goalIsIdentity[s], g[0] == k.b0, g[1] == k.b1, g[2] == k.b2, g[3] == k.a1, g[4] == k.a2 {
                return
            }
            g[0] = k.b0; g[1] = k.b1; g[2] = k.b2; g[3] = k.a1; g[4] = k.a2
            goalIsIdentity[s] = false
        }

        if glideSamples == 0 {
            for i in 0 ..< Self.words { c[i] = g[i] }
            glideLeft[s] = 0
        } else {
            let inv = 1.0 / Double(glideSamples)
            let d = step + s * Self.words
            for i in 0 ..< Self.words { d[i] = (g[i] - c[i]) * inv }
            glideLeft[s] = glideSamples
        }
        running[s] = true
    }

    /// Render thread. Linear gain the layer applies before its sections.
    func setGain(_ linear: Double) {
        gain.retarget(linear, samples: glideSamples)
    }

    /// Jump straight to the goals with clean state (prepare / hard reset).
    func snapToTargets() {
        for s in 0 ..< sectionCount {
            let c = current + s * Self.words, g = goal + s * Self.words
            for i in 0 ..< Self.words { c[i] = g[i] }
            glideLeft[s] = 0
            running[s] = !goalIsIdentity[s]
        }
        gain.settle()
        clearMemory()
    }

    /// Clear filter memory, finish any glide instantly.
    func reset() { snapToTargets() }

    private func clearMemory() {
        memory.update(repeating: 0, count: max(1, sectionCount) * channelCount * 2)
    }

    /// True when processing would leave the signal bit-for-bit unchanged.
    var isTransparent: Bool {
        if !gain.isSettled || gain.value != 1 { return false }
        for s in 0 ..< sectionCount where running[s] { return false }
        return true
    }

    /// False if any filter memory or coefficient went non-finite.
    var isFinite: Bool {
        guard gain.value.isFinite else { return false }
        for s in 0 ..< sectionCount where running[s] {
            let c = current + s * Self.words
            for i in 0 ..< Self.words where !c[i].isFinite { return false }
            let m = memory + s * channelCount * 2
            for i in 0 ..< channelCount * 2 where !m[i].isFinite { return false }
        }
        return true
    }

    /// Coefficients currently in force for section `s` (tests / diagnostics).
    func currentCoefficients(_ s: Int) -> BiquadCoefficients {
        let c = current + s * Self.words
        return BiquadCoefficients(b0: c[0], b1: c[1], b2: c[2], a1: c[3], a2: c[4])
    }

    func isRunning(_ s: Int) -> Bool { running[s] }

    // MARK: Processing

    /// Render thread. Processes `frames` samples of every channel in place.
    /// `buffers` holds `channelCount` planar Double buffers.
    func process(_ buffers: UnsafePointer<UnsafeMutablePointer<Double>>, frames n: Int) {
        guard n > 0 else { return }
        applyGain(buffers, n)
        for s in 0 ..< sectionCount where running[s] {
            runSection(s, buffers, n)
        }
    }

    private func applyGain(_ buffers: UnsafePointer<UnsafeMutablePointer<Double>>, _ n: Int) {
        if gain.isSettled {
            let g = gain.value
            guard g != 1 else { return }
            for ch in 0 ..< channelCount {
                let x = buffers[ch]
                for i in 0 ..< n { x[i] *= g }
            }
            return
        }
        var r = gain
        for ch in 0 ..< channelCount {
            r = gain
            let x = buffers[ch]
            for i in 0 ..< n { x[i] *= r.next() }
        }
        gain = r
    }

    private func runSection(_ s: Int, _ buffers: UnsafePointer<UnsafeMutablePointer<Double>>, _ n: Int) {
        let c = current + s * Self.words
        let mem = memory + s * channelCount * 2
        var done = 0

        let left = glideLeft[s]
        if left > 0 {
            let m = min(left, n)
            let d = step + s * Self.words
            // Every channel walks the identical coefficient trajectory from the
            // same start, so they stay bit-identical; commit it once at the end.
            var end = (c[0], c[1], c[2], c[3], c[4])
            var ch = 0
            while ch + 1 < channelCount {
                end = Self.glide2(buffers[ch], buffers[ch + 1], mem + ch * 2, mem + ch * 2 + 2,
                                  0, m, c, d)
                ch += 2
            }
            if ch < channelCount {
                end = Self.glide1(buffers[ch], mem + ch * 2, 0, m, c, d)
            }
            if left == m {
                // Glide finished: land exactly on the goal (no accumulated rounding).
                let g = goal + s * Self.words
                for i in 0 ..< Self.words { c[i] = g[i] }
            } else {
                c[0] = end.0; c[1] = end.1; c[2] = end.2; c[3] = end.3; c[4] = end.4
            }
            glideLeft[s] = left - m
            done = m
        }

        if done < n {
            let k = (c[0], c[1], c[2], c[3], c[4])
            var ch = 0
            while ch + 1 < channelCount {
                Self.static2(buffers[ch], buffers[ch + 1], mem + ch * 2, mem + ch * 2 + 2, done, n, k)
                ch += 2
            }
            if ch < channelCount {
                Self.static1(buffers[ch], mem + ch * 2, done, n, k)
            }
        }

        // Denormal guard, and retire an identity section once its tail is gone.
        var largest = 0.0
        for i in 0 ..< channelCount * 2 {
            let a = abs(mem[i])
            if a < Self.denormalFloor { mem[i] = 0 }
            if a > largest { largest = a }
        }
        if goalIsIdentity[s], glideLeft[s] == 0, largest < Self.idleStateFloor {
            for i in 0 ..< channelCount * 2 { mem[i] = 0 }
            running[s] = false
        }
    }

    // MARK: Kernels
    //
    // Two channels per loop: each channel's recursion is a serial chain of two
    // FMAs per sample, so running two independent chains side by side roughly
    // halves the latency-bound cost.

    @inline(__always)
    private static func static2(
        _ x: UnsafeMutablePointer<Double>, _ y: UnsafeMutablePointer<Double>,
        _ mx: UnsafeMutablePointer<Double>, _ my: UnsafeMutablePointer<Double>,
        _ from: Int, _ to: Int, _ k: (Double, Double, Double, Double, Double)
    ) {
        let (b0, b1, b2, a1, a2) = k
        var p1 = mx[0], p2 = mx[1], q1 = my[0], q2 = my[1]
        for i in from ..< to {
            let u = x[i], v = y[i]
            let yu = b0 * u + p1
            let yv = b0 * v + q1
            p1 = b1 * u - a1 * yu + p2
            q1 = b1 * v - a1 * yv + q2
            p2 = b2 * u - a2 * yu
            q2 = b2 * v - a2 * yv
            x[i] = yu
            y[i] = yv
        }
        mx[0] = p1; mx[1] = p2; my[0] = q1; my[1] = q2
    }

    @inline(__always)
    private static func static1(
        _ x: UnsafeMutablePointer<Double>, _ mx: UnsafeMutablePointer<Double>,
        _ from: Int, _ to: Int, _ k: (Double, Double, Double, Double, Double)
    ) {
        let (b0, b1, b2, a1, a2) = k
        var p1 = mx[0], p2 = mx[1]
        for i in from ..< to {
            let u = x[i]
            let yu = b0 * u + p1
            p1 = b1 * u - a1 * yu + p2
            p2 = b2 * u - a2 * yu
            x[i] = yu
        }
        mx[0] = p1; mx[1] = p2
    }

    @inline(__always)
    private static func glide2(
        _ x: UnsafeMutablePointer<Double>, _ y: UnsafeMutablePointer<Double>,
        _ mx: UnsafeMutablePointer<Double>, _ my: UnsafeMutablePointer<Double>,
        _ from: Int, _ to: Int,
        _ c: UnsafeMutablePointer<Double>, _ d: UnsafeMutablePointer<Double>
    ) -> (Double, Double, Double, Double, Double) {
        var b0 = c[0], b1 = c[1], b2 = c[2], a1 = c[3], a2 = c[4]
        let d0 = d[0], d1 = d[1], d2 = d[2], d3 = d[3], d4 = d[4]
        var p1 = mx[0], p2 = mx[1], q1 = my[0], q2 = my[1]
        for i in from ..< to {
            b0 += d0; b1 += d1; b2 += d2; a1 += d3; a2 += d4
            let u = x[i], v = y[i]
            let yu = b0 * u + p1
            let yv = b0 * v + q1
            p1 = b1 * u - a1 * yu + p2
            q1 = b1 * v - a1 * yv + q2
            p2 = b2 * u - a2 * yu
            q2 = b2 * v - a2 * yv
            x[i] = yu
            y[i] = yv
        }
        mx[0] = p1; mx[1] = p2; my[0] = q1; my[1] = q2
        return (b0, b1, b2, a1, a2)
    }

    @inline(__always)
    private static func glide1(
        _ x: UnsafeMutablePointer<Double>, _ mx: UnsafeMutablePointer<Double>,
        _ from: Int, _ to: Int,
        _ c: UnsafeMutablePointer<Double>, _ d: UnsafeMutablePointer<Double>
    ) -> (Double, Double, Double, Double, Double) {
        var b0 = c[0], b1 = c[1], b2 = c[2], a1 = c[3], a2 = c[4]
        let d0 = d[0], d1 = d[1], d2 = d[2], d3 = d[3], d4 = d[4]
        var p1 = mx[0], p2 = mx[1]
        for i in from ..< to {
            b0 += d0; b1 += d1; b2 += d2; a1 += d3; a2 += d4
            let u = x[i]
            let yu = b0 * u + p1
            p1 = b1 * u - a1 * yu + p2
            p2 = b2 * u - a2 * yu
            x[i] = yu
        }
        mx[0] = p1; mx[1] = p2
        return (b0, b1, b2, a1, a2)
    }
}
