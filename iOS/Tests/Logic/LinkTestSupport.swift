//
//  LinkTestSupport.swift
//  EQtargets (iOS)
//
//  Test keys, and a second implementation of the link handshake written from the
//  protocol in EQTLink.h. Sharing no code with EQTLink.c, it can play an honest or
//  a dishonest peer, and a change to the wire format can't pass by agreeing with
//  itself.
//

import CommonCrypto
import Darwin
import Foundation

enum LinkTestKey {
    static let real: [UInt8] = (0 ..< Int(EQT_LINK_KEY_BYTES)).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) }
    static let wrong: [UInt8] = (0 ..< Int(EQT_LINK_KEY_BYTES)).map { UInt8(truncatingIfNeeded: $0 &* 41 &+ 200) }
}

func keyedSender(_ port: UInt16) -> OpaquePointer {
    let sender = EQTLinkSenderCreate(port)!
    EQTLinkSenderSetKey(sender, LinkTestKey.real)
    return sender
}

func keyedReceiver(_ port: UInt16, _ ring: UnsafeMutablePointer<EQTRingHeader>) -> OpaquePointer {
    let receiver = EQTLinkReceiverCreate(port, ring)!
    EQTLinkReceiverSetKey(receiver, LinkTestKey.real)
    return receiver
}

/// A loopback connection a test can misbehave on.
func dialLoopback(_ port: UInt16) -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
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
    return fd
}

enum Handshake {
    static let helloMagic = Array("EQA1".utf8)
    static let serverMagic = Array("EQA2".utf8)
    static let clientMagic = Array("EQA3".utf8)
    static let serverLabel = "EQtargets link server v1"
    static let clientLabel = "EQtargets link client v1"
    static let helloBytes = 36
    static let serverBytes = 68
    static let clientBytes = 36

    static func nonce() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 32)
        arc4random_buf(&bytes, bytes.count)
        return bytes
    }

    /// What both ends of this connection must agree on: client address and port,
    /// then server address and port, as they are on the wire.
    static func channel(of fd: Int32, isClient: Bool) -> [UInt8] {
        func address(_ call: (Int32, UnsafeMutablePointer<sockaddr>, UnsafeMutablePointer<socklen_t>) -> Int32) -> [UInt8] {
            var a = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &a) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { call(fd, $0, &length) }
            }
            return withUnsafeBytes(of: a.sin_addr) { Array($0) } + withUnsafeBytes(of: a.sin_port) { Array($0) }
        }
        let local = address { getsockname($0, $1, $2) }
        let remote = address { getpeername($0, $1, $2) }
        return isClient ? local + remote : remote + local
    }

    static func proof(_ key: [UInt8], _ label: String, channel: [UInt8], client: [UInt8], server: [UInt8]) -> [UInt8] {
        let message = Array(label.utf8) + channel + client + server
        var out = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256), key, key.count, message, message.count, &out)
        return out
    }

    /// Exactly `count` bytes within `timeout`, or nil.
    static func read(_ fd: Int32, _ count: Int, timeout: TimeInterval = 2) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: count)
        var have = 0
        let deadline = Date().addingTimeInterval(timeout)
        while have < count {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { return nil }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&p, 1, Int32(left * 1_000) + 1)
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { return nil }
            let n = out.withUnsafeMutableBytes { recv(fd, $0.baseAddress! + have, count - have, 0) }
            if n > 0 {
                have += n
            } else if n == 0 || (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) {
                return nil
            }
        }
        return out
    }

    @discardableResult
    static func write(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        send(fd, bytes, bytes.count, MSG_DONTWAIT) == bytes.count
    }

    /// The same bytes as several small sends, so the other end sees partial reads.
    @discardableResult
    static func writeInPieces(_ fd: Int32, _ bytes: [UInt8], pieces: Int) -> Bool {
        let size = max(1, bytes.count / pieces)
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + size, bytes.count)
            guard write(fd, Array(bytes[offset ..< end])) else { return false }
            offset = end
            if offset < bytes.count { usleep(1_500) }
        }
        return true
    }

    /// Bytes that arrive until the other end hangs up, or nil if it never does.
    static func bytesUntilClosed(_ fd: Int32, timeout: TimeInterval = 2) -> Int? {
        var total = 0
        var buffer = [UInt8](repeating: 0, count: 8_192)
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { return nil }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&p, 1, Int32(left * 1_000) + 1)
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { return nil }
            let n = recv(fd, &buffer, buffer.count, 0)
            if n > 0 {
                total += n
            } else if n == 0 || errno == ECONNRESET {
                return total
            } else if errno != EINTR, errno != EAGAIN, errno != EWOULDBLOCK {
                return total
            }
        }
    }

    /// The app's half, done honestly with `key`.
    static func serve(_ fd: Int32, key: [UInt8], timeout: TimeInterval = 1) -> Bool {
        guard let hello = read(fd, helloBytes, timeout: timeout), Array(hello[..<4]) == helloMagic else { return false }
        let client = Array(hello[4...]), link = channel(of: fd, isClient: false)
        let server = nonce()
        guard write(fd, serverMagic + server + proof(key, serverLabel, channel: link, client: client, server: server)),
              let last = read(fd, clientBytes, timeout: timeout), Array(last[..<4]) == clientMagic else { return false }
        return Array(last[4...]) == proof(key, clientLabel, channel: link, client: client, server: server)
    }

    struct ClientRun {
        let client: [UInt8]
        let server: [UInt8]
        let sentProof: [UInt8]
    }

    /// The extension's half, sending a proof made with `key`.
    @discardableResult
    static func prove(_ fd: Int32, key: [UInt8], client: [UInt8] = nonce()) -> ClientRun? {
        guard write(fd, helloMagic + client), let reply = read(fd, serverBytes),
              Array(reply[..<4]) == serverMagic else { return nil }
        let server = Array(reply[4 ..< 36])
        let sent = proof(key, clientLabel, channel: channel(of: fd, isClient: true), client: client, server: server)
        guard write(fd, clientMagic + sent) else { return nil }
        return ClientRun(client: client, server: server, sentProof: sent)
    }

    /// One valid audio chunk: a caller without the key must not get this played.
    static func audioChunk(start: Int64, frames: Int) -> [UInt8] {
        var header = EQTLinkChunkHeader(magic: EQT_LINK_MAGIC, version: UInt16(EQT_LINK_VERSION),
                                        channels: UInt16(EQT_LINK_CHANNELS), frames: UInt32(frames),
                                        flags: 0, startFrame: start, endHostTime: mach_absolute_time())
        var bytes = withUnsafeBytes(of: &header) { Array($0) }
        let samples = [Float](repeating: 0.25, count: frames * 2)
        samples.withUnsafeBytes { bytes.append(contentsOf: $0) }
        return bytes
    }
}
