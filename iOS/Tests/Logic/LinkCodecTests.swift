//
//  LinkCodecTests.swift
//  EQtargets (iOS)
//
//  The wire format and the ring writer, without sockets: partial reads, garbage,
//  hostile headers, gaps and non-finite samples.
//

import XCTest

final class LinkCodecTests: XCTestCase {

    private func chunk(start: Int64, frames: Int, host: UInt64 = 7, value: (Int) -> Float = { Float($0) }) -> [UInt8] {
        var h = EQTLinkChunkHeader(magic: EQT_LINK_MAGIC, version: UInt16(EQT_LINK_VERSION),
                                   channels: UInt16(EQT_LINK_CHANNELS), frames: UInt32(frames),
                                   flags: 0, startFrame: start, endHostTime: host)
        var bytes = withUnsafeBytes(of: &h) { Array($0) }
        for i in 0 ..< frames * 2 {
            var v = value(i)
            bytes.append(contentsOf: withUnsafeBytes(of: &v) { Array($0) })
        }
        return bytes
    }

    /// Runs the consumer over `input` in pieces of `step` bytes, like TCP would.
    private func consume(_ input: [UInt8], step: Int) -> (headers: [EQTLinkChunkHeader], samples: [Float], skipped: Int) {
        final class Sink {
            var headers: [EQTLinkChunkHeader] = []
            var samples: [Float] = []
        }
        let sink = Sink()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var length = 0
        var skipped = 0
        var i = 0
        while i < input.count {
            let n = min(step, input.count - i)
            buffer.replaceSubrange(length ..< length + n, with: input[i ..< i + n])
            length += n
            i += n
            buffer.withUnsafeMutableBufferPointer { p in
                skipped += EQTLinkConsume(p.baseAddress!, &length, { ctx, header, payload in
                    let s = Unmanaged<Sink>.fromOpaque(ctx!).takeUnretainedValue()
                    let h = header!.pointee
                    s.headers.append(h)
                    for k in 0 ..< Int(h.frames) * 2 {
                        var v: Float = 0
                        memcpy(&v, payload! + k * 4, 4)
                        s.samples.append(v)
                    }
                }, Unmanaged.passUnretained(sink).toOpaque())
            }
        }
        return (sink.headers, sink.samples, skipped)
    }

    private func makeRing() -> UnsafeMutablePointer<EQTRingHeader> {
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(EQTRingTotalBytes()), alignment: 4096)
        let ring = memory.bindMemory(to: EQTRingHeader.self, capacity: 1)
        EQTLinkRingFormat(ring)
        addTeardownBlock { memory.deallocate() }
        return ring
    }

    private func write(_ writer: inout EQTLinkRingWriter, _ bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer { p in
            var h = EQTLinkChunkHeader()
            memcpy(&h, p.baseAddress!, MemoryLayout<EQTLinkChunkHeader>.size)
            EQTLinkRingWriterWrite(&writer, &h, p.baseAddress! + MemoryLayout<EQTLinkChunkHeader>.size)
        }
    }

    // MARK: Framing

    func test_headerIsThirtyTwoBytes() {
        XCTAssertEqual(MemoryLayout<EQTLinkChunkHeader>.size, 32)
    }

    func test_consume_deliversChunksIntact_atEveryTCPSplitSize() {
        let input = chunk(start: 0, frames: 3) + chunk(start: 3, frames: 5) { Float($0) + 100 }
        for step in [1, 2, 3, 5, 7, 31, 32, 33, 64, input.count] {
            let out = consume(input, step: step)
            XCTAssertEqual(out.skipped, 0, "split \(step)")
            XCTAssertEqual(out.headers.map(\.frames), [3, 5], "split \(step)")
            XCTAssertEqual(out.samples, (0 ..< 6).map(Float.init) + (0 ..< 10).map { Float($0) + 100 }, "split \(step)")
        }
    }

    func test_consume_recoversAfterGarbage_withoutLosingTheNextChunk() {
        let input = [UInt8](repeating: 0xAB, count: 57) + chunk(start: 9, frames: 4)
        let out = consume(input, step: 11)
        XCTAssertEqual(out.skipped, 57)
        XCTAssertEqual(out.headers.map(\.startFrame), [9])
        XCTAssertEqual(out.samples.count, 8)
    }

    func test_header_rejectsEveryOutOfRangeField() {
        let good = EQTLinkChunkHeader(magic: EQT_LINK_MAGIC, version: UInt16(EQT_LINK_VERSION),
                                      channels: 2, frames: 16, flags: 0, startFrame: 0, endHostTime: 1)
        var h = good
        XCTAssertEqual(EQTLinkHeaderIsValid(&h), 1)
        h = good; h.magic = 0;                      XCTAssertEqual(EQTLinkHeaderIsValid(&h), 0)
        h = good; h.version = 2;                    XCTAssertEqual(EQTLinkHeaderIsValid(&h), 0)
        h = good; h.channels = 1;                   XCTAssertEqual(EQTLinkHeaderIsValid(&h), 0)
        h = good; h.frames = 0;                     XCTAssertEqual(EQTLinkHeaderIsValid(&h), 0)
        h = good; h.frames = EQT_LINK_MAX_CHUNK_FRAMES + 1; XCTAssertEqual(EQTLinkHeaderIsValid(&h), 0)
        h = good; h.frames = .max;                  XCTAssertEqual(EQTLinkHeaderIsValid(&h), 0)
        h = good; h.startFrame = -1;                XCTAssertEqual(EQTLinkHeaderIsValid(&h), 0)
        h = good; h.startFrame = .max;              XCTAssertEqual(EQTLinkHeaderIsValid(&h), 0)
        h = good; h.frames = EQT_LINK_MAX_CHUNK_FRAMES; XCTAssertEqual(EQTLinkHeaderIsValid(&h), 1)
    }

    // MARK: Ring writer

    func test_writer_publishesFramesStampAndReserve() {
        let ring = makeRing()
        var w = EQTLinkRingWriter()
        EQTLinkRingWriterInit(&w, ring)
        let before = EQTRingLoadGeneration(ring)
        write(&w, chunk(start: 1_000, frames: 4, host: 555))
        XCTAssertEqual(EQTRingHeaderIsValid(ring), 1)
        XCTAssertEqual(EQTRingLoadGeneration(ring), before + 1)
        XCTAssertEqual(EQTRingLoadIORunning(ring), 1)
        XCTAssertEqual(EQTRingLoadWriteHead(ring), 4, "the first chunk maps to ring frame 0")
        XCTAssertEqual(EQTRingLoadLastWriteHostTime(ring), 555)
        XCTAssertEqual(EQTRingLoadIOBufferFrames(ring), EQT_LINK_DEFAULT_RESERVE)
        XCTAssertEqual(EQTRingSamples(ring)[7], 7)
    }

    func test_writer_zeroFillsAGap_soStaleAudioNeverPlays() {
        let ring = makeRing()
        var w = EQTLinkRingWriter()
        EQTLinkRingWriterInit(&w, ring)
        let s = EQTRingSamples(ring)!
        for i in 0 ..< 200 { s[i] = 9 }
        write(&w, chunk(start: 0, frames: 2) { _ in 1 })
        write(&w, chunk(start: 10, frames: 2) { _ in 2 })
        XCTAssertEqual(EQTRingLoadWriteHead(ring), 12)
        XCTAssertEqual(w.gapFrames, 8)
        for i in 4 ..< 20 { XCTAssertEqual(s[i], 0, "sample \(i)") }
        XCTAssertEqual(s[20], 2)
    }

    func test_writer_chunkMovingBackwards_startsANewGeneration() {
        let ring = makeRing()
        var w = EQTLinkRingWriter()
        EQTLinkRingWriterInit(&w, ring)
        write(&w, chunk(start: 100, frames: 8))
        let g = EQTRingLoadGeneration(ring)
        write(&w, chunk(start: 50, frames: 4))
        XCTAssertEqual(EQTRingLoadGeneration(ring), g + 1)
        XCTAssertEqual(EQTRingLoadWriteHead(ring), 4)
    }

    func test_writer_nonFiniteSamples_becomeSilenceAndAreCounted() {
        let ring = makeRing()
        var w = EQTLinkRingWriter()
        EQTLinkRingWriterInit(&w, ring)
        let bad: [Float] = [.nan, 0.5, .infinity, -.infinity]
        write(&w, chunk(start: 0, frames: 2) { bad[$0] })
        let s = EQTRingSamples(ring)!
        XCTAssertEqual([s[0], s[1], s[2], s[3]], [0, 0.5, 0, 0])
        XCTAssertEqual(w.badSamples, 3)
    }

    func test_writer_gapTooLongToBridge_startsANewTimeline_withoutAnyFillWork() {
        let ring = makeRing()
        var w = EQTLinkRingWriter()
        EQTLinkRingWriterInit(&w, ring)
        write(&w, chunk(start: 0, frames: 2))
        let generation = EQTRingLoadGeneration(ring)
        let s = EQTRingSamples(ring)!
        for i in 0 ..< 200 { s[i] = 9 }

        write(&w, chunk(start: Int64(1) << 49, frames: 2) { _ in 3 })
        XCTAssertEqual(EQTRingLoadGeneration(ring), generation + 1)
        XCTAssertEqual(EQTRingLoadWriteHead(ring), 2)
        XCTAssertEqual(s[0], 3)
        XCTAssertEqual(s[8], 9, "a 40-byte chunk must not trigger a 32,768-frame fill")
    }

    func test_writer_longestBridgedGap_staysOnTheSameTimeline() {
        let ring = makeRing()
        var w = EQTLinkRingWriter()
        EQTLinkRingWriterInit(&w, ring)
        write(&w, chunk(start: 0, frames: 2))
        let generation = EQTRingLoadGeneration(ring)
        write(&w, chunk(start: 2 + Int64(EQT_LINK_MAX_GAP_FRAMES), frames: 2))
        XCTAssertEqual(EQTRingLoadGeneration(ring), generation)
        XCTAssertEqual(w.gapFrames, UInt64(EQT_LINK_MAX_GAP_FRAMES))
    }

    func test_writer_absurdSamples_areClampedBeforeTheDSP() {
        let ring = makeRing()
        var w = EQTLinkRingWriter()
        EQTLinkRingWriterInit(&w, ring)
        let hot: [Float] = [1e38, -1e38, 7.5, -0.25]
        write(&w, chunk(start: 0, frames: 2) { hot[$0] })
        let s = EQTRingSamples(ring)!
        XCTAssertEqual([s[0], s[1], s[2], s[3]], [EQT_LINK_MAX_SAMPLE, -EQT_LINK_MAX_SAMPLE, 7.5, -0.25])
    }

    func test_writer_close_stopsIOWithoutMovingTheHead() {
        let ring = makeRing()
        var w = EQTLinkRingWriter()
        EQTLinkRingWriterInit(&w, ring)
        write(&w, chunk(start: 0, frames: 2))
        EQTLinkRingWriterClose(&w)
        XCTAssertEqual(EQTRingLoadIORunning(ring), 0)
        XCTAssertEqual(EQTRingLoadWriteHead(ring), 2)
    }

    // MARK: End of stream

    private func endMarker(at frame: Int64 = 0) -> [UInt8] {
        var h = EQTLinkChunkHeader(magic: EQT_LINK_MAGIC, version: UInt16(EQT_LINK_VERSION),
                                   channels: UInt16(EQT_LINK_CHANNELS), frames: 0,
                                   flags: EQT_LINK_FLAG_END_OF_STREAM, startFrame: frame, endHostTime: 0)
        return withUnsafeBytes(of: &h) { Array($0) }
    }

    func test_endMarker_isValidOnlyWithItsFlag() {
        var h = EQTLinkChunkHeader(magic: EQT_LINK_MAGIC, version: UInt16(EQT_LINK_VERSION),
                                   channels: 2, frames: 0, flags: EQT_LINK_FLAG_END_OF_STREAM,
                                   startFrame: 0, endHostTime: 0)
        XCTAssertEqual(EQTLinkHeaderIsValid(&h), 1)
        h.flags = 0
        XCTAssertEqual(EQTLinkHeaderIsValid(&h), 0, "an empty chunk without the flag is garbage")
        h.flags = EQT_LINK_FLAG_END_OF_STREAM
        h.frames = 16
        XCTAssertEqual(EQTLinkHeaderIsValid(&h), 0, "an audio chunk must not carry flags")
    }

    func test_endMarker_framesCleanlyBetweenChunks() {
        let input = chunk(start: 0, frames: 3) + endMarker(at: 3) + chunk(start: 3, frames: 2)
        for step in [1, 7, 32, input.count] {
            let out = consume(input, step: step)
            XCTAssertEqual(out.skipped, 0, "split \(step)")
            XCTAssertEqual(out.headers.map(\.frames), [3, 0, 2], "split \(step)")
        }
    }

    // MARK: Reserve policy

    func test_reservePolicy_ignoresStartUpUnderruns() {
        var p = LinkReservePolicy()
        XCTAssertNil(p.observeUnderrun(framesFromPeer: 5_000))
        XCTAssertNil(p.observeUnderrun(framesFromPeer: 25_000))
        XCTAssertNil(p.observeUnderrun(framesFromPeer: 47_999))
        XCTAssertEqual(p.reserve, 1024)
        XCTAssertNil(p.observeUnderrun(framesFromPeer: 60_000), "the first one that counts changes nothing")
        XCTAssertEqual(p.reserve, 1024)
    }

    func test_reservePolicy_oneIsolatedDropoutChangesNothing() {
        var p = LinkReservePolicy()
        XCTAssertNil(p.observeUnderrun(framesFromPeer: 100_000))
        XCTAssertNil(p.observeUnderrun(framesFromPeer: 100_000 + LinkReservePolicy.windowFrames + 1),
                     "further apart than the window")
        XCTAssertEqual(p.reserve, 1024)
    }

    func test_reservePolicy_repeatedDropouts_doubleToTheCap_thenStop() {
        var p = LinkReservePolicy()
        var frames: UInt64 = 100_000
        func next() -> UInt32? {
            frames += 192_000
            return p.observeUnderrun(framesFromPeer: frames)
        }
        XCTAssertNil(next())
        XCTAssertEqual(next(), 2048)
        XCTAssertNil(next())
        XCTAssertEqual(next(), 4096)
        XCTAssertNil(next())
        XCTAssertNil(next())
        XCTAssertEqual(p.reserve, 4096)
    }

    func test_reservePolicy_newPeerForgetsTheOldOnesUnderrun() {
        var p = LinkReservePolicy()
        XCTAssertNil(p.observeUnderrun(framesFromPeer: 900_000))
        XCTAssertNil(p.observeUnderrun(framesFromPeer: 60_000), "the counter went back: a new peer")
        XCTAssertEqual(p.reserve, 1024)
    }

    func test_reservePolicy_resetReturnsToShallowAndForgets() {
        var p = LinkReservePolicy()
        _ = p.observeUnderrun(framesFromPeer: 100_000)
        _ = p.observeUnderrun(framesFromPeer: 200_000)
        XCTAssertEqual(p.reserve, 2048)
        _ = p.observeUnderrun(framesFromPeer: 300_000)
        p.reset()
        XCTAssertEqual(p.reserve, 1024)
        XCTAssertNil(p.observeUnderrun(framesFromPeer: 400_000), "memory cleared too")
    }
}
