//
//  LinkSocketTests.swift
//  EQtargets (iOS)
//
//  The real sender and receiver over real loopback TCP, into the real RingReader.
//  This is everything between the audio server and the speaker except the Apple
//  framework calls, which only exist on a device. Each test uses its own port.
//

import XCTest
import Darwin

final class LinkSocketTests: XCTestCase {

    private static var nextPort: UInt16 = 48_310

    private func makePort() -> UInt16 {
        Self.nextPort += 1
        return Self.nextPort
    }

    private final class Harness {
        let memory: UnsafeMutableRawPointer
        let ring: UnsafeMutablePointer<EQTRingHeader>
        let receiver: OpaquePointer
        let sender: OpaquePointer

        init(port: UInt16) {
            memory = .allocate(byteCount: Int(EQTRingTotalBytes()), alignment: 4096)
            ring = memory.bindMemory(to: EQTRingHeader.self, capacity: 1)
            EQTLinkRingFormat(ring)
            receiver = keyedReceiver(port, ring)
            sender = keyedSender(port)
        }

        deinit {
            EQTLinkSenderDestroy(sender)
            EQTLinkReceiverDestroy(receiver)
            memory.deallocate()
        }

        var receiverStats: EQTLinkReceiverStats {
            var s = EQTLinkReceiverStats()
            EQTLinkReceiverGetStats(receiver, &s)
            return s
        }

        var senderStats: EQTLinkSenderStats {
            var s = EQTLinkSenderStats()
            EQTLinkSenderGetStats(sender, &s)
            return s
        }
    }

    private func wait(_ what: String, timeout: TimeInterval = 5, until condition: () -> Bool,
                      file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out waiting for \(what)", file: file, line: line)
                return
            }
            usleep(2_000)
        }
    }

    /// Identifies a frame by value, inside the range the ring writer accepts.
    private static func marker(_ frame: Int) -> Float { Float(frame) / 65_536 }

    private func push(_ h: Harness, from start: Int, frames: Int) {
        var samples = [Float](repeating: 0, count: frames * 2)
        for i in 0 ..< frames {
            samples[i * 2] = Self.marker(start + i)
            samples[i * 2 + 1] = -Self.marker(start + i)
        }
        EQTLinkSenderPush(h.sender, samples, UInt32(frames), 2, mach_absolute_time())
    }

    private func connect(_ h: Harness) {
        XCTAssertEqual(EQTLinkReceiverStart(h.receiver), 0)
        XCTAssertEqual(EQTLinkSenderStart(h.sender), 0)
        wait("connection", until: { h.receiverStats.hasPeer == 1 && h.senderStats.connected == 1 })
    }

    func test_framesArriveInOrder_withLeftAndRightIntact() {
        let h = Harness(port: makePort())
        connect(h)
        let total = 30_000
        var sent = 0
        while sent < total {
            let n = min(137, total - sent)     // not a multiple of anything useful
            push(h, from: sent, frames: n)
            sent += n
            if sent % 2_740 == 0 { usleep(500) }
        }
        wait("all frames", until: { h.receiverStats.receivedFrames == UInt64(total) })
        XCTAssertEqual(EQTRingLoadWriteHead(h.ring), Int64(total))
        XCTAssertEqual(h.receiverStats.skippedBytes, 0)
        XCTAssertEqual(h.receiverStats.badSamples, 0)
        XCTAssertEqual(h.senderStats.droppedFrames, 0)

        let cap = Int(EQT_RING_CAPACITY_FRAMES)
        let s = EQTRingSamples(h.ring)!
        for f in (total - 2_000) ..< total {
            let slot = f & (cap - 1)
            XCTAssertEqual(s[slot * 2], Self.marker(f), "left at frame \(f)")
            XCTAssertEqual(s[slot * 2 + 1], -Self.marker(f), "right at frame \(f)")
        }
    }

    func test_receiverBindsLoopbackOnly() {
        let port = makePort()
        let h = Harness(port: port)
        XCTAssertEqual(EQTLinkReceiverStart(h.receiver), 0)
        // With SO_REUSEADDR, the wildcard address can share a port with a
        // listener on a specific address, but not with another wildcard listener.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        a.sin_addr.s_addr = INADDR_ANY.bigEndian
        let rc = withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(rc, 0, "bind of the wildcard failed, so the receiver is not loopback-only")
    }

    func test_secondReceiverOnTheSamePort_reportsAnError() {
        let port = makePort()
        let a = Harness(port: port)
        let b = Harness(port: port)
        XCTAssertEqual(EQTLinkReceiverStart(a.receiver), 0)
        XCTAssertEqual(EQTLinkReceiverStart(b.receiver), EADDRINUSE)
    }

    func test_senderWithNoApp_keepsRetrying_andConnectsWhenTheAppArrives() {
        let h = Harness(port: makePort())
        XCTAssertEqual(EQTLinkSenderStart(h.sender), 0)
        push(h, from: 0, frames: 512)
        usleep(150_000)
        XCTAssertEqual(h.senderStats.connected, 0)
        XCTAssertEqual(EQTLinkReceiverStart(h.receiver), 0)
        wait("late connection", until: { h.receiverStats.hasPeer == 1 })
        // Audio queued before the connection is already late and must not play.
        XCTAssertEqual(h.receiverStats.receivedFrames, 0)
        push(h, from: 512, frames: 64)
        wait("new audio", until: { h.receiverStats.receivedFrames == 64 })
    }

    func test_appRestart_senderReconnects_andANewGenerationBegins() {
        let h = Harness(port: makePort())
        connect(h)
        push(h, from: 0, frames: 256)
        wait("first audio", until: { h.receiverStats.receivedFrames == 256 })
        let generation = EQTRingLoadGeneration(h.ring)

        EQTLinkReceiverStop(h.receiver)
        XCTAssertEqual(EQTRingLoadIORunning(h.ring), 0, "the reader must learn the peer left")
        // The sender discovers the closed socket on its next send.
        var next = 256
        wait("sender to notice", until: {
            push(h, from: next, frames: 64)
            next += 64
            return h.senderStats.connected == 0
        })

        XCTAssertEqual(EQTLinkReceiverStart(h.receiver), 0)
        wait("reconnect", until: { h.receiverStats.hasPeer == 1 && h.senderStats.connected == 1 })
        let before = h.receiverStats.receivedFrames
        wait("audio after reconnect", until: {
            push(h, from: next, frames: 64)
            next += 64
            return h.receiverStats.receivedFrames > before
        })
        XCTAssertGreaterThan(EQTRingLoadGeneration(h.ring), generation)
        XCTAssertEqual(EQTRingLoadIORunning(h.ring), 1)
    }

    func test_garbageFromAnotherLocalApp_cannotCrashOrPoisonTheStream() {
        let port = makePort()
        let h = Harness(port: port)
        XCTAssertEqual(EQTLinkReceiverStart(h.receiver), 0)

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        a.sin_addr.s_addr = in_addr_t(0x7F00_0001).bigEndian
        let rc = withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(rc, 0)

        var rng = SplitMix64(seed: 3)
        var junk = [UInt8](repeating: 0, count: 200_000)
        for i in junk.indices { junk[i] = UInt8(truncatingIfNeeded: rng.next()) }
        _ = junk.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, MSG_DONTWAIT) }
        wait("the caller to be refused", until: { h.receiverStats.rejectedCallers >= 1 })
        XCTAssertEqual(h.receiverStats.hasPeer, 0, "junk must never become the peer")
        XCTAssertEqual(h.receiverStats.receivedFrames, 0, "random bytes must not be accepted as audio")
        XCTAssertEqual(h.receiverStats.listening, 1)
    }

    func test_aSilentCaller_cannotBlockARealSender() {
        let port = makePort()
        let h = Harness(port: port)
        XCTAssertEqual(EQTLinkReceiverStart(h.receiver), 0)

        let squatter = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(squatter) }
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        a.sin_addr.s_addr = in_addr_t(0x7F00_0001).bigEndian
        _ = withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(squatter, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        usleep(50_000)
        XCTAssertEqual(h.receiverStats.connections, 0, "a caller that proves nothing is not a peer")

        XCTAssertEqual(EQTLinkSenderStart(h.sender), 0)
        wait("the real sender", until: { h.receiverStats.connections == 1 })
        var next = 0
        wait("audio from the real sender", until: {
            push(h, from: next, frames: 64)
            next += 64
            return h.receiverStats.receivedFrames > 0
        })
    }

    /// Junk must not count as activity, or any local app could hold the link.
    func test_aCallerSendingOnlyJunk_cannotBlockARealSender() {
        let port = makePort()
        let h = Harness(port: port)
        XCTAssertEqual(EQTLinkReceiverStart(h.receiver), 0)

        let squatter = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(squatter) }
        var on: Int32 = 1
        setsockopt(squatter, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        a.sin_addr.s_addr = in_addr_t(0x7F00_0001).bigEndian
        _ = withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(squatter, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        let junk = [UInt8](repeating: 0x5A, count: 4_096)
        _ = junk.withUnsafeBytes { send(squatter, $0.baseAddress, $0.count, MSG_DONTWAIT) }
        wait("the caller to be refused", until: { h.receiverStats.rejectedCallers >= 1 })
        XCTAssertEqual(h.receiverStats.receivedFrames, 0)
        XCTAssertEqual(h.receiverStats.connections, 0)

        XCTAssertEqual(EQTLinkSenderStart(h.sender), 0)
        wait("the real sender", until: {
            _ = junk.withUnsafeBytes { send(squatter, $0.baseAddress, $0.count, MSG_DONTWAIT) }
            return h.receiverStats.connections == 1
        })
    }

    // MARK: Idle behaviour (battery)

    func test_connectedButIdleSender_doesNotKeepWakingUp() {
        let h = Harness(port: makePort())
        connect(h)
        usleep(100_000)         // let it finish connecting and go to sleep
        let before = h.senderStats.wakeups
        usleep(600_000)         // the old timer would have fired 6 times
        XCTAssertLessThanOrEqual(h.senderStats.wakeups - before, 1)
    }

    func test_senderNotDelivering_makesNoConnectAttempts() {
        let h = Harness(port: makePort())       // nobody is listening
        XCTAssertEqual(EQTLinkSenderStart(h.sender), 0)
        EQTLinkSenderSetDelivering(h.sender, 0)
        usleep(150_000)
        let before = h.senderStats.connectAttempts
        let wakesBefore = h.senderStats.wakeups
        usleep(2_300_000)       // longer than the slowest retry timer
        XCTAssertEqual(h.senderStats.connectAttempts, before, "a selected, idle output must not poll")
        XCTAssertEqual(h.senderStats.wakeups, wakesBefore, "and must not wake the phone to check")

        EQTLinkSenderSetDelivering(h.sender, 1)
        wait("reconnect attempts resume", until: { h.senderStats.connectAttempts > before })
    }

    func test_deliveryStopping_endsTheStream_withoutDroppingThePeer() {
        let h = Harness(port: makePort())
        connect(h)
        push(h, from: 0, frames: 256)
        wait("first audio", until: { h.receiverStats.receivedFrames == 256 })
        XCTAssertEqual(EQTRingLoadIORunning(h.ring), 1)
        let generation = EQTRingLoadGeneration(h.ring)

        EQTLinkSenderSetDelivering(h.sender, 0)
        wait("end of stream", until: { EQTRingLoadIORunning(h.ring) == 0 })
        XCTAssertEqual(h.receiverStats.hasPeer, 1, "a pause must not look like another output was picked")
        XCTAssertEqual(h.receiverStats.connections, 1)

        EQTLinkSenderSetDelivering(h.sender, 1)
        push(h, from: 256, frames: 64)
        wait("audio after the pause", until: { h.receiverStats.receivedFrames == 320 })
        XCTAssertEqual(EQTRingLoadIORunning(h.ring), 1)
        XCTAssertEqual(EQTRingLoadGeneration(h.ring), generation + 1, "a clean new timeline")
        XCTAssertEqual(h.receiverStats.skippedBytes, 0)
    }

    func test_audioResumingBeforeTheMarkerIsSent_cancelsTheMarker() {
        let port = makePort()
        let peer = RawPeer(port: port)
        let sender = keyedSender(port)
        defer { EQTLinkSenderDestroy(sender) }
        connectRaw(sender, peer)
        // Request the end and push straight away, many times: whenever the push
        // lands first, no end marker may follow audio that is already flowing.
        let samples = [Float](repeating: 0.1, count: 128)
        for _ in 0 ..< 200 {
            EQTLinkSenderSetDelivering(sender, 0)
            EQTLinkSenderSetDelivering(sender, 1)
            EQTLinkSenderPush(sender, samples, 64, 2, mach_absolute_time())
        }
        wait("all audio", until: {
            peer.drain()
            return peer.sink.left.count == 200 * 64
        })
        usleep(150_000)         // a stale marker would be sent right after the audio
        peer.drain()
        if let last = peer.sink.headers.last {
            XCTAssertGreaterThan(last.frames, 0, "the stream must not end on a stale marker")
        }
    }

    func test_bareEndMarkers_cannotHoldTheLink() {
        let port = makePort()
        let h = Harness(port: port)
        XCTAssertEqual(EQTLinkReceiverStart(h.receiver), 0)

        let squatter = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(squatter) }
        var on: Int32 = 1
        setsockopt(squatter, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        a.sin_addr.s_addr = in_addr_t(0x7F00_0001).bigEndian
        _ = withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(squatter, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var marker = EQTLinkChunkHeader(magic: EQT_LINK_MAGIC, version: UInt16(EQT_LINK_VERSION), channels: 2,
                                        frames: 0, flags: EQT_LINK_FLAG_END_OF_STREAM, startFrame: 0, endHostTime: 0)
        for _ in 0 ..< 2 { _ = send(squatter, &marker, MemoryLayout<EQTLinkChunkHeader>.size, MSG_DONTWAIT) }
        wait("the caller to be refused", until: { h.receiverStats.rejectedCallers >= 1 })
        XCTAssertEqual(h.receiverStats.connections, 0)

        XCTAssertEqual(EQTLinkSenderStart(h.sender), 0)
        wait("the real sender", until: { h.receiverStats.connections == 1 })
    }

    func test_audioWithNoAppReachable_isReportedOnce_soTheRouteCanBeGivenBack() {
        final class Counter { var hits = 0 }
        let counter = Counter()
        let sender = keyedSender(makePort())      // nobody will ever listen
        defer { EQTLinkSenderDestroy(sender) }
        EQTLinkSenderSetUnreachableHandler(sender, 0.3, { context in
            Unmanaged<Counter>.fromOpaque(context!).takeUnretainedValue().hits += 1
        }, Unmanaged.passUnretained(counter).toOpaque())
        XCTAssertEqual(EQTLinkSenderStart(sender), 0)

        let block = [Float](repeating: 0.1, count: 960)
        let until = Date().addingTimeInterval(1.2)
        while Date() < until {
            EQTLinkSenderPush(sender, block, 480, 2, mach_absolute_time())
            usleep(10_000)
        }
        EQTLinkSenderStop(sender)
        XCTAssertEqual(counter.hits, 1)
    }

    /// What a suspended app looks like: the kernel completes the connection and
    /// buffers the audio, and nobody ever reads it or answers.
    func test_connectionNobodyAnswers_isReported_andKeptRetrying() {
        final class Counter { var hits = 0 }
        let counter = Counter()
        let port = makePort()
        let suspended = RawPeer(port: port)     // listening, never accepting
        let sender = keyedSender(port)
        defer {
            EQTLinkSenderDestroy(sender)
            _ = suspended
        }
        EQTLinkSenderSetUnreachableHandler(sender, 2.5, { context in
            Unmanaged<Counter>.fromOpaque(context!).takeUnretainedValue().hits += 1
        }, Unmanaged.passUnretained(counter).toOpaque())
        XCTAssertEqual(EQTLinkSenderStart(sender), 0)

        // Twice real speed: what counts is how much audio went unanswered.
        let block = [Float](repeating: 0.1, count: 1_920)
        var s = EQTLinkSenderStats()
        while s.pushedFrames < 158_400 {        // 3.3 s of audio
            EQTLinkSenderPush(sender, block, 960, 2, mach_absolute_time())
            usleep(10_000)
            EQTLinkSenderGetStats(sender, &s)
        }
        wait("the report", until: { counter.hits >= 1 })
        wait("a retry", until: {
            EQTLinkSenderGetStats(sender, &s)
            return s.connectAttempts >= 2
        })
        EQTLinkSenderStop(sender)
        XCTAssertEqual(counter.hits, 1, "connect() succeeding must not count as the app being alive")
        XCTAssertEqual(s.connects, 0, "it never proved itself, so it never counts as connected")
        XCTAssertEqual(s.sentFrames, 0, "and it never gets any audio")
    }

    /// This peer proved itself and keeps reading, so the send never blocks. Only the
    /// missing answers can end the connection, which is what a hung app looks like.
    /// Audio that went unanswered before it connected must not count against it.
    func test_aPeerThatReadsButNeverAnswers_getsItsFullAllowance_thenIsDropped() {
        let port = makePort()
        let sender = keyedSender(port)
        defer { EQTLinkSenderDestroy(sender) }
        XCTAssertEqual(EQTLinkSenderStart(sender), 0)
        let block = [Float](repeating: 0.1, count: 1_920)
        for _ in 0 ..< 110 {        // 105,600 frames with no app: over one link's allowance
            EQTLinkSenderPush(sender, block, 960, 2, mach_absolute_time())
            usleep(1_000)
        }
        usleep(30_000)
        let peer = RawPeer(port: port)
        defer { withExtendedLifetime(peer) {} }
        XCTAssertTrue(peer.acceptPeer())
        var s = EQTLinkSenderStats()
        wait("the connection", until: {
            EQTLinkSenderGetStats(sender, &s)
            return s.connected == 1
        })
        let atConnect = s.pushedFrames
        while s.connected == 1, s.pushedFrames - atConnect < 130_000 {
            EQTLinkSenderPush(sender, block, 960, 2, mach_absolute_time())
            peer.discardAvailable()
            usleep(5_000)
            EQTLinkSenderGetStats(sender, &s)
            if s.pushedFrames - atConnect < 81_600 {
                XCTAssertEqual(s.connected, 1, "a new connection must get its full allowance")
            }
        }
        wait("the silent connection to be dropped", until: {
            peer.discardAvailable()
            EQTLinkSenderGetStats(sender, &s)
            return s.connected == 0
        })
    }

    /// The usual real case: the output is already playing when the link comes up
    /// or comes back. The connection has to hold.
    func test_connectingWhileAudioIsAlreadyMoving_holdsTheLink() {
        let h = Harness(port: makePort())
        XCTAssertEqual(EQTLinkSenderStart(h.sender), 0)
        var frame = 0
        func play(_ frames: Int) {
            let end = frame + frames
            while frame < end {
                push(h, from: frame, frames: 960)
                frame += 960
                usleep(10_000)
            }
        }
        play(110_000)       // more unanswered audio than a stalled link is allowed
        XCTAssertEqual(EQTLinkReceiverStart(h.receiver), 0)
        play(60_000)
        XCTAssertEqual(h.senderStats.connected, 1)
        XCTAssertEqual(h.senderStats.connects, 1, "the link must not drop and reconnect")
        XCTAssertGreaterThan(h.receiverStats.receivedFrames, 24_000)
    }

    func test_silenceBetweenSounds_keepsAHealthyLink() {
        let h = Harness(port: makePort())
        connect(h)
        push(h, from: 0, frames: 4_800)
        wait("the first sound", until: { h.receiverStats.receivedFrames == 4_800 })
        usleep(150_000)
        push(h, from: 4_800, frames: 64)        // its pass consumes the app's answer
        wait("the tail", until: { h.receiverStats.receivedFrames == 4_864 })
        usleep(2_500_000)       // longer than a stalled link is allowed
        push(h, from: 4_864, frames: 4_800)
        wait("the second sound", until: { h.receiverStats.receivedFrames == 9_664 })
        usleep(200_000)
        XCTAssertEqual(h.senderStats.connects, 1)
    }

    /// Navigation prompts and notifications: short sounds with pauses between them.
    func test_shortSoundsWithPauses_addUpToAReport() {
        final class Counter { var hits = 0 }
        let counter = Counter()
        let port = makePort()
        let suspended = RawPeer(port: port)     // listening, never accepting
        let sender = keyedSender(port)
        defer {
            EQTLinkSenderDestroy(sender)
            withExtendedLifetime(suspended) {}
        }
        EQTLinkSenderSetUnreachableHandler(sender, 0.5, { context in
            Unmanaged<Counter>.fromOpaque(context!).takeUnretainedValue().hits += 1
        }, Unmanaged.passUnretained(counter).toOpaque())
        XCTAssertEqual(EQTLinkSenderStart(sender), 0)

        let block = [Float](repeating: 0.1, count: 1_920)
        func sound() {          // 0.3 s of audio
            for _ in 0 ..< 15 {
                EQTLinkSenderPush(sender, block, 960, 2, mach_absolute_time())
                usleep(2_000)
            }
        }
        sound()
        usleep(1_200_000)       // longer than the sender's "audio is moving" window
        XCTAssertEqual(counter.hits, 0, "one short sound is not a dead app")
        sound()
        wait("the report", until: { counter.hits == 1 })
    }

    func test_blockedSendAfterAudioStops_letsTheSenderSleep() {
        let port = makePort()
        let peer = RawPeer(port: port)
        let sender = keyedSender(port)
        defer {
            EQTLinkSenderDestroy(sender)
            withExtendedLifetime(peer) {}
        }
        connectRaw(sender, peer)
        let block = [Float](repeating: 0.1, count: 4_096)
        for _ in 0 ..< 30 {     // fills the socket, and the app never reads it
            EQTLinkSenderPush(sender, block, 2_048, 2, mach_absolute_time())
            usleep(2_000)
        }
        usleep(100_000)
        var s = EQTLinkSenderStats()
        EQTLinkSenderGetStats(sender, &s)
        XCTAssertLessThan(s.sentFrames, s.pushedFrames, "the send should be blocked")

        wait("the blocked connection to be dropped", until: {
            EQTLinkSenderGetStats(sender, &s)
            return s.connected == 0
        })
        usleep(300_000)
        EQTLinkSenderGetStats(sender, &s)
        let before = s.wakeups
        usleep(600_000)
        EQTLinkSenderGetStats(sender, &s)
        XCTAssertLessThanOrEqual(s.wakeups - before, 2, "an idle phone must not be kept awake")
    }

    func test_aLinkThatJustCameUp_getsAMomentToAnswer() {
        final class Counter { var hits = 0 }
        let counter = Counter()
        let port = makePort()
        let sender = keyedSender(port)
        defer { EQTLinkSenderDestroy(sender) }
        EQTLinkSenderSetUnreachableHandler(sender, 0.5, { context in
            Unmanaged<Counter>.fromOpaque(context!).takeUnretainedValue().hits += 1
        }, Unmanaged.passUnretained(counter).toOpaque())
        XCTAssertEqual(EQTLinkSenderStart(sender), 0)
        let block = [Float](repeating: 0.1, count: 1_920)
        for _ in 0 ..< 24 {     // 23,040 frames: almost the whole allowance, with no app
            EQTLinkSenderPush(sender, block, 960, 2, mach_absolute_time())
        }
        let peer = RawPeer(port: port)          // now the app appears
        peer.acceptPeer()
        var s = EQTLinkSenderStats()
        wait("connection", until: {
            EQTLinkSenderGetStats(sender, &s)
            return s.connected == 1
        })
        for _ in 0 ..< 2 {      // crosses the limit just after connecting
            EQTLinkSenderPush(sender, block, 960, 2, mach_absolute_time())
        }
        usleep(60_000)
        XCTAssertEqual(counter.hits, 0, "the app has not had a chance to answer yet")
        peer.drain()            // its answer
        usleep(300_000)         // past the wait: an ignored answer would report now
        XCTAssertEqual(counter.hits, 0)
        withExtendedLifetime(peer) {}
    }

    func test_anAnswerWaitingToBeRead_preventsAFalseReport() {
        final class Counter { var hits = 0 }
        let counter = Counter()
        let port = makePort()
        let peer = RawPeer(port: port)
        let sender = keyedSender(port)
        defer {
            EQTLinkSenderDestroy(sender)
            withExtendedLifetime(peer) {}
        }
        EQTLinkSenderSetUnreachableHandler(sender, 0.5, { context in
            Unmanaged<Counter>.fromOpaque(context!).takeUnretainedValue().hits += 1
        }, Unmanaged.passUnretained(counter).toOpaque())
        connectRaw(sender, peer)
        let block = [Float](repeating: 0.1, count: 1_920)
        for _ in 0 ..< 21 {     // past a new link's grace, still under the limit
            EQTLinkSenderPush(sender, block, 960, 2, mach_absolute_time())
        }
        usleep(20_000)          // its throttled read has just run
        peer.answerOnce()
        for _ in 0 ..< 5 {      // crosses the limit while that answer sits unread
            EQTLinkSenderPush(sender, block, 960, 2, mach_absolute_time())
        }
        usleep(350_000)         // past the wait
        XCTAssertEqual(counter.hits, 0, "the waiting answer proves the app is alive")
    }

    /// The app was suspended, then opened with nothing playing, so it has had no
    /// audio to answer. The next sound must not end the session or drop the link.
    func test_leftoverCount_doesNotEndAHealthyLink_whenTheNextSoundStarts() {
        final class Counter { var hits = 0 }
        let counter = Counter()
        let port = makePort()
        let peer = RawPeer(port: port)
        let sender = keyedSender(port)
        defer {
            EQTLinkSenderDestroy(sender)
            withExtendedLifetime(peer) {}
        }
        EQTLinkSenderSetUnreachableHandler(sender, 0.5, { context in
            Unmanaged<Counter>.fromOpaque(context!).takeUnretainedValue().hits += 1
        }, Unmanaged.passUnretained(counter).toOpaque())
        connectRaw(sender, peer)
        let block = [Float](repeating: 0.1, count: 1_920)
        for _ in 0 ..< 24 {     // 23,040 frames, just under the limit, unanswered
            EQTLinkSenderPush(sender, block, 960, 2, mach_absolute_time())
        }
        usleep(300_000)         // the sender goes idle on an old connection
        EQTLinkSenderPush(sender, block, 960, 2, mach_absolute_time())     // crosses it
        usleep(40_000)
        XCTAssertEqual(counter.hits, 0, "the app needs a moment to hear this sound")
        peer.drain()
        usleep(300_000)
        XCTAssertEqual(counter.hits, 0, "it answered in time")
        var s = EQTLinkSenderStats()
        EQTLinkSenderGetStats(sender, &s)
        XCTAssertEqual(s.connects, 1)
    }

    /// The count can already be full when a link comes up with nothing playing.
    /// The app can't answer audio it never got, so the link waits to be given some.
    func test_aLinkGivenNoAudioYet_isNotJudged_untilItHasSome() {
        final class Counter { var hits = 0 }
        let counter = Counter()
        let port = makePort()
        let sender = keyedSender(port)
        defer { EQTLinkSenderDestroy(sender) }
        EQTLinkSenderSetUnreachableHandler(sender, 0.5, { context in
            Unmanaged<Counter>.fromOpaque(context!).takeUnretainedValue().hits += 1
        }, Unmanaged.passUnretained(counter).toOpaque())
        XCTAssertEqual(EQTLinkSenderStart(sender), 0)
        let block = [Float](repeating: 0.1, count: 1_920)
        for _ in 0 ..< 24 {     // 23,040 frames, just under the limit, with no app
            EQTLinkSenderPush(sender, block, 960, 2, mach_absolute_time())
        }
        usleep(50_000)
        EQTLinkSenderSetDelivering(sender, 0)
        usleep(1_200_000)       // audio has stopped moving, so the sender parks
        XCTAssertEqual(counter.hits, 0)

        let peer = RawPeer(port: port)          // the app opens, with nothing playing
        // This block crosses the limit. The same pass connects and starts at the
        // present, so the block itself is never sent.
        EQTLinkSenderPush(sender, block, 960, 2, mach_absolute_time())
        guard peer.acceptPeer() else { return XCTFail("the push must wake the sender to connect") }
        var s = EQTLinkSenderStats()
        wait("connection", until: {
            EQTLinkSenderGetStats(sender, &s)
            return s.connected == 1
        })
        usleep(350_000)         // past the answer wait
        EQTLinkSenderGetStats(sender, &s)
        XCTAssertEqual(s.sentFrames, 0, "the link has not carried any audio")
        XCTAssertEqual(counter.hits, 0, "the app was given nothing to answer")

        // Now it has audio and still says nothing, so the verdict is real.
        EQTLinkSenderPush(sender, block, 960, 2, mach_absolute_time())
        wait("the report", until: { counter.hits == 1 })
        withExtendedLifetime(peer) {}
    }

    /// The last push can land after the pump found the ring empty, and before it
    /// looks for a stop. That audio must still go out ahead of the end marker.
    func test_endMarker_cannotOvertakeAPushThatLandedJustBeforeIt() {
        let port = makePort()
        let peer = RawPeer(port: port)
        let sender = keyedSender(port)
        defer {
            EQTTestSetPumpDrainedHook(nil)
            EQTLinkSenderDestroy(sender)
            withExtendedLifetime(peer) {}
        }
        connectRaw(sender, peer)
        usleep(50_000)          // let it finish connecting and go to sleep

        EQTTestSetPumpDrainedHook { sender in
            var stats = EQTLinkSenderStats()
            EQTLinkSenderGetStats(sender, &stats)
            guard stats.pushedFrames == 64 else { return }      // after the first push only
            EQTTestSetPumpDrainedHook(nil)
            let last = [Float](repeating: 0.2, count: 256)
            EQTLinkSenderPush(sender, last, 128, 2, mach_absolute_time())
            EQTLinkSenderSetDelivering(sender, 0)
        }
        let first = [Float](repeating: 0.1, count: 128)
        EQTLinkSenderPush(sender, first, 64, 2, mach_absolute_time())

        wait("the audio, then the marker", until: {
            peer.drain()
            return peer.sink.headers.count >= 3
        })
        XCTAssertEqual(peer.sink.headers.map(\.frames), [64, 128, 0], "the marker must come last")
        XCTAssertEqual(peer.sink.headers.last?.flags, EQT_LINK_FLAG_END_OF_STREAM)
    }

    func test_healthyApp_isNeverReportedAsUnreachable() {
        final class Counter { var hits = 0 }
        let counter = Counter()
        let h = Harness(port: makePort())
        EQTLinkSenderSetUnreachableHandler(h.sender, 0.6, { context in
            Unmanaged<Counter>.fromOpaque(context!).takeUnretainedValue().hits += 1
        }, Unmanaged.passUnretained(counter).toOpaque())
        connect(h)

        var frame = 0
        let until = Date().addingTimeInterval(1.6)
        while Date() < until {
            push(h, from: frame, frames: 480)
            frame += 480
            usleep(10_000)
        }
        XCTAssertEqual(counter.hits, 0, "the app's answers must keep the route alive")
        XCTAssertEqual(h.senderStats.connects, 1)
    }

    /// The sender is blocked mid-send, so it cannot act on the stop until the app
    /// reads. A push landing in that window must not cancel the end of the stream.
    func test_pushDuringAStop_cannotCancelTheEndMarker() {
        let port = makePort()
        let peer = RawPeer(port: port)
        let sender = keyedSender(port)
        defer {
            EQTLinkSenderDestroy(sender)
            withExtendedLifetime(peer) {}
        }
        connectRaw(sender, peer)
        let block = [Float](repeating: 0.1, count: 4_096)
        for _ in 0 ..< 30 {
            EQTLinkSenderPush(sender, block, 2_048, 2, mach_absolute_time())
            usleep(2_000)
        }
        usleep(50_000)
        var s = EQTLinkSenderStats()
        EQTLinkSenderGetStats(sender, &s)
        XCTAssertLessThan(s.sentFrames, s.pushedFrames, "the sender must still be mid-send")

        EQTLinkSenderSetDelivering(sender, 0)
        EQTLinkSenderPush(sender, block, 2_048, 2, mach_absolute_time())

        let total = 31 * 2_048
        wait("all the audio, then the end marker", timeout: 8, until: {
            peer.drain()
            return peer.sink.left.count == total
                && peer.sink.headers.last?.flags == EQT_LINK_FLAG_END_OF_STREAM
        })
    }

    func test_aLatePush_doesNotRestartDelivery() {
        let h = Harness(port: makePort())       // nobody is listening
        XCTAssertEqual(EQTLinkSenderStart(h.sender), 0)
        EQTLinkSenderSetDelivering(h.sender, 0)
        push(h, from: 0, frames: 64)
        usleep(1_200_000)       // the "audio is moving" window passes
        let before = h.senderStats.connectAttempts
        usleep(2_300_000)       // longer than the slowest retry timer
        XCTAssertEqual(h.senderStats.connectAttempts, before)
    }

    func test_noAudioFlowing_isNeverReportedAsUnreachable() {
        final class Counter { var hits = 0 }
        let counter = Counter()
        let sender = keyedSender(makePort())
        defer { EQTLinkSenderDestroy(sender) }
        EQTLinkSenderSetUnreachableHandler(sender, 0.1, { context in
            Unmanaged<Counter>.fromOpaque(context!).takeUnretainedValue().hits += 1
        }, Unmanaged.passUnretained(counter).toOpaque())
        XCTAssertEqual(EQTLinkSenderStart(sender), 0)
        usleep(500_000)
        EQTLinkSenderStop(sender)
        XCTAssertEqual(counter.hits, 0, "a selected output with nothing playing is not a failure")
    }

    func test_audioAfterADeliveryStop_wakesTheSenderAndReconnects() {
        let h = Harness(port: makePort())
        XCTAssertEqual(EQTLinkSenderStart(h.sender), 0)
        EQTLinkSenderSetDelivering(h.sender, 0)
        usleep(150_000)         // parked with no timeout
        XCTAssertEqual(EQTLinkReceiverStart(h.receiver), 0)
        push(h, from: 0, frames: 64)
        wait("the push to wake it and reconnect", until: { h.receiverStats.hasPeer == 1 })
    }

    // MARK: What the sender actually puts on the wire

    /// A plain listener that receives the raw stream and parses it with the codec.
    private final class RawPeer {
        final class Sink {
            var headers: [EQTLinkChunkHeader] = []
            var left: [Float] = []
            var right: [Float] = []
        }

        let listener: Int32
        var peer: Int32 = -1
        let sink = Sink()
        private var buffer = [UInt8](repeating: 0, count: 65_536)
        private var length = 0
        private(set) var skipped = 0

        init(port: UInt16) {
            listener = socket(AF_INET, SOCK_STREAM, 0)
            var one: Int32 = 1
            setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
            var small: Int32 = 4_096
            setsockopt(listener, SOL_SOCKET, SO_RCVBUF, &small, socklen_t(MemoryLayout<Int32>.size))
            var a = sockaddr_in()
            a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            a.sin_family = sa_family_t(AF_INET)
            a.sin_port = port.bigEndian
            a.sin_addr.s_addr = in_addr_t(0x7F00_0001).bigEndian
            _ = withUnsafePointer(to: &a) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            listen(listener, 1)
        }

        deinit {
            if peer >= 0 { close(peer) }
            close(listener)
        }

        /// Accepts the sender and proves it holds the key, as the real app does. A
        /// connection the sender already gave up on is skipped.
        @discardableResult
        func acceptPeer(timeout: TimeInterval = 5) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while deadline.timeIntervalSinceNow > 0 {
                var p = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                guard poll(&p, 1, Int32(deadline.timeIntervalSinceNow * 1_000) + 1) > 0 else { return false }
                let fd = accept(listener, nil, nil)
                guard fd >= 0 else { continue }
                var on: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                if Handshake.serve(fd, key: LinkTestKey.real) {
                    peer = fd
                    let flags = fcntl(peer, F_GETFL, 0)
                    _ = fcntl(peer, F_SETFL, flags | O_NONBLOCK)
                    return true
                }
                close(fd)
            }
            return false
        }

        /// What the real receiver sends while it is alive.
        func answerOnce() {
            var answer: UInt8 = 0xA5
            _ = send(peer, &answer, 1, MSG_DONTWAIT)
        }

        /// Reads and throws away what arrived, without answering.
        func discardAvailable() {
            var scratch = [UInt8](repeating: 0, count: 16_384)
            while recv(peer, &scratch, scratch.count, 0) > 0 {}
        }

        /// Reads whatever is available, in deliberately small pieces.
        func drain(pieceBytes: Int = 1_453) {
            while true {
                let room = min(pieceBytes, buffer.count - length)
                let n = buffer.withUnsafeMutableBytes { recv(peer, $0.baseAddress! + length, room, 0) }
                guard n > 0 else { return }
                var answer: UInt8 = 0xA5        // what the real receiver does
                _ = send(peer, &answer, 1, MSG_DONTWAIT)
                length += n
                let context = Unmanaged.passUnretained(sink).toOpaque()
                buffer.withUnsafeMutableBufferPointer { p in
                    skipped += EQTLinkConsume(p.baseAddress!, &length, { ctx, header, payload in
                        let s = Unmanaged<Sink>.fromOpaque(ctx!).takeUnretainedValue()
                        let h = header!.pointee
                        s.headers.append(h)
                        for k in 0 ..< Int(h.frames) {
                            var l: Float = 0
                            var r: Float = 0
                            memcpy(&l, payload! + k * 8, 4)
                            memcpy(&r, payload! + k * 8 + 4, 4)
                            s.left.append(l)
                            s.right.append(r)
                        }
                    }, context)
                }
            }
        }
    }

    private func connectRaw(_ sender: OpaquePointer, _ peer: RawPeer) {
        XCTAssertEqual(EQTLinkSenderStart(sender), 0)
        XCTAssertTrue(peer.acceptPeer())
        var s = EQTLinkSenderStats()
        wait("sender connected", until: {
            EQTLinkSenderGetStats(sender, &s)
            return s.connected == 1
        })
    }

    /// The PLL depends on these stamps: a chunk that ends before the newest
    /// write must carry the time ITS last frame was written.
    func test_chunkStamps_interpolateBackFromTheNewestWrite() {
        let port = makePort()
        let peer = RawPeer(port: port)
        let sender = keyedSender(port)
        defer { EQTLinkSenderDestroy(sender) }
        connectRaw(sender, peer)

        let frames = 5_000
        let host: UInt64 = 900_000_000
        let samples = [Float](repeating: 0.1, count: frames * 2)
        EQTLinkSenderPush(sender, samples, UInt32(frames), 2, host)
        wait("all chunks", until: {
            peer.drain()
            return peer.sink.left.count == frames
        })

        let ticksPerFrame = RingReader.hostTicksPerSecond / EQT_LINK_SAMPLE_RATE
        var end = 0
        for h in peer.sink.headers {
            XCTAssertEqual(Int(h.startFrame), end)
            end += Int(h.frames)
            XCTAssertLessThanOrEqual(h.frames, EQT_LINK_MAX_CHUNK_FRAMES)
            let expected = Double(host) - Double(frames - end) * ticksPerFrame
            XCTAssertEqual(Double(h.endHostTime), expected, accuracy: 2, "chunk ending at frame \(end)")
        }
        XCTAssertEqual(end, frames)
        XCTAssertGreaterThanOrEqual(peer.sink.headers.count, 3)
    }

    /// When the socket fills, send() stops mid-chunk and often mid-float. Resuming
    /// anywhere but the exact byte would shift every later sample.
    func test_partialSends_neverShiftTheStream() {
        let port = makePort()
        let peer = RawPeer(port: port)
        let sender = keyedSender(port)
        defer { EQTLinkSenderDestroy(sender) }
        connectRaw(sender, peer)

        // Far more than the socket buffers hold, while nothing is being read.
        let total = 60_000
        var pushed = 0
        var block = [Float](repeating: 0, count: 2 * 499)
        while pushed < total {
            let n = min(499, total - pushed)
            for i in 0 ..< n {
                block[i * 2] = Float(pushed + i)
                block[i * 2 + 1] = -Float(pushed + i)
            }
            EQTLinkSenderPush(sender, block, UInt32(n), 2, mach_absolute_time())
            pushed += n
        }
        usleep(200_000)

        wait("the backlog to drain", timeout: 20, until: {
            peer.drain()
            usleep(1_000)
            return peer.sink.left.count >= total
        })
        var s = EQTLinkSenderStats()
        EQTLinkSenderGetStats(sender, &s)
        XCTAssertEqual(s.droppedFrames, 0, "the backlog fits the send ring")
        XCTAssertEqual(peer.skipped, 0, "the stream desynchronised")
        XCTAssertEqual(peer.sink.left.count, total)
        for i in stride(from: 0, to: total, by: 1) where peer.sink.left[i] != Float(i) || peer.sink.right[i] != -Float(i) {
            XCTFail("frame \(i) is \(peer.sink.left[i]), \(peer.sink.right[i])")
            break
        }
    }

    /// Real sockets and threads into the real reader: a tone in, the same tone out.
    ///
    /// The clock is simulated and each block waits for its delivery, so CPU load
    /// on the machine running the tests cannot fail it. Delivery jitter has its
    /// own deterministic coverage in LinkClockTests.
    func test_endToEnd_toneThroughSocketAndReader_comesOutClean() {
        let h = Harness(port: makePort())
        connect(h)
        let clock = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        clock.initialize(to: 1_000_000)
        defer { clock.deallocate() }
        let reader = RingReader(header: UnsafePointer(h.ring))
        reader.hostClockOverride = clock
        reader.configure(outputSampleRate: 48_000, outputMaxFrames: 4_096, outputBufferFrames: 480)

        func ticks(_ t: Double) -> UInt64 { UInt64(1_000_000 + t * RingReader.hostTicksPerSecond) }
        let block = 512
        let cps = 997.0 / 48_000
        let out = PlanarBuffer(channels: 2, frames: 8_192)
        var left: [Float] = []
        var frame = 0
        var renders = 0
        var samples = [Float](repeating: 0, count: block * 2)
        var nextIO = 0.0
        var nextRender = 0.0005

        while min(nextIO, nextRender) < 8 {
            if nextIO <= nextRender {
                clock.pointee = ticks(nextIO)
                for i in 0 ..< block {
                    let v = sin(2 * Double.pi * cps * Double(frame + i))
                    samples[i * 2] = Float(0.5 * v)
                    samples[i * 2 + 1] = Float(0.25 * v)
                }
                EQTLinkSenderPush(h.sender, samples, UInt32(block), 2, ticks(nextIO))
                frame += block
                let expected = UInt64(frame)
                wait("block delivery", timeout: 20, until: { h.receiverStats.receivedFrames == expected })
                nextIO = Double(frame) / 48_000
            } else {
                clock.pointee = ticks(nextRender)
                reader.render(into: out.pointers, frameCount: 480)
                out.store(0, into: &left, count: 480)
                renders += 1
                nextRender = 0.0005 + Double(renders) * 0.01
            }
        }

        let st = reader.stats()
        print("socket end-to-end:", st.lock, "fill", st.fillFrames, "underruns", st.underruns, "resyncs", st.resyncs)
        XCTAssertEqual(st.lock, .locked)
        XCTAssertEqual(st.underruns, 0)
        XCTAssertEqual(st.resyncs, 1)
        XCTAssertEqual(h.receiverStats.skippedBytes, 0)
        XCTAssertTrue(left.allSatisfy(\.isFinite))
        let peak = left.suffix(48_000).map { abs($0) }.max() ?? 0
        XCTAssertEqual(Double(peak), 0.5, accuracy: 0.001, "the tone must come out at its level")
        let tail = Array(left.suffix(4_096))
        let r = Fixtures.fitSineFreeFrequency(tail, nominal: cps, spanPPM: 300)
        print(String(format: "socket end-to-end: THD+N %.1f dB, offset %.1f ppm", r.fit.thdPlusNoiseDB, r.offsetPPM))
        XCTAssertLessThan(r.fit.thdPlusNoiseDB, -100, "the tone came out damaged")
        XCTAssertLessThan(abs(r.offsetPPM), 5, "the pitch moved")
    }
}
