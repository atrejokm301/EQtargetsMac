//
//  LinkClockTests.swift
//  EQtargets (iOS)
//
//  Can the Mac's RingReader (resampler + PLL) play audio that arrives over the
//  loopback link? The Mac's own notes record that it never locks when the WRITER
//  has millisecond jitter, and socket delivery is exactly that.
//
//  The fix under test: each chunk carries the time the audio server wrote it, so
//  the reader's head projection follows the source clock, not socket arrival.
//  These runs use the REAL EQTLinkRingWriter and RingReader on a deterministic
//  simulated clock, with deliberately bad delivery: a 10 ms pump, up to 5 ms of
//  random delay, and a 30 ms stall every few seconds.
//

import XCTest

/// Source, socket and output on one simulated timeline.
final class LinkSimulation {

    struct Delivery {
        var pumpSeconds = 0.010
        var jitterSeconds = 0.005
        var stallEverySeconds = 4.0
        var stallSeconds = 0.030
        /// Negative control: stamp chunks when they ARRIVE, the naive design.
        var stampArrivalTime = false
    }

    private struct Chunk {
        let arrival: Double
        let start: Int64
        let frames: Int
        let endHost: UInt64
    }

    let reader: RingReader
    private let memory: UnsafeMutableRawPointer
    private let header: UnsafeMutablePointer<EQTRingHeader>
    private var writer = EQTLinkRingWriter()
    private let clock: UnsafeMutablePointer<UInt64>
    private let out = PlanarBuffer(channels: 2, frames: 8_192)
    private var rng = SplitMix64(seed: 11)

    private let sourceBlock: Int
    private let outputBlock: Int
    private let outputRate: Double
    private let driftPPM: Double
    private let delivery: Delivery
    private let tone: Double

    private(set) var time = 0.0
    private var produced: Int64 = 0
    private var sent: Int64 = 0
    private var stampFrame: Int64 = 0
    private var stampHost: UInt64 = 0
    private var nextIO = 0.0
    private var ioIndex: Int64 = 0
    private var nextPump = 0.002
    private var nextRender = 0.0005
    private var renderIndex: Int64 = 0
    private var nextStall: Double
    private var queue: [Chunk] = []
    private var queueHead = 0
    private var lastArrival = 0.0
    private var payload = [Float](repeating: 0, count: Int(EQT_LINK_MAX_CHUNK_FRAMES) * 2)
    private(set) var deliveredFrames: UInt64 = 0

    var left: [Float] = []
    /// Set by a test to raise the reserve while running, as the engine does.
    var onUnderrun: ((Int) -> UInt32?)?
    private var seenUnderruns = 0

    init(sourceBlock: Int = 512, outputBlock: Int = 480, outputRate: Double = 48_000,
         driftPPM: Double, delivery: Delivery = Delivery(), tone: Double = 997) {
        self.sourceBlock = sourceBlock
        self.outputBlock = outputBlock
        self.outputRate = outputRate
        self.driftPPM = driftPPM
        self.delivery = delivery
        self.tone = tone
        nextStall = delivery.stallEverySeconds
        memory = UnsafeMutableRawPointer.allocate(byteCount: Int(EQTRingTotalBytes()), alignment: 4096)
        header = memory.bindMemory(to: EQTRingHeader.self, capacity: 1)
        EQTLinkRingFormat(header)
        EQTLinkRingWriterInit(&writer, header)
        reader = RingReader(header: UnsafePointer(header))
        clock = .allocate(capacity: 1)
        clock.initialize(to: 1_000_000)
        reader.hostClockOverride = clock
        reader.configure(outputSampleRate: outputRate, outputMaxFrames: 4_096, outputBufferFrames: outputBlock)
    }

    deinit {
        clock.deallocate()
        memory.deallocate()
    }

    private func ticks(_ t: Double) -> UInt64 { UInt64(1_000_000 + t * RingReader.hostTicksPerSecond) }

    private var ticksPerFrame: Double { RingReader.hostTicksPerSecond / EQT_LINK_SAMPLE_RATE }

    /// Same interpolation as SenderHostTime in EQTLink.c.
    private func hostTime(ofFrame frame: Int64) -> UInt64 {
        let behind = stampFrame - frame
        guard behind > 0 else { return stampHost }
        return stampHost - UInt64(Double(behind) * ticksPerFrame)
    }

    private func pump(at t: Double) {
        var stall = 0.0
        if t >= nextStall {
            stall = delivery.stallSeconds
            nextStall += delivery.stallEverySeconds
        }
        while sent < produced {
            let n = Int(min(produced - sent, Int64(EQT_LINK_MAX_CHUNK_FRAMES)))
            let delay = Double.random(in: 0 ... delivery.jitterSeconds, using: &rng) + stall
            let arrival = max(lastArrival, t + delay)
            lastArrival = arrival
            let endHost = delivery.stampArrivalTime ? ticks(arrival) : hostTime(ofFrame: sent + Int64(n))
            queue.append(Chunk(arrival: arrival, start: sent, frames: n, endHost: endHost))
            sent += Int64(n)
        }
    }

    private func deliver(_ c: Chunk) {
        let cps = tone / EQT_LINK_SAMPLE_RATE
        for i in 0 ..< c.frames {
            let v = sin(2 * Double.pi * cps * Double(c.start + Int64(i)))
            payload[i * 2] = Float(0.5 * v)
            payload[i * 2 + 1] = Float(0.25 * v)
        }
        var h = EQTLinkChunkHeader(magic: EQT_LINK_MAGIC, version: UInt16(EQT_LINK_VERSION),
                                   channels: UInt16(EQT_LINK_CHANNELS), frames: UInt32(c.frames),
                                   flags: 0, startFrame: c.start, endHostTime: c.endHost)
        payload.withUnsafeBytes { raw in
            EQTLinkRingWriterWrite(&writer, &h, raw.bindMemory(to: UInt8.self).baseAddress!)
        }
        deliveredFrames += UInt64(c.frames)
    }

    func setReserve(_ frames: UInt32) { writer.reserveFrames = frames }

    func run(seconds: Double, onRender: ((RingReaderStats) -> Void)? = nil) {
        let end = time + seconds
        let ioPeriod = Double(sourceBlock) / (EQT_LINK_SAMPLE_RATE * (1 + driftPPM * 1e-6))
        let renderPeriod = Double(outputBlock) / outputRate
        while true {
            let tDeliver = queueHead < queue.count ? queue[queueHead].arrival : .infinity
            let t = min(nextIO, nextPump, nextRender, tDeliver)
            if t > end { break }
            time = t
            clock.pointee = ticks(t)
            if t == tDeliver {
                deliver(queue[queueHead])
                queueHead += 1
                if queueHead > 256 {
                    queue.removeFirst(queueHead)
                    queueHead = 0
                }
            } else if t == nextIO {
                produced += Int64(sourceBlock)
                stampFrame = produced
                stampHost = ticks(t)
                ioIndex += 1
                nextIO = Double(ioIndex) * ioPeriod
            } else if t == nextPump {
                pump(at: t)
                nextPump += delivery.pumpSeconds
            } else {
                renderIndex += 1
                nextRender = 0.0005 + Double(renderIndex) * renderPeriod
                reader.render(into: out.pointers, frameCount: outputBlock)
                out.store(0, into: &left, count: outputBlock)
                let st = reader.stats()
                if st.underruns != seenUnderruns {
                    seenUnderruns = st.underruns
                    if let r = onUnderrun?(st.underruns) { setReserve(r) }
                }
                onRender?(st)
            }
        }
        time = end
    }
}

final class LinkClockTests: XCTestCase {

    private struct Outcome {
        var lockedAt: Double?
        var lostLock = 0
        var worstFill = 0.0
        var worstPPM = 0.0
        var worstTHD = -300.0
        var pitchPPM = 0.0
        var stats = RingReaderStats()
    }

    private func measure(_ sim: LinkSimulation, seconds: Double, trueDriftPPM: Double,
                         nominal: Double, label: String, holdFrom: Double = 0) -> Outcome {
        var o = Outcome()
        sim.run(seconds: seconds) { st in
            if o.lockedAt == nil, st.lock == .locked { o.lockedAt = sim.time }
            if let at = o.lockedAt, sim.time > max(at + 5, holdFrom) {
                o.worstFill = max(o.worstFill, abs(st.fillFrames - st.targetFillFrames))
                o.worstPPM = max(o.worstPPM, abs(st.driftPPM - trueDriftPPM))
                if st.lock != .locked { o.lostLock += 1 }
            }
        }
        o.stats = sim.reader.stats()
        let n = 24_000
        let tail = Array(sim.left[(sim.left.count - n)...])
        for start in stride(from: 0, through: n - 4_096, by: 4_096) {
            let r = Fixtures.fitSineFreeFrequency(Array(tail[start ..< start + 4_096]), nominal: nominal, spanPPM: 300)
            o.worstTHD = max(o.worstTHD, r.fit.thdPlusNoiseDB)
        }
        o.pitchPPM = Fixtures.fitSineFreeFrequency(tail, nominal: nominal, spanPPM: 300).offsetPPM
        print(String(format: "%@: lock %.2f s, lost %d, |fill-target| %.1f (target %.0f), |drift err| %.2f ppm, under %d over %d resync %d, THD+N %.1f dB, pitch %+.2f ppm",
                     label, o.lockedAt ?? -1, o.lostLock, o.worstFill, o.stats.targetFillFrames, o.worstPPM,
                     o.stats.underruns, o.stats.overruns, o.stats.resyncs, o.worstTHD, o.pitchPPM))
        return o
    }

    private func assertHolds(_ o: Outcome, allowedUnderruns: Int = 0,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNotNil(o.lockedAt, "never locked", file: file, line: line)
        XCTAssertLessThan(o.lockedAt ?? .infinity, 20, "slow to lock", file: file, line: line)
        XCTAssertEqual(o.lostLock, 0, "lost lock", file: file, line: line)
        XCTAssertLessThanOrEqual(o.stats.underruns, allowedUnderruns, file: file, line: line)
        XCTAssertEqual(o.stats.overruns, 0, file: file, line: line)
        XCTAssertEqual(o.stats.resyncs, o.stats.underruns + 1, file: file, line: line)
        XCTAssertLessThan(o.worstPPM, 15, "ratio wandered", file: file, line: line)
        XCTAssertLessThan(o.worstTHD, -80, "output not clean", file: file, line: line)
        XCTAssertLessThan(abs(o.pitchPPM), 15, "pitch off", file: file, line: line)
    }

    /// Everyday delivery: pump and jitter, no scheduling stalls.
    private var steady: LinkSimulation.Delivery {
        var d = LinkSimulation.Delivery()
        d.stallSeconds = 0
        return d
    }

    /// The engine's policy, applied the moment the reader reports an underrun.
    private func adaptive(_ sim: LinkSimulation) {
        var policy = LinkReservePolicy()
        sim.onUnderrun = { [unowned sim] _ in policy.observeUnderrun(framesFromPeer: sim.deliveredFrames) }
    }

    func test_steadyDelivery_plus60ppm_locksWithNoDropouts() {
        let sim = LinkSimulation(driftPPM: 60, delivery: steady)
        assertHolds(measure(sim, seconds: 50, trueDriftPPM: 60,
                            nominal: 997.0 / 48_000 * (1 + 60e-6), label: "link +60 ppm, 512 block"))
    }

    func test_steadyDelivery_minus60ppm_locksWithNoDropouts() {
        let sim = LinkSimulation(driftPPM: -60, delivery: steady)
        assertHolds(measure(sim, seconds: 50, trueDriftPPM: -60,
                            nominal: 997.0 / 48_000 * (1 - 60e-6), label: "link -60 ppm, 512 block"))
    }

    func test_steadyDelivery_1024FrameServerCycle_locksWithNoDropouts() {
        let sim = LinkSimulation(sourceBlock: 1024, driftPPM: 25, delivery: steady)
        assertHolds(measure(sim, seconds: 50, trueDriftPPM: 25,
                            nominal: 997.0 / 48_000 * (1 + 25e-6), label: "link +25 ppm, 1024 block"))
    }

    /// The device can run at 44.1 kHz while the link is fixed at 48 kHz. A plain
    /// copy would play 8.8 % sharp.
    func test_outputAt44k1_playsTheRightPitch() {
        let sim = LinkSimulation(outputBlock: 441, outputRate: 44_100, driftPPM: 30, delivery: steady)
        let nominal = 997.0 / 44_100 * (1 + 30e-6)
        assertHolds(measure(sim, seconds: 50, trueDriftPPM: 30, nominal: nominal, label: "link to 44.1 kHz output"))
    }

    /// Repeating 30 ms stalls: two dropouts, then the deeper reserve absorbs them.
    func test_repeatedStalls_costTwoDropouts_thenAreAbsorbed() {
        let sim = LinkSimulation(driftPPM: 60)
        adaptive(sim)
        assertHolds(measure(sim, seconds: 50, trueDriftPPM: 60,
                            nominal: 997.0 / 48_000 * (1 + 60e-6), label: "link with 30 ms stalls",
                            holdFrom: 16),
                    allowedUnderruns: 2)
    }

    /// Negative control for the policy: without it the same stalls keep dropping out.
    func test_negativeControl_withoutReservePolicy_stallsKeepDroppingOut() {
        let o = measure(LinkSimulation(driftPPM: 60), seconds: 50, trueDriftPPM: 60,
                        nominal: 997.0 / 48_000 * (1 + 60e-6), label: "CONTROL fixed reserve")
        XCTAssertGreaterThan(o.stats.underruns, 5)
    }

    /// Negative control for capture-time stamps: same delivery, stamped on arrival.
    func test_negativeControl_arrivalStamps_failToHoldTheRatio() {
        var naive = steady
        naive.stampArrivalTime = true
        let bad = measure(LinkSimulation(driftPPM: 60, delivery: naive), seconds: 50, trueDriftPPM: 60,
                          nominal: 997.0 / 48_000 * (1 + 60e-6), label: "CONTROL arrival stamps")
        let good = measure(LinkSimulation(driftPPM: 60, delivery: steady), seconds: 50, trueDriftPPM: 60,
                           nominal: 997.0 / 48_000 * (1 + 60e-6), label: "capture stamps")
        XCTAssertNotNil(good.lockedAt)
        let failed = bad.lockedAt == nil || bad.lostLock > 0 || bad.worstPPM > good.worstPPM * 2
            || bad.stats.underruns > good.stats.underruns
        XCTAssertTrue(failed, "arrival stamps should be measurably worse than capture stamps")
    }

    // MARK: A paused player

    /// Plays 3 s, stops delivering for 1 s, then resumes. `announced` is whether
    /// the end-of-stream marker reached the writer.
    private func pauseAndResume(announced: Bool) -> (RingReaderStats, atPause: RingReaderStats.Lock, generations: UInt64) {
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(EQTRingTotalBytes()), alignment: 4096)
        defer { memory.deallocate() }
        let ring = memory.bindMemory(to: EQTRingHeader.self, capacity: 1)
        EQTLinkRingFormat(ring)
        var writer = EQTLinkRingWriter()
        EQTLinkRingWriterInit(&writer, ring)
        let clock = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        clock.initialize(to: 1_000_000)
        defer { clock.deallocate() }
        let reader = RingReader(header: UnsafePointer(ring))
        reader.hostClockOverride = clock
        reader.configure(outputSampleRate: 48_000, outputMaxFrames: 4_096, outputBufferFrames: 480)
        let out = PlanarBuffer(channels: 2, frames: 8_192)
        var payload = [Float](repeating: 0.1, count: 960)
        var frame: Int64 = 0
        var block = 0
        func ticks() -> UInt64 { UInt64(1_000_000 + Double(block) * 0.01 * RingReader.hostTicksPerSecond) }

        func step(writing: Bool) {
            clock.pointee = ticks()
            if writing {
                var h = EQTLinkChunkHeader(magic: EQT_LINK_MAGIC, version: UInt16(EQT_LINK_VERSION), channels: 2,
                                           frames: 480, flags: 0, startFrame: frame, endHostTime: ticks())
                payload.withUnsafeMutableBytes {
                    EQTLinkRingWriterWrite(&writer, &h, $0.bindMemory(to: UInt8.self).baseAddress!)
                }
                frame += 480
            }
            reader.render(into: out.pointers, frameCount: 480)
            block += 1
        }

        for _ in 0 ..< 300 { step(writing: true) }
        let before = EQTRingLoadGeneration(ring)
        if announced { EQTLinkRingWriterClose(&writer) }
        for _ in 0 ..< 100 { step(writing: false) }
        let atPause = reader.stats().lock
        for _ in 0 ..< 300 { step(writing: true) }
        return (reader.stats(), atPause, EQTRingLoadGeneration(ring) - before)
    }

    func test_announcedPause_isNotADropout_andResumesOnACleanTimeline() {
        let (st, atPause, generations) = pauseAndResume(announced: true)
        XCTAssertEqual(st.underruns, 0, "a pause must not show up as a dropout")
        XCTAssertEqual(atPause, .waiting)
        XCTAssertEqual(generations, 1)
        XCTAssertEqual(st.resyncs, 2)
        XCTAssertNotEqual(st.lock, .waiting)
    }

    func test_negativeControl_unannouncedPause_countsADropout() {
        let (st, _, generations) = pauseAndResume(announced: false)
        XCTAssertEqual(st.underruns, 1)
        XCTAssertEqual(generations, 0)
    }
}
