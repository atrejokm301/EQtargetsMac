//
//  LinkAuthTests.swift
//  EQtargets (iOS)
//
//  Any app on the phone can reach the loopback link. These tests play that app.
//  The promises: it can't receive the system's audio, it can't feed its own in,
//  and it can't disturb the real link while pretending to be part of it.
//

import Darwin
import XCTest

final class LinkAuthTests: XCTestCase {

    private static var nextPort: UInt16 = 48_600

    private func makePort() -> UInt16 {
        Self.nextPort += 1
        return Self.nextPort
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

    private func stats(_ s: OpaquePointer) -> EQTLinkSenderStats {
        var out = EQTLinkSenderStats()
        EQTLinkSenderGetStats(s, &out)
        return out
    }

    private func stats(receiver r: OpaquePointer) -> EQTLinkReceiverStats {
        var out = EQTLinkReceiverStats()
        EQTLinkReceiverGetStats(r, &out)
        return out
    }

    private func pushAudio(_ s: OpaquePointer, frames: Int = 480) {
        let block = [Float](repeating: 0.2, count: frames * 2)
        EQTLinkSenderPush(s, block, UInt32(frames), 2, mach_absolute_time())
    }

    /// Plays the app that took the port.
    private final class FakeApp {
        var listener: Int32

        init(port: UInt16) {
            listener = socket(AF_INET, SOCK_STREAM, 0)
            var one: Int32 = 1
            setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
            var a = sockaddr_in()
            a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            a.sin_family = sa_family_t(AF_INET)
            a.sin_port = port.bigEndian
            a.sin_addr.s_addr = in_addr_t(0x7F00_0001).bigEndian
            _ = withUnsafePointer(to: &a) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            listen(listener, 4)
        }

        deinit { closeListener() }

        /// Gives the port up, keeping any connection it already accepted.
        func closeListener() {
            if listener >= 0 { close(listener) }
            listener = -1
        }

        func nextCaller(timeout: TimeInterval = 3) -> Int32? {
            var p = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, Int32(timeout * 1_000)) > 0 else { return nil }
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return nil }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            return fd
        }
    }

    /// The real receiver and its ring.
    private final class App {
        let memory: UnsafeMutableRawPointer
        let ring: UnsafeMutablePointer<EQTRingHeader>
        let receiver: OpaquePointer

        init(port: UInt16, key: [UInt8]? = LinkTestKey.real) {
            memory = .allocate(byteCount: Int(EQTRingTotalBytes()), alignment: 4096)
            ring = memory.bindMemory(to: EQTRingHeader.self, capacity: 1)
            EQTLinkRingFormat(ring)
            receiver = EQTLinkReceiverCreate(port, ring)!
            if let key { EQTLinkReceiverSetKey(receiver, key) }
            XCTAssertEqual(EQTLinkReceiverStart(receiver), 0)
        }

        deinit {
            EQTLinkReceiverDestroy(receiver)
            memory.deallocate()
        }
    }

    // MARK: The extension's side: a fake app must not get the audio

    func test_theRealSender_passesAnIndependentServer_thenSendsAudio() throws {
        let port = makePort()
        let app = FakeApp(port: port)
        let sender = keyedSender(port)
        defer { EQTLinkSenderDestroy(sender) }
        XCTAssertEqual(EQTLinkSenderStart(sender), 0)
        let caller = try XCTUnwrap(app.nextCaller())
        defer { close(caller) }
        XCTAssertTrue(Handshake.serve(caller, key: LinkTestKey.real))
        wait("the sender to accept the proof", until: { stats(sender).connected == 1 })

        pushAudio(sender)
        let header = try XCTUnwrap(Handshake.read(caller, MemoryLayout<EQTLinkChunkHeader>.size))
        let magic = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        XCTAssertEqual(magic, EQT_LINK_MAGIC, "audio follows the proof")
    }

    func test_aFakeAppWithoutTheKey_getsNoAudio() throws {
        let port = makePort()
        let app = FakeApp(port: port)
        let sender = keyedSender(port)
        defer { EQTLinkSenderDestroy(sender) }
        XCTAssertEqual(EQTLinkSenderStart(sender), 0)
        pushAudio(sender)
        let caller = try XCTUnwrap(app.nextCaller())
        defer { close(caller) }
        let hello = try XCTUnwrap(Handshake.read(caller, Handshake.helloBytes))
        let client = Array(hello[4...]), server = Handshake.nonce()
        Handshake.write(caller, Handshake.serverMagic + server
                        + Handshake.proof(LinkTestKey.wrong, Handshake.serverLabel,
                                          channel: Handshake.channel(of: caller, isClient: false), client: client, server: server))
        for _ in 0 ..< 10 {
            pushAudio(sender)
            usleep(5_000)
        }
        XCTAssertEqual(Handshake.bytesUntilClosed(caller), 0, "it must hang up without sending anything more")
        XCTAssertEqual(stats(sender).connected, 0)
        XCTAssertEqual(stats(sender).sentFrames, 0)
    }

    /// Also what a suspended app looks like: connected in the kernel, never answering.
    func test_aFakeAppThatNeverAnswers_getsNoAudio() throws {
        let port = makePort()
        let app = FakeApp(port: port)
        let sender = keyedSender(port)
        defer { EQTLinkSenderDestroy(sender) }
        XCTAssertEqual(EQTLinkSenderStart(sender), 0)
        let caller = try XCTUnwrap(app.nextCaller())
        defer { close(caller) }
        for _ in 0 ..< 20 {
            pushAudio(sender)
            usleep(5_000)
        }
        XCTAssertEqual(Handshake.bytesUntilClosed(caller), Handshake.helloBytes, "the hello and nothing else")
        XCTAssertEqual(stats(sender).sentFrames, 0)
    }

    func test_aFakeAppReplayingARecordedAnswer_getsNoAudio() throws {
        let port = makePort()
        let app = FakeApp(port: port)
        let sender = keyedSender(port)
        defer { EQTLinkSenderDestroy(sender) }
        XCTAssertEqual(EQTLinkSenderStart(sender), 0)

        // Record a genuine answer.
        let first = try XCTUnwrap(app.nextCaller())
        let hello = try XCTUnwrap(Handshake.read(first, Handshake.helloBytes))
        let client = Array(hello[4...]), server = Handshake.nonce()
        let recorded = Handshake.serverMagic + server
            + Handshake.proof(LinkTestKey.real, Handshake.serverLabel,
                              channel: Handshake.channel(of: first, isClient: false), client: client, server: server)
        Handshake.write(first, recorded)
        XCTAssertNotNil(Handshake.read(first, Handshake.clientBytes))
        wait("the first connection", until: { stats(sender).connected == 1 })
        close(first)
        wait("the sender to notice", until: {
            pushAudio(sender)
            usleep(2_000)
            return stats(sender).connected == 0
        })
        let sentBefore = stats(sender).sentFrames

        // Play it back on the next connection, which has a different nonce.
        let second = try XCTUnwrap(app.nextCaller())
        defer { close(second) }
        let nextHello = try XCTUnwrap(Handshake.read(second, Handshake.helloBytes))
        XCTAssertNotEqual(Array(nextHello[4...]), client, "the extension's nonce must be fresh")
        Handshake.write(second, recorded)
        pushAudio(sender)
        XCTAssertEqual(Handshake.bytesUntilClosed(second), 0, "an old answer proves nothing")
        XCTAssertEqual(stats(sender).connected, 0)
        XCTAssertEqual(stats(sender).sentFrames, sentBefore)
    }

    /// The client's proof must not double as the server's.
    func test_aFakeAppReflectingTheOtherRolesProof_getsNoAudio() throws {
        let port = makePort()
        let app = FakeApp(port: port)
        let sender = keyedSender(port)
        defer { EQTLinkSenderDestroy(sender) }
        XCTAssertEqual(EQTLinkSenderStart(sender), 0)
        let caller = try XCTUnwrap(app.nextCaller())
        defer { close(caller) }
        let hello = try XCTUnwrap(Handshake.read(caller, Handshake.helloBytes))
        let client = Array(hello[4...]), server = Handshake.nonce()
        Handshake.write(caller, Handshake.serverMagic + server
                        + Handshake.proof(LinkTestKey.real, Handshake.clientLabel,
                                          channel: Handshake.channel(of: caller, isClient: false), client: client, server: server))
        pushAudio(sender)
        XCTAssertEqual(Handshake.bytesUntilClosed(caller), 0)
        XCTAssertEqual(stats(sender).sentFrames, 0)
    }

    func test_aSenderWithNoKey_neverConnects() {
        let port = makePort()
        let app = FakeApp(port: port)
        let sender = EQTLinkSenderCreate(port)!
        defer { EQTLinkSenderDestroy(sender) }
        XCTAssertEqual(EQTLinkSenderStart(sender), 0)
        pushAudio(sender)
        XCTAssertNil(app.nextCaller(timeout: 0.4), "no key, no connection")
        XCTAssertEqual(stats(sender).connectAttempts, 0)
    }

    func test_onlyTheFirstKeyCounts() throws {
        let port = makePort()
        let app = FakeApp(port: port)
        let sender = keyedSender(port)
        defer { EQTLinkSenderDestroy(sender) }
        EQTLinkSenderSetKey(sender, LinkTestKey.wrong)
        XCTAssertEqual(EQTLinkSenderStart(sender), 0)
        let caller = try XCTUnwrap(app.nextCaller())
        defer { close(caller) }
        XCTAssertTrue(Handshake.serve(caller, key: LinkTestKey.real))
    }

    // MARK: The app's side: a fake extension must not get audio played

    func test_theRealReceiver_acceptsAnIndependentClient_andPlaysItsAudio() throws {
        let port = makePort()
        let app = App(port: port)
        let fd = dialLoopback(port)
        defer { close(fd) }
        XCTAssertNotNil(Handshake.prove(fd, key: LinkTestKey.real))
        wait("the peer", until: { stats(receiver: app.receiver).hasPeer == 1 })
        Handshake.write(fd, Handshake.audioChunk(start: 0, frames: 64))
        wait("the audio", until: { stats(receiver: app.receiver).receivedFrames == 64 })
    }

    func test_aCallerWithoutTheKey_cannotFeedAudioIn() throws {
        let port = makePort()
        let app = App(port: port)
        let fd = dialLoopback(port)
        defer { close(fd) }
        XCTAssertNotNil(Handshake.prove(fd, key: LinkTestKey.wrong))
        Handshake.write(fd, Handshake.audioChunk(start: 0, frames: 64))
        wait("the refusal", until: { stats(receiver: app.receiver).rejectedCallers >= 1 })
        usleep(50_000)
        let s = stats(receiver: app.receiver)
        XCTAssertEqual(s.hasPeer, 0)
        XCTAssertEqual(s.connections, 0)
        XCTAssertEqual(s.receivedFrames, 0)
        XCTAssertEqual(EQTRingLoadWriteHead(app.ring), 0, "nothing may reach the ring")
    }

    func test_aCallerThatSkipsTheHandshake_cannotFeedAudioIn() {
        let port = makePort()
        let app = App(port: port)
        let fd = dialLoopback(port)
        defer { close(fd) }
        Handshake.write(fd, Handshake.audioChunk(start: 0, frames: 64))
        wait("the refusal", until: { stats(receiver: app.receiver).rejectedCallers >= 1 })
        usleep(50_000)
        let s = stats(receiver: app.receiver)
        XCTAssertEqual(s.hasPeer, 0)
        XCTAssertEqual(s.receivedFrames, 0)
        XCTAssertEqual(EQTRingLoadWriteHead(app.ring), 0)
    }

    func test_aCallerReplayingARecordedProof_isRefused() throws {
        let port = makePort()
        let app = App(port: port)
        let first = dialLoopback(port)
        let run = try XCTUnwrap(Handshake.prove(first, key: LinkTestKey.real))
        wait("the first peer", until: { stats(receiver: app.receiver).connections == 1 })
        close(first)
        wait("the peer to leave", until: { stats(receiver: app.receiver).hasPeer == 0 })

        // Same client nonce and same proof, against the app's new nonce.
        let second = dialLoopback(port)
        defer { close(second) }
        Handshake.write(second, Handshake.helloMagic + run.client)
        let reply = try XCTUnwrap(Handshake.read(second, Handshake.serverBytes))
        XCTAssertNotEqual(Array(reply[4 ..< 36]), run.server, "the app's nonce must be fresh")
        Handshake.write(second, Handshake.clientMagic + run.sentProof)
        wait("the refusal", until: { stats(receiver: app.receiver).rejectedCallers >= 1 })
        XCTAssertEqual(stats(receiver: app.receiver).hasPeer, 0)
        XCTAssertEqual(stats(receiver: app.receiver).connections, 1)
    }

    /// The app's own proof must not be accepted back from a caller.
    func test_aCallerReflectingTheServersProof_isRefused() throws {
        let port = makePort()
        let app = App(port: port)
        let fd = dialLoopback(port)
        defer { close(fd) }
        Handshake.write(fd, Handshake.helloMagic + Handshake.nonce())
        let reply = try XCTUnwrap(Handshake.read(fd, Handshake.serverBytes))
        Handshake.write(fd, Handshake.clientMagic + Array(reply[36...]))
        wait("the refusal", until: { stats(receiver: app.receiver).rejectedCallers >= 1 })
        XCTAssertEqual(stats(receiver: app.receiver).hasPeer, 0)
    }

    /// `hasPeer` keeps the audio engine running, so an unproven caller must not set it.
    func test_aCallerStillProvingItself_isNotAPeer() throws {
        let port = makePort()
        let app = App(port: port)
        let fd = dialLoopback(port)
        defer { close(fd) }
        Handshake.write(fd, Handshake.helloMagic + Handshake.nonce())
        XCTAssertNotNil(Handshake.read(fd, Handshake.serverBytes))
        usleep(30_000)
        XCTAssertEqual(stats(receiver: app.receiver).hasPeer, 0)
        XCTAssertEqual(stats(receiver: app.receiver).connections, 0)
    }

    func test_anUnfinishedHandshake_isHungUpOn() {
        let port = makePort()
        let app = App(port: port)
        let fd = dialLoopback(port)
        defer { close(fd) }
        XCTAssertEqual(Handshake.bytesUntilClosed(fd, timeout: 2), 0, "a silent caller can't stay")
        XCTAssertGreaterThanOrEqual(stats(receiver: app.receiver).rejectedCallers, 1)
    }

    func test_aHostileCaller_cannotDisturbThePlayingPeer() {
        let port = makePort()
        let app = App(port: port)
        let sender = keyedSender(port)
        defer { EQTLinkSenderDestroy(sender) }
        XCTAssertEqual(EQTLinkSenderStart(sender), 0)
        wait("the link", until: { stats(receiver: app.receiver).hasPeer == 1 && stats(sender).connected == 1 })
        pushAudio(sender)
        wait("first audio", until: { stats(receiver: app.receiver).receivedFrames == 480 })

        let hostile = dialLoopback(port)
        defer { close(hostile) }
        Handshake.write(hostile, Handshake.audioChunk(start: 9_000, frames: 64))
        wait("the refusal", until: { stats(receiver: app.receiver).rejectedCallers >= 1 })

        pushAudio(sender)
        wait("audio still arriving", until: { stats(receiver: app.receiver).receivedFrames == 960 })
        XCTAssertEqual(stats(receiver: app.receiver).connections, 1)
        XCTAssertEqual(stats(sender).connects, 1, "the real link must not have dropped")
    }

    func test_theRealSender_getsPastACallerHoldingTheSlot() {
        let port = makePort()
        let app = App(port: port)
        let squatter = dialLoopback(port)
        defer { close(squatter) }
        usleep(20_000)          // it now holds the one handshake slot, saying nothing
        let sender = keyedSender(port)
        defer { EQTLinkSenderDestroy(sender) }
        let started = Date()
        XCTAssertEqual(EQTLinkSenderStart(sender), 0)
        wait("the real sender", timeout: 3, until: { stats(receiver: app.receiver).hasPeer == 1 })
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.4,
                          "it must take the slot, not wait out the squatter's 0.5 s")
    }

    /// The extension's process can die and come back. Its new connection must not
    /// have to wait for the old socket to time out.
    func test_aProvenCaller_replacesTheOldPeerAtOnce() throws {
        let port = makePort()
        let app = App(port: port)
        let first = dialLoopback(port)
        defer { close(first) }
        XCTAssertNotNil(Handshake.prove(first, key: LinkTestKey.real))
        wait("the first peer", until: { stats(receiver: app.receiver).connections == 1 })
        Handshake.write(first, Handshake.audioChunk(start: 0, frames: 64))
        wait("its audio", until: { stats(receiver: app.receiver).receivedFrames == 64 })

        let second = dialLoopback(port)
        defer { close(second) }
        XCTAssertNotNil(Handshake.prove(second, key: LinkTestKey.real))
        wait("the replacement", until: { stats(receiver: app.receiver).connections == 2 })
        XCTAssertEqual(stats(receiver: app.receiver).hasPeer, 1)
        XCTAssertNotNil(Handshake.bytesUntilClosed(first), "the old connection is closed")
    }

    func test_aReceiverWithNoKey_refusesEveryone() {
        let port = makePort()
        let app = App(port: port, key: nil)
        let sender = keyedSender(port)
        defer { EQTLinkSenderDestroy(sender) }
        XCTAssertEqual(EQTLinkSenderStart(sender), 0)
        wait("a refusal", until: { stats(receiver: app.receiver).rejectedCallers >= 1 })
        XCTAssertEqual(stats(receiver: app.receiver).hasPeer, 0)
        XCTAssertEqual(stats(sender).connected, 0)
    }

    /// With no key loaded the receiver's key buffer is all zeros. A caller must not
    /// be able to pass by proving it knows that.
    func test_aReceiverWithNoKey_cannotBePassedWithAnAllZeroKey() {
        let port = makePort()
        let app = App(port: port, key: nil)
        let fd = dialLoopback(port)
        defer { close(fd) }
        XCTAssertNil(Handshake.prove(fd, key: [UInt8](repeating: 0, count: LinkKey.byteCount)),
                     "it must not even answer the hello")
        usleep(30_000)
        XCTAssertEqual(stats(receiver: app.receiver).hasPeer, 0)
        XCTAssertEqual(stats(receiver: app.receiver).connections, 0)
    }

    func test_onlyTheFirstKeyCounts_onTheReceiverToo() {
        let port = makePort()
        let app = App(port: port)
        EQTLinkReceiverSetKey(app.receiver, LinkTestKey.wrong)
        let fd = dialLoopback(port)
        defer { close(fd) }
        XCTAssertNotNil(Handshake.prove(fd, key: LinkTestKey.real))
        wait("the peer", until: { stats(receiver: app.receiver).hasPeer == 1 })
    }

    // MARK: The relay

    /// The attack the connection binding exists to stop. Another app takes the port
    /// while the real one is away, hands it over, and passes the handshake messages
    /// between the two real ends.
    func test_aRelayBetweenTheRealEnds_getsNoAudio() throws {
        var reachedItInTime = false
        for _ in 0 ..< 5 where !reachedItInTime {
            let port = makePort()
            let relay = FakeApp(port: port)
            let sender = keyedSender(port)
            defer { EQTLinkSenderDestroy(sender) }
            let started = Date()            // before its 250 ms limit can have begun
            XCTAssertEqual(EQTLinkSenderStart(sender), 0)
            let toExtension = try XCTUnwrap(relay.nextCaller())
            defer { close(toExtension) }
            let hello = try XCTUnwrap(Handshake.read(toExtension, Handshake.helloBytes))

            relay.closeListener()
            let app = App(port: port)       // binds the port the relay just gave up
            defer { withExtendedLifetime(app) {} }
            let toApp = dialLoopback(port)
            defer { close(toApp) }
            XCTAssertTrue(Handshake.write(toApp, hello))
            let answer = try XCTUnwrap(Handshake.read(toApp, Handshake.serverBytes))
            reachedItInTime = Date().timeIntervalSince(started) < 0.2
            XCTAssertTrue(Handshake.write(toExtension, answer))

            pushAudio(sender)
            if let stolen = Handshake.read(toExtension, Handshake.clientBytes, timeout: 0.4) {
                Handshake.write(toApp, stolen)      // what a working relay does next
                XCTFail("the extension proved itself to a relay")
            }
            XCTAssertEqual(Handshake.bytesUntilClosed(toExtension), 0, "no audio may reach the relay")

            wait("the extension to reach the real app instead", until: {
                pushAudio(sender)
                usleep(2_000)
                return stats(receiver: app.receiver).hasPeer == 1 && stats(sender).connected == 1
            })
        }
        XCTAssertTrue(reachedItInTime, "the relay never answered in time, so this proved nothing")
    }

    /// The defence rests on this: two sockets can't share all four addresses, so a
    /// relay can't reach the app from the extension's own address and port.
    func test_theKernelRefusesASecondSocketWithTheSameAddresses() throws {
        let port = makePort()
        let relay = FakeApp(port: port)
        let extensionEnd = dialLoopback(port)
        defer { close(extensionEnd) }
        let relayEnd = try XCTUnwrap(relay.nextCaller())
        defer { close(relayEnd) }
        var client = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &client) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(extensionEnd, $0, &length) }
        }
        relay.closeListener()
        let app = App(port: port)
        defer { withExtendedLifetime(app) {} }

        let clone = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(clone) }
        var on: Int32 = 1
        setsockopt(clone, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(clone, SOL_SOCKET, SO_REUSEPORT, &on, socklen_t(MemoryLayout<Int32>.size))
        let bound = withUnsafePointer(to: &client) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(clone, $0, length) }
        }
        guard bound == 0 else { return }    // refused even earlier
        var server = sockaddr_in()
        server.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        server.sin_family = sa_family_t(AF_INET)
        server.sin_port = port.bigEndian
        server.sin_addr.s_addr = in_addr_t(0x7F00_0001).bigEndian
        let connected = withUnsafePointer(to: &server) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(clone, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertNotEqual(connected, 0, "a relay could present the extension's own addresses")
    }

    func test_anAppProofMadeForAnotherConnection_getsNoAudio() throws {
        let port = makePort()
        let app = FakeApp(port: port)
        let sender = keyedSender(port)
        defer { EQTLinkSenderDestroy(sender) }
        XCTAssertEqual(EQTLinkSenderStart(sender), 0)
        pushAudio(sender)
        let caller = try XCTUnwrap(app.nextCaller())
        defer { close(caller) }
        let hello = try XCTUnwrap(Handshake.read(caller, Handshake.helloBytes))
        let client = Array(hello[4...]), server = Handshake.nonce()
        var other = Handshake.channel(of: caller, isClient: false)
        other[4] ^= 1                       // a different client port
        Handshake.write(caller, Handshake.serverMagic + server
                        + Handshake.proof(LinkTestKey.real, Handshake.serverLabel, channel: other, client: client, server: server))
        pushAudio(sender)
        XCTAssertEqual(Handshake.bytesUntilClosed(caller), 0)
        XCTAssertEqual(stats(sender).sentFrames, 0)
    }

    func test_aCallerProofMadeForAnotherConnection_isRefused() throws {
        let port = makePort()
        let app = App(port: port)
        let fd = dialLoopback(port)
        defer { close(fd) }
        let client = Handshake.nonce()
        Handshake.write(fd, Handshake.helloMagic + client)
        let reply = try XCTUnwrap(Handshake.read(fd, Handshake.serverBytes))
        var other = Handshake.channel(of: fd, isClient: true)
        other[4] ^= 1
        Handshake.write(fd, Handshake.clientMagic + Handshake.proof(
            LinkTestKey.real, Handshake.clientLabel, channel: other, client: client, server: Array(reply[4 ..< 36])))
        wait("the refusal", until: { stats(receiver: app.receiver).rejectedCallers >= 1 })
        XCTAssertEqual(stats(receiver: app.receiver).hasPeer, 0)
    }

    // MARK: Exact comparison and partial delivery

    func test_anAppProofWrongInItsLastBit_getsNoAudio() throws {
        let port = makePort()
        let app = FakeApp(port: port)
        let sender = keyedSender(port)
        defer { EQTLinkSenderDestroy(sender) }
        XCTAssertEqual(EQTLinkSenderStart(sender), 0)
        pushAudio(sender)
        let caller = try XCTUnwrap(app.nextCaller())
        defer { close(caller) }
        let hello = try XCTUnwrap(Handshake.read(caller, Handshake.helloBytes))
        let client = Array(hello[4...]), server = Handshake.nonce()
        var proof = Handshake.proof(LinkTestKey.real, Handshake.serverLabel,
                                    channel: Handshake.channel(of: caller, isClient: false), client: client, server: server)
        proof[proof.count - 1] ^= 1
        Handshake.write(caller, Handshake.serverMagic + server + proof)
        pushAudio(sender)
        XCTAssertEqual(Handshake.bytesUntilClosed(caller), 0)
        XCTAssertEqual(stats(sender).sentFrames, 0)
    }

    func test_aCallerProofWrongInItsLastBit_isRefused() throws {
        let port = makePort()
        let app = App(port: port)
        let fd = dialLoopback(port)
        defer { close(fd) }
        let client = Handshake.nonce()
        Handshake.write(fd, Handshake.helloMagic + client)
        let reply = try XCTUnwrap(Handshake.read(fd, Handshake.serverBytes))
        var proof = Handshake.proof(LinkTestKey.real, Handshake.clientLabel,
                                    channel: Handshake.channel(of: fd, isClient: true), client: client, server: Array(reply[4 ..< 36]))
        proof[proof.count - 1] ^= 1
        Handshake.write(fd, Handshake.clientMagic + proof)
        wait("the refusal", until: { stats(receiver: app.receiver).rejectedCallers >= 1 })
        XCTAssertEqual(stats(receiver: app.receiver).hasPeer, 0)
    }

    func test_aHandshakeArrivingInPieces_stillCompletes_atTheApp() throws {
        let port = makePort()
        let app = App(port: port)
        let fd = dialLoopback(port)
        defer { close(fd) }
        let client = Handshake.nonce()
        XCTAssertTrue(Handshake.writeInPieces(fd, Handshake.helloMagic + client, pieces: 5))
        let reply = try XCTUnwrap(Handshake.read(fd, Handshake.serverBytes))
        let proof = Handshake.proof(LinkTestKey.real, Handshake.clientLabel,
                                    channel: Handshake.channel(of: fd, isClient: true), client: client, server: Array(reply[4 ..< 36]))
        XCTAssertTrue(Handshake.writeInPieces(fd, Handshake.clientMagic + proof, pieces: 5))
        wait("the peer", until: { stats(receiver: app.receiver).hasPeer == 1 })
    }

    func test_aHandshakeArrivingInPieces_stillCompletes_atTheExtension() throws {
        let port = makePort()
        let app = FakeApp(port: port)
        let sender = keyedSender(port)
        defer { EQTLinkSenderDestroy(sender) }
        XCTAssertEqual(EQTLinkSenderStart(sender), 0)
        let caller = try XCTUnwrap(app.nextCaller())
        defer { close(caller) }
        let hello = try XCTUnwrap(Handshake.read(caller, Handshake.helloBytes))
        let client = Array(hello[4...]), server = Handshake.nonce()
        let proof = Handshake.proof(LinkTestKey.real, Handshake.serverLabel,
                                    channel: Handshake.channel(of: caller, isClient: false), client: client, server: server)
        XCTAssertTrue(Handshake.writeInPieces(caller, Handshake.serverMagic + server + proof, pieces: 4))
        wait("the sender to accept it", until: { stats(sender).connected == 1 })
    }

    func test_aProofAndAudioInOneWrite_arePlayed() throws {
        let port = makePort()
        let app = App(port: port)
        let fd = dialLoopback(port)
        defer { close(fd) }
        let client = Handshake.nonce()
        Handshake.write(fd, Handshake.helloMagic + client)
        let reply = try XCTUnwrap(Handshake.read(fd, Handshake.serverBytes))
        let proof = Handshake.proof(LinkTestKey.real, Handshake.clientLabel,
                                    channel: Handshake.channel(of: fd, isClient: true), client: client, server: Array(reply[4 ..< 36]))
        Handshake.write(fd, Handshake.clientMagic + proof + Handshake.audioChunk(start: 0, frames: 64))
        wait("the audio", until: { stats(receiver: app.receiver).receivedFrames == 64 })
    }

    func test_aCallerThatStopsAfterItsHello_isHungUpOn() throws {
        let port = makePort()
        let app = App(port: port)
        let fd = dialLoopback(port)
        defer { close(fd) }
        Handshake.write(fd, Handshake.helloMagic + Handshake.nonce())
        XCTAssertNotNil(Handshake.read(fd, Handshake.serverBytes))
        XCTAssertEqual(Handshake.bytesUntilClosed(fd, timeout: 2), 0, "it can't stay without proving itself")
        XCTAssertEqual(stats(receiver: app.receiver).hasPeer, 0)
        XCTAssertEqual(stats(receiver: app.receiver).connections, 0)
    }

    // MARK: Floods

    /// One call in a flood. It never blocks, and says hello if it got through. The
    /// caller hangs it up later: a call reset at once never reaches accept.
    private func floodCall(_ port: UInt16) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return fd }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var hangUp = linger(l_onoff: 1, l_linger: 0)        // no TIME_WAIT, or a flood runs out of ports
        setsockopt(fd, SOL_SOCKET, SO_LINGER, &hangUp, socklen_t(MemoryLayout<linger>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        a.sin_addr.s_addr = in_addr_t(0x7F00_0001).bigEndian
        _ = withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        _ = send(fd, Handshake.helloMagic + Handshake.nonce(), Handshake.helloBytes, MSG_DONTWAIT)
        return fd
    }

    private func flood(_ port: UInt16, seconds: TimeInterval, gapMicroseconds: UInt32 = 1_000,
                       each: () -> Void = {}) {
        var held: [Int32] = []
        defer { held.forEach { close($0) } }
        let started = Date()
        while Date().timeIntervalSince(started) < seconds {
            held.append(floodCall(port))
            if held.count > 16 { close(held.removeFirst()) }
            each()
            usleep(gapMicroseconds)
        }
    }

    func test_aConnectionFlood_isAdmittedAtABoundedRate() {
        let port = makePort()
        let app = App(port: port)
        let started = Date()
        flood(port, seconds: 2)
        let elapsed = Date().timeIntervalSince(started)
        let admitted = stats(receiver: app.receiver).rejectedCallers
        XCTAssertGreaterThanOrEqual(admitted, 8, "the flood must actually have reached it")
        XCTAssertLessThanOrEqual(admitted, UInt64(elapsed * 32) + 10, "a flood must cost a bounded amount of work")
    }

    func test_aConnectionFlood_doesNotDisturbThePlayingPeer() {
        let port = makePort()
        let app = App(port: port)
        let sender = keyedSender(port)
        defer { EQTLinkSenderDestroy(sender) }
        XCTAssertEqual(EQTLinkSenderStart(sender), 0)
        wait("the link", until: { stats(receiver: app.receiver).hasPeer == 1 && stats(sender).connected == 1 })
        var pushed: UInt64 = 0
        flood(port, seconds: 0.5, gapMicroseconds: 10_000) {
            pushAudio(sender)
            pushed += 480
        }
        wait("all the audio", until: { stats(receiver: app.receiver).receivedFrames == pushed })
        XCTAssertEqual(stats(receiver: app.receiver).connections, 1)
        XCTAssertEqual(stats(sender).connects, 1, "the real link must not have dropped")
    }

    func test_afterAFlood_theRealSenderGetsIn() {
        let port = makePort()
        let app = App(port: port)
        flood(port, seconds: 0.3)
        let sender = keyedSender(port)
        defer { EQTLinkSenderDestroy(sender) }
        XCTAssertEqual(EQTLinkSenderStart(sender), 0)
        wait("the real sender", until: {
            pushAudio(sender)
            usleep(5_000)
            return stats(receiver: app.receiver).hasPeer == 1
        })
    }

    /// A real handshake needs a moment, so the next caller can't take the slot at once.
    func test_aNewerCaller_cannotTakeTheSlotStraightAway() throws {
        let port = makePort()
        let app = App(port: port)
        defer { withExtendedLifetime(app) {} }
        for _ in 0 ..< 3 {
            let started = Date()            // before the first dial: the bound holds under load
            let first = dialLoopback(port)
            let second = dialLoopback(port)
            defer {
                close(first)
                close(second)
            }
            XCTAssertTrue(Handshake.write(second, Handshake.helloMagic + Handshake.nonce()))
            XCTAssertNotNil(Handshake.read(second, Handshake.serverBytes, timeout: 2))
            XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.019,
                                        "the first caller got no time to finish")
        }
    }

    /// A queue it can't drain keeps the listener readable, which must not become a spin.
    func test_aFailingAccept_isRetriedAtAPace() {
        let port = makePort()
        let app = App(port: port)
        defer { withExtendedLifetime(app) {} }
        EQTTestSetAcceptError(ECONNABORTED)
        defer { EQTTestSetAcceptError(0) }
        let caller = dialLoopback(port)     // stays queued, so accept keeps failing
        defer { close(caller) }
        usleep(30_000)
        let before = EQTTestAcceptCalls()
        let started = Date()
        usleep(300_000)
        let calls = EQTTestAcceptCalls() - before
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(calls, 2, "it must keep trying")
        XCTAssertLessThanOrEqual(Double(calls), elapsed / 0.02 + 2, "it must not spin on a failing accept")
    }

    // MARK: The sender around a failed handshake

    /// The best of three: a busy machine can delay one stop, a real regression delays all.
    func test_stoppingDuringTheHandshake_doesNotWaitItOut() throws {
        var fastest = TimeInterval.infinity
        for _ in 0 ..< 3 {
            let port = makePort()
            let app = FakeApp(port: port)
            let sender = keyedSender(port)
            defer { EQTLinkSenderDestroy(sender) }
            XCTAssertEqual(EQTLinkSenderStart(sender), 0)
            let caller = try XCTUnwrap(app.nextCaller())
            defer { close(caller) }
            XCTAssertNotNil(Handshake.read(caller, Handshake.helloBytes))   // now it waits for the answer
            let started = Date()
            EQTLinkSenderStop(sender)
            fastest = min(fastest, Date().timeIntervalSince(started))
        }
        XCTAssertLessThan(fastest, 0.2, "a stop must not sit out the 250 ms limit")
    }

    /// A route left selected with nothing playing must not keep the phone waking.
    func test_anIdleRoute_backsOffItsRetries() {
        let sender = keyedSender(makePort())    // nobody will ever listen
        defer { EQTLinkSenderDestroy(sender) }
        let started = Date()
        XCTAssertEqual(EQTLinkSenderStart(sender), 0)
        wait("the first retry", until: { stats(sender).connectAttempts >= 2 })      // at about 2 s
        let left = 4.5 - Date().timeIntervalSince(started)
        if left > 0 { usleep(UInt32(left * 1_000_000)) }
        guard Date().timeIntervalSince(started) < 5.8 else { return }               // the next is due at 6 s
        XCTAssertEqual(stats(sender).connectAttempts, 2, "the next retry must wait twice as long")
    }

    /// EQtargets can be picked before the app has ever made the key.
    func test_aKeyArrivingLate_wakesASleepingSender() {
        let port = makePort()
        let app = App(port: port)
        let sender = EQTLinkSenderCreate(port)!
        defer { EQTLinkSenderDestroy(sender) }
        XCTAssertEqual(EQTLinkSenderStart(sender), 0)
        usleep(150_000)                         // nothing to connect with, so it sleeps
        XCTAssertEqual(stats(sender).connectAttempts, 0)
        EQTLinkSenderSetKey(sender, LinkTestKey.real)
        wait("the link", timeout: 1.5, until: { stats(receiver: app.receiver).hasPeer == 1 })
    }

    func test_audioDuringAnIdleWait_connectsAtOnce() {
        let port = makePort()
        let sender = keyedSender(port)
        defer { EQTLinkSenderDestroy(sender) }
        XCTAssertEqual(EQTLinkSenderStart(sender), 0)
        wait("the first retry", until: { stats(sender).connectAttempts >= 2 })      // now it sleeps 4 s
        let app = App(port: port)
        pushAudio(sender)
        wait("the link", timeout: 1.5, until: { stats(receiver: app.receiver).hasPeer == 1 })
    }

    func test_aSenderThatNeverGotAKey_stillGivesTheRouteBack() {
        final class Counter { var hits = 0 }
        let counter = Counter()
        let sender = EQTLinkSenderCreate(makePort())!
        defer { EQTLinkSenderDestroy(sender) }
        EQTLinkSenderSetUnreachableHandler(sender, 0.1, { context in
            Unmanaged<Counter>.fromOpaque(context!).takeUnretainedValue().hits += 1
        }, Unmanaged.passUnretained(counter).toOpaque())
        XCTAssertEqual(EQTLinkSenderStart(sender), 0)
        for _ in 0 ..< 20 {
            pushAudio(sender)
            usleep(2_000)
        }
        wait("the report", until: { counter.hits >= 1 })
        EQTLinkSenderStop(sender)
        XCTAssertEqual(counter.hits, 1)
    }

    /// Handshake bytes from a fake app must not count as the real app answering, or
    /// it could keep every other app on the phone silent.
    func test_aHostileListenersBytes_neverCountAsTheAppAnswering() {
        final class Counter { var hits = 0 }
        let counter = Counter()
        let port = makePort()
        let hostile = FakeApp(port: port)
        let sender = keyedSender(port)
        defer { EQTLinkSenderDestroy(sender) }
        EQTLinkSenderSetUnreachableHandler(sender, 0.5, { context in
            Unmanaged<Counter>.fromOpaque(context!).takeUnretainedValue().hits += 1
        }, Unmanaged.passUnretained(counter).toOpaque())
        XCTAssertEqual(EQTLinkSenderStart(sender), 0)
        let deadline = Date().addingTimeInterval(5)
        while counter.hits == 0, Date() < deadline {
            pushAudio(sender)
            if let caller = hostile.nextCaller(timeout: 0.01) {
                if let hello = Handshake.read(caller, Handshake.helloBytes, timeout: 0.1) {
                    let client = Array(hello[4...]), server = Handshake.nonce()
                    Handshake.write(caller, Handshake.serverMagic + server + Handshake.proof(
                        LinkTestKey.wrong, Handshake.serverLabel,
                        channel: Handshake.channel(of: caller, isClient: false), client: client, server: server))
                }
                close(caller)
            }
            usleep(2_000)
        }
        EQTLinkSenderStop(sender)
        XCTAssertEqual(counter.hits, 1, "the route must still be given back")
        XCTAssertEqual(stats(sender).sentFrames, 0)
    }

    // MARK: Build setup

    func test_bothTargets_shareOneKeychainGroup() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        func plist(_ path: String) throws -> [String: Any] {
            let data = try Data(contentsOf: root.appendingPathComponent(path))
            return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        }
        let group = "$(AppIdentifierPrefix)com.eqtargets.ios.link"
        XCTAssertEqual((try plist("App/EQtargets.entitlements")["keychain-access-groups"] as? [String])?.first, group)
        XCTAssertEqual(try plist("Extension/Extension.entitlements")["keychain-access-groups"] as? [String], [group])
        XCTAssertEqual(try plist("App/Info.plist")["EQTLinkKeychainGroup"] as? String, group)
        XCTAssertEqual(try plist("Extension/Info.plist")["EQTLinkKeychainGroup"] as? String, group)
    }
}

// MARK: - The key's life

final class LinkKeyTests: XCTestCase {

    private final class FakeKeychain {
        var stored: [UInt8]?
        var readFailure: OSStatus?
        var addResult: OSStatus = errSecSuccess
        var racingKey: [UInt8]?
        var randomWorks = true
        var reads = 0
        var adds = 0
        var removes = 0

        var store: LinkKey.Store {
            LinkKey.Store(
                read: { [self] in
                    reads += 1
                    if let readFailure { return (readFailure, nil) }
                    return stored.map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil)
                },
                add: { [self] key in
                    adds += 1
                    if addResult == errSecDuplicateItem { stored = racingKey }
                    if addResult == errSecSuccess { stored = key }
                    return addResult
                },
                remove: { [self] in
                    removes += 1
                    stored = nil
                    return errSecSuccess
                },
                random: { [self] n in randomWorks ? (0 ..< n).map { UInt8($0 &+ 9) } : nil })
        }
    }

    func test_anExistingKey_isReused() {
        let k = FakeKeychain()
        k.stored = LinkTestKey.real
        XCTAssertEqual(LinkKey.loadOrCreate(using: k.store), LinkTestKey.real)
        XCTAssertEqual(k.adds, 0)
    }

    func test_noKeyYet_makesAndStoresOne() {
        let k = FakeKeychain()
        let key = LinkKey.loadOrCreate(using: k.store)
        XCTAssertEqual(key?.count, LinkKey.byteCount)
        XCTAssertEqual(k.stored, key)
    }

    func test_aDamagedKey_isReplaced() {
        let k = FakeKeychain()
        k.stored = [1, 2, 3]
        let key = LinkKey.loadOrCreate(using: k.store)
        XCTAssertEqual(key?.count, LinkKey.byteCount)
        XCTAssertEqual(k.removes, 1)
        XCTAssertEqual(k.stored, key)
    }

    /// A locked Keychain is not a missing key: making a new one would lock the
    /// extension out of the link for good.
    func test_aLockedKeychain_neverMakesANewKey() {
        let k = FakeKeychain()
        k.readFailure = errSecInteractionNotAllowed
        XCTAssertNil(LinkKey.loadOrCreate(using: k.store))
        XCTAssertEqual(k.adds, 0)
        XCTAssertEqual(k.removes, 0)
    }

    func test_aFailedSave_leavesTheLinkClosed() {
        let k = FakeKeychain()
        k.addResult = errSecNotAvailable
        XCTAssertNil(LinkKey.loadOrCreate(using: k.store))
    }

    func test_noRandomness_leavesTheLinkClosed() {
        let k = FakeKeychain()
        k.randomWorks = false
        XCTAssertNil(LinkKey.loadOrCreate(using: k.store))
        XCTAssertEqual(k.adds, 0)
    }

    func test_losingTheRaceToSave_usesTheKeyThatWon() {
        let k = FakeKeychain()
        k.addResult = errSecDuplicateItem
        k.racingKey = LinkTestKey.wrong
        XCTAssertEqual(LinkKey.loadOrCreate(using: k.store), LinkTestKey.wrong)
    }

    /// A key only the extension had could never pass the handshake.
    func test_theExtensionsSide_neverMakesAKey() {
        let k = FakeKeychain()
        XCTAssertNil(LinkKey.load(using: k.store))
        XCTAssertEqual(k.adds, 0)
        k.stored = [1, 2, 3]
        XCTAssertNil(LinkKey.load(using: k.store), "a damaged key is no key")
        k.stored = LinkTestKey.real
        XCTAssertEqual(LinkKey.load(using: k.store), LinkTestKey.real)
    }

    // MARK: The extension waiting for the key

    @MainActor
    private final class FakeTimer {
        var pending: [(delay: TimeInterval, action: @MainActor () -> Void)] = []

        func schedule(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) {
            pending.append((delay, action))
        }

        func fire() {
            guard !pending.isEmpty else { return }
            pending.removeFirst().action()
        }
    }

    /// EQtargets can be picked moments before the app first opens and makes the key.
    @MainActor
    func test_theExtension_keepsLookingUntilTheKeyExists() {
        let k = FakeKeychain(), timer = FakeTimer()
        let waiter = LinkKeyWaiter(store: k.store, schedule: timer.schedule)
        var found: [[UInt8]] = []
        waiter.look(isWanted: { true }, found: { found.append($0) })
        XCTAssertTrue(found.isEmpty)
        XCTAssertEqual(timer.pending.count, 1, "it must look again")
        timer.fire()
        XCTAssertEqual(timer.pending.count, 1)
        k.stored = LinkTestKey.real
        timer.fire()
        XCTAssertEqual(found, [LinkTestKey.real])
        XCTAssertTrue(timer.pending.isEmpty, "with the key found there is nothing left to do")
    }

    @MainActor
    func test_theExtension_stopsLookingWhenItsSessionEnds() {
        let k = FakeKeychain(), timer = FakeTimer()
        var wanted = true, found = false
        let waiter = LinkKeyWaiter(store: k.store, schedule: timer.schedule)
        waiter.look(isWanted: { wanted }, found: { _ in found = true })
        wanted = false
        k.stored = LinkTestKey.real
        let reads = k.reads
        timer.fire()
        XCTAssertFalse(found)
        XCTAssertEqual(k.reads, reads, "no Keychain call once the session is over")
        XCTAssertTrue(timer.pending.isEmpty)
    }

    @MainActor
    func test_startingAgain_retiresTheOldSearch() {
        let k = FakeKeychain(), timer = FakeTimer()
        let waiter = LinkKeyWaiter(store: k.store, schedule: timer.schedule)
        waiter.look(isWanted: { true }, found: { _ in })
        waiter.look(isWanted: { true }, found: { _ in })
        XCTAssertEqual(timer.pending.count, 2)
        timer.fire()                        // the first search's look, now retired
        XCTAssertEqual(timer.pending.count, 1, "only the newest search may go on")
    }

    /// A route left selected with no key must not keep an idle phone waking.
    @MainActor
    func test_theKeyWait_slowsDown() {
        XCTAssertEqual(LinkKeyWaiter.delay(afterLooks: 0), 0.5)
        XCTAssertEqual(LinkKeyWaiter.delay(afterLooks: 59), 0.5, "30 seconds of quick looks")
        XCTAssertEqual(LinkKeyWaiter.delay(afterLooks: 60), 1)
        XCTAssertEqual(LinkKeyWaiter.delay(afterLooks: 61), 2)
        XCTAssertEqual(LinkKeyWaiter.delay(afterLooks: 64), 16)
        XCTAssertEqual(LinkKeyWaiter.delay(afterLooks: 65), 30)
        XCTAssertEqual(LinkKeyWaiter.delay(afterLooks: 1_000_000), 30)
    }

    @MainActor
    func test_startingAgain_beginsTheQuickLooksAgain() {
        let k = FakeKeychain(), timer = FakeTimer()
        let waiter = LinkKeyWaiter(store: k.store, schedule: timer.schedule)
        waiter.look(isWanted: { true }, found: { _ in })
        for _ in 0 ..< 70 { timer.fire() }
        XCTAssertEqual(timer.pending.last?.delay, 30, "by now it waits a long time")
        waiter.look(isWanted: { true }, found: { _ in })
        XCTAssertEqual(timer.pending.last?.delay, 0.5)
    }
}
