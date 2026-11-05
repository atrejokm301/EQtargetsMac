//
//  PerformanceTests.swift
//  EQTCoreTests
//
//  Render cost per 512-frame stereo buffer at 48 kHz (one buffer = 10 667 µs
//  of audio). Meaningful only in an optimized build:
//    xcodebuild … -scheme EQTCoreTests -configuration Release test
//  (the sources are compiled into the test bundle, so Release really is -O).
//  Debug (-Onone) runs print their numbers for reference but assert nothing.
//
//  Best-of-N timing: on a shared machine the minimum is the least-disturbed
//  sample; the median of a noisy run would measure the machine, not the code.
//

import XCTest

final class PerformanceTests: XCTestCase {

    private let frames = 512
    private let bufferMicros = 512.0 / 48_000 * 1e6

    private func fullParameters() throws -> ChainParameters {
        var p = ChainParameters()
        p.dual.target = try AutoEQParser.parse(text: Fixtures.airPodsMaxPreset)       // 10 bands
        var bands: [EQBand] = []
        for (i, f) in [40.0, 80, 160, 320, 640, 1_250, 2_500, 5_000, 10_000, 16_000].enumerated() {
            bands.append(EQBand(frequency: f, gain: i % 2 == 0 ? 3.5 : -2.5, q: 1.2,
                                filterType: i == 0 ? .lowShelf : (i == 9 ? .highShelf : .peak)))
        }
        p.dual.fineTune = EQLayerState(preamp: -3, bands: bands)                       // 10 bands
        p.bass.selectStyle(.sustainRumble)                                             // dynamic stage on
        p.bass.strength = 0.8
        p.bass.rumbleSustain = 0.6
        p.bass.rumbleSoften = 0.3
        p.outputProtection = true
        return p
    }

    private func programMaterial(_ n: Int) -> ([Float], [Float]) {
        var rng = SplitMix64(seed: 12)
        var l = [Float](repeating: 0, count: n), r = l
        for i in 0 ..< n {
            let t = Double(i) / 48_000
            let bass = 0.3 * sin(2 * .pi * 55 * t) * (0.6 + 0.4 * sin(2 * .pi * 2 * t))
            l[i] = Float(bass) + Float.random(in: -0.15 ... 0.15, using: &rng)
            r[i] = Float(bass) + Float.random(in: -0.15 ... 0.15, using: &rng)
        }
        return (l, r)
    }

    /// µs per 512-frame process() call, best of 7 runs of 400 calls.
    private func measureChain(_ chain: ProcessingChain, perBlock: ((Int) -> Void)? = nil) -> Double {
        let (l, r) = programMaterial(frames * 64)
        let buf = PlanarBuffer(channels: 2, frames: frames)
        var block = 0
        func step() {
            let off = (block % 64) * frames
            l.withUnsafeBufferPointer { buf.channel(0).update(from: $0.baseAddress! + off, count: frames) }
            r.withUnsafeBufferPointer { buf.channel(1).update(from: $0.baseAddress! + off, count: frames) }
            perBlock?(block)
            chain.process(buf.pointers, frameCount: frames)
            block += 1
        }
        for _ in 0 ..< 200 { step() }                // warm up, settle glides
        let calls = 400
        let total = Fixtures.bestOf(7) { for _ in 0 ..< calls { step() } }
        // Subtract the input copy (measured the same way) so only the DSP counts.
        let copyOnly = Fixtures.bestOf(7) {
            for i in 0 ..< calls {
                let off = (i % 64) * frames
                l.withUnsafeBufferPointer { buf.channel(0).update(from: $0.baseAddress! + off, count: frames) }
                r.withUnsafeBufferPointer { buf.channel(1).update(from: $0.baseAddress! + off, count: frames) }
            }
        }
        return max(0, total - copyOnly) / Double(calls) * 1e6
    }

    private func report(_ label: String, _ micros: Double) -> Double {
        let pct = micros / bufferMicros * 100
        print(String(format: "PERF [%@] %@: %.2f µs per 512-frame stereo buffer @ 48 kHz = %.3f %% of one core",
                     Fixtures.isOptimizedBuild ? "Release -O" : "Debug -Onone", label, micros, pct))
        return pct
    }

    func test_perf_fullChain_target10_fineTune10_rumble_protection() throws {
        let chain = Fixtures.chain(try fullParameters())
        let pct = report("full chain (Target 10 + Fine-Tune 10 + Bass shape + Rumble + protection)", measureChain(chain))
        if Fixtures.isOptimizedBuild { XCTAssertLessThan(pct, 3, "full chain over the 3 % budget") }
    }

    func test_perf_fullChain_whileDraggingABand() throws {
        let p = try fullParameters()
        let chain = Fixtures.chain(p)
        // A band moves every block → coefficient glides run continuously.
        let pct = report("full chain while dragging a band every block", measureChain(chain) { b in
            var q = p
            q.dual.fineTune.bands[4].frequency = 400 + Double(b % 200) * 5
            chain.setParameters(q)
        })
        if Fixtures.isOptimizedBuild { XCTAssertLessThan(pct, 5) }
    }

    func test_perf_flatChain_isNearlyFree() {
        let chain = Fixtures.chain(ChainParameters())
        let pct = report("flat chain (protection on, nothing else)", measureChain(chain))
        if Fixtures.isOptimizedBuild { XCTAssertLessThan(pct, 0.5) }
    }

    func test_perf_ringReaderWithResampler_512() {
        let cps = 997.0 / 48_000
        let w = FakeRingWriter(sampleRate: 48_000) { f in
            let v = Float(0.5 * sin(2 * Double.pi * cps * Double(f)))
            return (v, v)
        }
        let r = RingReader(header: w.readOnlyHeader)
        let clock = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        defer { clock.deallocate() }
        clock.pointee = 1_000_000
        r.hostClockOverride = clock
        r.configure(outputSampleRate: 48_000, outputMaxFrames: 4_096, outputBufferFrames: frames)
        w.startIO()
        let out = PlanarBuffer(channels: 2, frames: frames)
        let tick = UInt64(Double(frames) / 48_000 * RingReader.hostTicksPerSecond)
        for _ in 0 ..< 4 { clock.pointee += tick; w.write(frames: frames, hostTime: clock.pointee) }
        var renderNanos: UInt64 = 0
        var best = Double.infinity
        for _ in 0 ..< 7 {
            renderNanos = 0
            for _ in 0 ..< 400 {
                clock.pointee += tick
                w.write(frames: frames, hostTime: clock.pointee)
                let t0 = DispatchTime.now().uptimeNanoseconds
                r.render(into: out.pointers, frameCount: frames)
                renderNanos += DispatchTime.now().uptimeNanoseconds - t0
            }
            best = min(best, Double(renderNanos) / 400 / 1_000)
        }
        XCTAssertNotEqual(r.stats().lock, .waiting, "reader was not streaming during the measurement")
        let pct = report("RingReader + windowed-sinc resampler (32 taps × 1024 phases)", best)
        if Fixtures.isOptimizedBuild { XCTAssertLessThan(pct, 1) }
    }
}
