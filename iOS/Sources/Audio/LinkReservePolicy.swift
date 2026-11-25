//
//  LinkReservePolicy.swift
//  EQtargets (iOS)
//
//  How much delivery delay the stream is sized to absorb. It starts shallow, for
//  low latency, and doubles when dropouts repeat.
//
//  - Underruns in the first second from a peer are ignored. EffectDeck's device
//    logs show every start-up going through them.
//  - One isolated underrun changes nothing. Two within 30 seconds of audio do.
//    (EffectDeck waits for three in 5 s, but its misses are 5 ms holes. A
//    RingReader underrun fades out and refills its target, about 40 ms.)
//  - It changes while the reader is stopped by that underrun. RingReader then
//    restarts at the deeper target with no extra gap. Changing it during playback
//    would make the PLL bend the pitch for seconds to reach the new fill.
//  - A quiet stream or a new peer resets it, so a rough moment never costs
//    latency for the rest of the session.
//

import Foundation

struct LinkReservePolicy: Equatable {
    static let shallowest = UInt32(EQT_LINK_DEFAULT_RESERVE)
    static let deepest = UInt32(EQT_LINK_MAX_RESERVE)
    static let startupFrames: UInt64 = 48_000
    static let windowFrames: UInt64 = 1_440_000

    private(set) var reserve = LinkReservePolicy.shallowest
    private var lastUnderrun: UInt64?

    /// Render thread. `framesFromPeer` counts audio received from the current
    /// peer. Returns the new reserve when it should change.
    mutating func observeUnderrun(framesFromPeer frames: UInt64) -> UInt32? {
        if let last = lastUnderrun, frames < last { lastUnderrun = nil }    // a new peer
        guard frames >= Self.startupFrames else { return nil }
        guard let last = lastUnderrun, frames - last <= Self.windowFrames else {
            lastUnderrun = frames
            return nil
        }
        lastUnderrun = nil
        guard reserve < Self.deepest else { return nil }
        reserve = min(reserve * 2, Self.deepest)
        return reserve
    }

    /// The stream went quiet or a new peer connected.
    mutating func reset() {
        reserve = Self.shallowest
        lastUnderrun = nil
    }
}
