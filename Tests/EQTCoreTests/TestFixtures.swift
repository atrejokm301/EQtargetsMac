//
//  TestFixtures.swift
//  EQTCoreTests
//
//  Shared builders + reference measurement helpers. Ported from the iOS suite
//  (EQtargetsMusicTests/TestFixtures.swift: RefBiquad, kWeightDB, bestOf) plus
//  the Mac additions: signal analysis (least-squares sine fit, DFT tone level,
//  8th-order high-pass for click detection), a seeded RNG, and a fake ring
//  writer with a deterministic two-clock simulator for RingReader.
//
//  The measurement helpers are deliberately re-derived from first principles
//  rather than shared with the app: a suite that validates code against that
//  code's own helper cannot catch a bug in the helper.
//

import Foundation
import XCTest

// MARK: - RNG

/// Deterministic generator so every "random" test input is reproducible.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

enum Fixtures {

    // MARK: - Reference DSP (independent of the app's implementation)

    /// RBJ biquad magnitude, written from the cookbook rather than reusing EQBiquad.
    struct RefBiquad {
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a0 = 1.0, a1 = 0.0, a2 = 0.0
        enum Kind { case peak, lowShelf, highShelf, highPass }

        init(_ kind: Kind, frequency: Double, gainDB: Double, q: Double, sampleRate: Double = 48_000) {
            let A = pow(10, gainDB / 40)
            let w0 = 2 * .pi * frequency / sampleRate
            let c = cos(w0), s = sin(w0)
            let alpha = s / (2 * max(q, 0.05))
            switch kind {
            case .peak:
                b0 = 1 + alpha * A; b1 = -2 * c; b2 = 1 - alpha * A
                a0 = 1 + alpha / A; a1 = -2 * c; a2 = 1 - alpha / A
            case .lowShelf:
                let t = 2 * sqrt(A) * alpha
                b0 = A * ((A + 1) - (A - 1) * c + t)
                b1 = 2 * A * ((A - 1) - (A + 1) * c)
                b2 = A * ((A + 1) - (A - 1) * c - t)
                a0 = (A + 1) + (A - 1) * c + t
                a1 = -2 * ((A - 1) + (A + 1) * c)
                a2 = (A + 1) + (A - 1) * c - t
            case .highShelf:
                let t = 2 * sqrt(A) * alpha
                b0 = A * ((A + 1) + (A - 1) * c + t)
                b1 = -2 * A * ((A - 1) + (A + 1) * c)
                b2 = A * ((A + 1) + (A - 1) * c - t)
                a0 = (A + 1) - (A - 1) * c + t
                a1 = 2 * ((A - 1) - (A + 1) * c)
                a2 = (A + 1) - (A - 1) * c - t
            case .highPass:
                b0 = (1 + c) / 2; b1 = -(1 + c); b2 = (1 + c) / 2
                a0 = 1 + alpha;   a1 = -2 * c;   a2 = 1 - alpha
            }
        }

        init(type: EQFilterType, frequency: Double, gainDB: Double, q: Double, sampleRate: Double = 48_000) {
            let kind: Kind
            switch type {
            case .peak: kind = .peak
            case .lowShelf: kind = .lowShelf
            case .highShelf: kind = .highShelf
            }
            self.init(kind, frequency: frequency, gainDB: gainDB, q: q, sampleRate: sampleRate)
        }

        func magnitudeDB(at f: Double, sampleRate: Double = 48_000) -> Double {
            let w = 2 * Double.pi * f / sampleRate
            let cw = cos(w), c2w = cos(2 * w), sw = sin(w), s2w = sin(2 * w)
            let nRe = b0 + b1 * cw + b2 * c2w, nIm = -(b1 * sw + b2 * s2w)
            let dRe = a0 + a1 * cw + a2 * c2w, dIm = -(a1 * sw + a2 * s2w)
            let n2 = nRe * nRe + nIm * nIm, d2 = dRe * dRe + dIm * dIm
            guard d2 > 1e-30, n2 > 0 else { return 0 }
            return 10 * log10(n2 / d2)
        }

        /// Filter a signal (direct form I, Double) — used by the HP click detector.
        func filter(_ x: [Double]) -> [Double] {
            var y = [Double](repeating: 0, count: x.count)
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            for i in x.indices {
                let v = (b0 * x[i] + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2) / a0
                x2 = x1; x1 = x[i]; y2 = y1; y1 = v
                y[i] = v
            }
            return y
        }
    }

    /// ITU-R BS.1770 K-weighting, re-derived from the spec.
    static func kWeightDB(_ f: Double, sampleRate: Double = 48_000) -> Double {
        let shelf = RefBiquad(.highShelf, frequency: 1_681.97, gainDB: 3.999, q: 0.7071, sampleRate: sampleRate)
        let hp = RefBiquad(.highPass, frequency: 38.13, gainDB: 0, q: 0.5003, sampleRate: sampleRate)
        return shelf.magnitudeDB(at: f, sampleRate: sampleRate) + hp.magnitudeDB(at: f, sampleRate: sampleRate)
    }

    // MARK: - Timing

    /// Best of N — a microbenchmark on a shared machine measures contention,
    /// not regressions. The minimum is the least-disturbed sample.
    static func bestOf(_ n: Int, _ body: () -> Void) -> TimeInterval {
        var best = TimeInterval.infinity
        for _ in 0 ..< n {
            let t0 = DispatchTime.now().uptimeNanoseconds
            body()
            let dt = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
            best = min(best, dt)
        }
        return best
    }

    static var isOptimizedBuild: Bool {
        #if DEBUG
        return false
        #else
        return true
        #endif
    }

    // MARK: - Signals

    static func sine(_ amp: Double, _ hz: Double, _ n: Int, sampleRate: Double = 48_000, phase: Double = 0) -> [Float] {
        (0 ..< n).map { Float(amp * sin(2 * .pi * hz * Double($0) / sampleRate + phase)) }
    }

    static func peak(_ b: ArraySlice<Float>) -> Double {
        b.reduce(0.0) { max($0, abs(Double($1))) }
    }

    static func peak(_ b: [Float]) -> Double { peak(b[...]) }

    static func rms(_ b: ArraySlice<Float>) -> Double {
        guard !b.isEmpty else { return 0 }
        return (b.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(b.count)).squareRoot()
    }

    static func db(_ x: Double) -> Double { 20 * log10(max(x, 1e-30)) }

    // MARK: - Analysis

    struct SineFit {
        var amplitude: Double
        var phase: Double
        var dc: Double
        var residualRMS: Double
        /// Residual (everything that is not the fitted sine) relative to the
        /// sine's RMS — THD+N.
        var thdPlusNoiseDB: Double { db(residualRMS / (amplitude / 2.0.squareRoot())) }
    }

    /// Least-squares fit of a·cos(ωn) + b·sin(ωn) + c at a KNOWN frequency
    /// (cycles per sample) over `range`. Exact for any window length (solves the
    /// 3×3 normal equations rather than assuming orthogonality).
    static func fitSine<C: RandomAccessCollection>(_ x: C, cyclesPerSample nu: Double) -> SineFit
    where C.Element == Float, C.Index == Int {
        let w = 2 * Double.pi * nu
        var scc = 0.0, sss = 0.0, scs = 0.0, sc = 0.0, ss = 0.0, s1 = 0.0
        var sxc = 0.0, sxs = 0.0, sx = 0.0
        let start = x.startIndex
        for i in x.indices {
            let n = Double(i - start)
            let c = cos(w * n), s = sin(w * n)
            let v = Double(x[i])
            scc += c * c; sss += s * s; scs += c * s; sc += c; ss += s; s1 += 1
            sxc += v * c; sxs += v * s; sx += v
        }
        // Solve [[scc scs sc][scs sss ss][sc ss s1]] · [a b d] = [sxc sxs sx]
        let m = [[scc, scs, sc], [scs, sss, ss], [sc, ss, s1]]
        let r = [sxc, sxs, sx]
        func det3(_ a: [[Double]]) -> Double {
            a[0][0] * (a[1][1] * a[2][2] - a[1][2] * a[2][1])
                - a[0][1] * (a[1][0] * a[2][2] - a[1][2] * a[2][0])
                + a[0][2] * (a[1][0] * a[2][1] - a[1][1] * a[2][0])
        }
        let d = det3(m)
        func solve(_ col: Int) -> Double {
            var t = m
            for row in 0 ..< 3 { t[row][col] = r[row] }
            return det3(t) / d
        }
        let a = solve(0), b = solve(1), dc = solve(2)
        var res = 0.0
        for i in x.indices {
            let n = Double(i - start)
            let e = Double(x[i]) - (a * cos(w * n) + b * sin(w * n) + dc)
            res += e * e
        }
        return SineFit(amplitude: (a * a + b * b).squareRoot(), phase: atan2(-b, a), dc: dc,
                       residualRMS: (res / Double(x.count)).squareRoot())
    }

    /// Least-squares sine fit with the frequency ALSO fitted (golden-section
    /// search within ±`spanPPM` of `nominal`). Separates a constant pitch
    /// offset (returned in ppm) from genuine distortion + noise, which a
    /// fixed-frequency fit lumps together.
    static func fitSineFreeFrequency(_ x: [Float], nominal: Double, spanPPM: Double = 500)
        -> (fit: SineFit, offsetPPM: Double) {
        var lo = nominal * (1 - spanPPM * 1e-6), hi = nominal * (1 + spanPPM * 1e-6)
        let g = (5.0.squareRoot() - 1) / 2
        var a = hi - g * (hi - lo), b = lo + g * (hi - lo)
        var fa = fitSine(x, cyclesPerSample: a).residualRMS
        var fb = fitSine(x, cyclesPerSample: b).residualRMS
        for _ in 0 ..< 30 {
            if fa < fb { hi = b; b = a; fb = fa; a = hi - g * (hi - lo); fa = fitSine(x, cyclesPerSample: a).residualRMS }
            else { lo = a; a = b; fa = fb; b = lo + g * (hi - lo); fb = fitSine(x, cyclesPerSample: b).residualRMS }
        }
        let nu = (lo + hi) / 2
        return (fitSine(x, cyclesPerSample: nu), (nu / nominal - 1) * 1e6)
    }

    /// Amplitude of a tone via a single DFT bin (Hann window). For tones well
    /// separated from others; used to read spurious components (aliases).
    static func toneAmplitude<C: RandomAccessCollection>(_ x: C, cyclesPerSample nu: Double) -> Double
    where C.Element == Float, C.Index == Int {
        let n = x.count
        var re = 0.0, im = 0.0, wsum = 0.0
        let start = x.startIndex
        for i in x.indices {
            let k = Double(i - start)
            let win = 0.5 - 0.5 * cos(2 * .pi * k / Double(n - 1))
            let v = Double(x[i]) * win
            re += v * cos(2 * .pi * nu * k)
            im -= v * sin(2 * .pi * nu * k)
            wsum += win
        }
        return 2 * (re * re + im * im).squareRoot() / wsum
    }

    /// 8th-order Butterworth high-pass (4 cascaded RBJ sections, Butterworth Qs).
    /// At 8 kHz it is ~190 dB down at 500 Hz, so a clean low tone leaves nothing
    /// and any click / zipper (broadband by nature) shows up undiluted.
    static func highPass8(_ x: [Float], cutoff: Double, sampleRate: Double = 48_000) -> [Double] {
        var y = x.map(Double.init)
        for q in [0.5098, 0.6013, 0.9000, 2.5629] {
            y = RefBiquad(.highPass, frequency: cutoff, gainDB: 0, q: q, sampleRate: sampleRate).filter(y)
        }
        return y
    }

    /// Peak broadband (≥ cutoff) content of `x` relative to `reference` level,
    /// in dB, skipping the first `skip` samples (filter start-up).
    static func clickLevelDB(_ x: [Float], reference: Double, skip: Int = 2_000,
                             cutoff: Double = 8_000, sampleRate: Double = 48_000) -> Double {
        let h = highPass8(x, cutoff: cutoff, sampleRate: sampleRate)
        let p = h[skip...].reduce(0.0) { max($0, abs($1)) }
        return db(p / reference)
    }
}

// MARK: - Multi-channel buffer helper

/// Planar Float buffers with a stable channel-pointer table, so tests can hand
/// `UnsafeMutableBufferPointer<UnsafeMutablePointer<Float>>` to the DSP.
final class PlanarBuffer {
    let channels: Int
    let frames: Int
    let data: UnsafeMutablePointer<Float>
    let table: UnsafeMutablePointer<UnsafeMutablePointer<Float>>

    init(channels: Int, frames: Int) {
        self.channels = channels
        self.frames = frames
        data = .allocate(capacity: channels * frames)
        data.initialize(repeating: 0, count: channels * frames)
        table = .allocate(capacity: channels)
        for ch in 0 ..< channels { (table + ch).initialize(to: data + ch * frames) }
    }

    deinit {
        data.deallocate()
        table.deallocate()
    }

    var pointers: UnsafeMutableBufferPointer<UnsafeMutablePointer<Float>> {
        UnsafeMutableBufferPointer(start: table, count: channels)
    }

    func channel(_ ch: Int) -> UnsafeMutablePointer<Float> { data + ch * frames }

    func load(_ ch: Int, from src: [Float], offset: Int, count: Int) {
        let d = channel(ch)
        for i in 0 ..< count { d[i] = offset + i < src.count ? src[offset + i] : 0 }
    }

    func store(_ ch: Int, into dst: inout [Float], count: Int) {
        let d = channel(ch)
        for i in 0 ..< count { dst.append(d[i]) }
    }
}

extension ProcessingChain {
    /// Run whole planar signals through the chain in `block`-sized calls.
    func run(_ input: [[Float]], block: Int = 512, between: ((Int) -> Void)? = nil) -> [[Float]] {
        let chs = input.count
        let n = input[0].count
        let buf = PlanarBuffer(channels: chs, frames: block)
        var out = [[Float]](repeating: [], count: chs)
        for ch in 0 ..< chs { out[ch].reserveCapacity(n) }
        var off = 0
        var blockIndex = 0
        while off < n {
            between?(blockIndex)
            let m = min(block, n - off)
            for ch in 0 ..< chs { buf.load(ch, from: input[ch], offset: off, count: m) }
            process(UnsafeMutableBufferPointer(start: buf.table, count: chs), frameCount: m)
            for ch in 0 ..< chs { buf.store(ch, into: &out[ch], count: m) }
            off += m
            blockIndex += 1
        }
        return out
    }
}

// MARK: - Fake ring writer (driver side of Shared/EQTRingProtocol.h)

/// Implements the WRITER half of the ring protocol in plain allocated memory.
final class FakeRingWriter {
    let raw: UnsafeMutableRawPointer
    let header: UnsafeMutablePointer<EQTRingHeader>
    let samples: UnsafeMutablePointer<Float>
    private(set) var frame: Int64 = 0        // next absolute frame of this generation
    /// Writer-side running sample counter (continuous across generations) so
    /// the test signal's phase never jumps.
    private(set) var signalFrame: Int64 = 0
    var signal: (Int64) -> (Float, Float)
    var sampleRate: Double

    init(sampleRate: Double, signal: @escaping (Int64) -> (Float, Float)) {
        self.sampleRate = sampleRate
        self.signal = signal
        let bytes = Int(EQTRingTotalBytes())
        raw = .allocate(byteCount: bytes, alignment: 64)
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: bytes)
        header = raw.bindMemory(to: EQTRingHeader.self, capacity: 1)
        samples = EQTRingSamples(header)
        header.pointee.version = EQT_RING_VERSION
        header.pointee.channels = EQT_RING_CHANNELS
        header.pointee.capacityFrames = EQT_RING_CAPACITY_FRAMES
        header.pointee.headerBytes = EQT_RING_HEADER_BYTES
        EQTRingStoreSampleRate(header, sampleRate)
        EQTRingStoreMagic(header, EQT_RING_MAGIC)
    }

    deinit { raw.deallocate() }

    var readOnlyHeader: UnsafePointer<EQTRingHeader> { UnsafePointer(header) }

    /// StartIO (first client) or a sample-rate change.
    func startIO(sampleRate newRate: Double? = nil) {
        if let newRate { sampleRate = newRate; EQTRingStoreSampleRate(header, newRate) }
        EQTRingBumpGeneration(header)
        EQTRingStoreWriteHead(header, 0)
        frame = 0
        EQTRingStoreIORunning(header, 1)
    }

    func stopIO() { EQTRingStoreIORunning(header, 0) }

    /// WriteMix of `n` frames starting at generation frame `at` (default: the
    /// current head), stamped `hostTime`. Writer rule 1: a gap is zero-filled
    /// (at most `capacity` frames) so a skipped IO cycle reads as silence.
    func write(frames n: Int, hostTime: UInt64, at start: Int64? = nil) {
        let cap = Int64(EQT_RING_CAPACITY_FRAMES)
        let t = start ?? frame
        if t > frame {
            let gap = t - frame
            var f = max(frame, t - cap)
            while f < t {
                let slot = Int(f & (cap - 1))
                samples[slot * 2] = 0
                samples[slot * 2 + 1] = 0
                f += 1
            }
            signalFrame += gap
            frame = t
        }
        for i in 0 ..< n {
            let f = frame + Int64(i)
            let (l, r) = signal(signalFrame + Int64(i))
            let slot = Int(f & (cap - 1))
            samples[slot * 2] = l
            samples[slot * 2 + 1] = r
        }
        frame += Int64(n)
        signalFrame += Int64(n)
        EQTRingStoreIOBufferFrames(header, UInt32(n))
        EQTRingStoreWriteHead(header, frame)
        EQTRingStoreLastWriteHostTime(header, hostTime)
    }
}

/// Deterministic two-clock simulation: a driver writing `writerBlock` frames
/// on a clock that runs `driftPPM` fast, and a RingReader rendering
/// `readerBlock` frames on the reference clock. Host time is simulated.
final class RingSimulation {
    let writer: FakeRingWriter
    let reader: RingReader
    let clock: UnsafeMutablePointer<UInt64>
    var outputRate: Double
    var readerBlock: Int
    var writerBlock: Int
    var driftPPM: Double
    /// Max IO-thread wake-up jitter applied to each write (seconds).
    var jitterSeconds: Double
    var writerEnabled = true
    var readerEnabled = true
    var rng = SplitMix64(seed: 7)

    private(set) var time = 0.0
    private var nextWrite = 0.0
    private var nominalWrite = 0.0
    private var nextRead = 0.0
    private var writeIndex: Int64 = 0
    private var readIndex: Int64 = 0
    /// The writer's own sample clock in the current generation. It keeps
    /// running while `writerEnabled` is false (an IO thread that is not being
    /// scheduled), so the next write lands later and zero-fills the gap.
    private var writerClockFrame: Int64 = 0
    private let out: PlanarBuffer
    var left: [Float] = []
    var right: [Float] = []
    var keepAudio = true

    init(sourceRate: Double, outputRate: Double, writerBlock: Int = 512, readerBlock: Int = 512,
         driftPPM: Double = 0, jitterSeconds: Double = 50e-6,
         signal: @escaping (Int64) -> (Float, Float)) {
        writer = FakeRingWriter(sampleRate: sourceRate, signal: signal)
        reader = RingReader(header: writer.readOnlyHeader)
        clock = .allocate(capacity: 1)
        clock.initialize(to: 1_000_000)
        reader.hostClockOverride = clock
        self.outputRate = outputRate
        self.readerBlock = readerBlock
        self.writerBlock = writerBlock
        self.driftPPM = driftPPM
        self.jitterSeconds = jitterSeconds
        out = PlanarBuffer(channels: 2, frames: 8_192)
        reader.configure(outputSampleRate: outputRate, outputMaxFrames: 4_096, outputBufferFrames: readerBlock)
        writer.startIO()
        nextWrite = 0
        nextRead = 0.0005
    }

    deinit { clock.deallocate() }

    /// Driver StartIO / sample-rate change: new generation, head back to 0.
    func startIO(sampleRate: Double? = nil, writerBlock newBlock: Int? = nil) {
        if let newBlock { writerBlock = newBlock }
        writer.startIO(sampleRate: sampleRate)
        writerClockFrame = 0
        writerEnabled = true
    }

    /// Driver StopIO: ioRunning = 0 and no more writes.
    func stopIO() {
        writer.stopIO()
        writerEnabled = false
    }

    private func ticks(_ t: Double) -> UInt64 { UInt64(1_000_000 + t * RingReader.hostTicksPerSecond) }

    /// Advance simulated time by `seconds`, calling `onRender` after each render.
    func run(seconds: Double, onRender: ((RingReaderStats, Bool) -> Void)? = nil) {
        let end = time + seconds
        let writerPeriod = Double(writerBlock) / (writer.sampleRate * (1 + driftPPM * 1e-6))
        let readerPeriod = Double(readerBlock) / outputRate
        while true {
            let tw = nextWrite, tr = nextRead
            let t = min(tw, tr)
            if t > end { break }
            time = t
            if tw <= tr {
                writeIndex += 1
                // Wake-up jitter delays the write within its period, never
                // reorders; the nominal schedule itself is incremental so a
                // rate change between runs continues seamlessly.
                nominalWrite += writerPeriod
                nextWrite = nominalWrite + Double.random(in: 0 ... jitterSeconds, using: &rng)
                let at = writerClockFrame
                writerClockFrame += Int64(writerBlock)
                if writerEnabled {
                    clock.pointee = ticks(t)
                    writer.write(frames: writerBlock, hostTime: ticks(t), at: at)
                }
            } else {
                readIndex += 1
                nextRead = 0.0005 + Double(readIndex) * readerPeriod
                if readerEnabled {
                    clock.pointee = ticks(t)
                    let got = reader.render(into: out.pointers, frameCount: readerBlock)
                    if keepAudio {
                        out.store(0, into: &left, count: readerBlock)
                        out.store(1, into: &right, count: readerBlock)
                    }
                    onRender?(reader.stats(), got)
                }
            }
        }
        time = end
    }
}
