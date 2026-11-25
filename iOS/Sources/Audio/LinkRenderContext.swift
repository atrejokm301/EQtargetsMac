//
//  LinkRenderContext.swift
//  EQtargets (iOS)
//
//  Everything the audio thread touches:
//
//    link ring -> RingReader (resampler + PLL) -> ProcessingChain -> output
//
//  The reader and chain are the Mac app's, unchanged. Same render-thread rules:
//  no allocation, locks, Swift arrays or retain/release.
//

import AVFoundation
import Synchronization

final class LinkRenderContext: @unchecked Sendable {

    static let maxFrames = 4096
    /// After this much silence the chain stops running. The session stays open:
    /// releasing it would suspend the app and kill the listening socket.
    private static let idleSeconds = 1.0
    private static let fadeSeconds = 0.005

    let reader: RingReader
    let chain: ProcessingChain
    private let receiver: OpaquePointer
    private let channelTable: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private let blockTable: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private let placeholder: UnsafeMutablePointer<Float>
    private let buffersOffset = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)!

    // Render thread only.
    private var policy = LinkReservePolicy()
    private var seenUnderruns = 0
    private var silentFrames = Int.max / 2
    private var idleFrames = 48_000
    private var fadeFrames = 240
    private var fadePosition = 0
    private let ticksPerFrameStorage: UnsafeMutablePointer<Double>

    // Cross-thread.
    private let enabled = Atomic<Bool>(false)
    private let inFlight = Atomic<Int>(0)
    private let mutedFlag = Atomic<Bool>(false)
    private let policyResetRequested = Atomic<Bool>(false)
    private let fadeOutRequested = Atomic<Bool>(false)
    private let fadedOut = Atomic<Bool>(false)
    private let busyTicks = Atomic<UInt64>(0)
    private let periodTicks = Atomic<UInt64>(0)
    /// `silenceRun.frames`, published for the main thread (one relaxed store per callback).
    private let silentShared = Atomic<Int>(0)
    private var silenceRun = SilenceRun(sampleRate: 48_000)     // render thread
    private var preparedRate = 48_000.0     // main thread

    /// Preview `--demo` runs the real pipeline and meters, but its test signal
    /// must never play out of the Mac running the simulator.
    private let silentOutput: Bool

    init(ring: UnsafePointer<EQTRingHeader>, receiver: OpaquePointer, silentOutput: Bool = false) {
        reader = RingReader(header: ring)
        chain = ProcessingChain(maxFrames: Self.maxFrames, maxChannels: 2)
        self.receiver = receiver
        self.silentOutput = silentOutput
        placeholder = .allocate(capacity: 1)
        placeholder.initialize(to: 0)
        channelTable = .allocate(capacity: 2)
        channelTable.initialize(repeating: placeholder, count: 2)
        blockTable = .allocate(capacity: 2)
        blockTable.initialize(repeating: placeholder, count: 2)
        ticksPerFrameStorage = .allocate(capacity: 1)
        ticksPerFrameStorage.initialize(to: RingReader.hostTicksPerSecond / 48_000)
    }

    deinit {
        channelTable.deallocate()
        blockTable.deallocate()
        placeholder.deallocate()
        ticksPerFrameStorage.deallocate()
    }

    // MARK: Main thread

    /// Only while rendering is stopped.
    func prepare(sampleRate: Double, bufferFrames: Int) {
        reader.configure(outputSampleRate: sampleRate, outputMaxFrames: Self.maxFrames,
                         outputBufferFrames: bufferFrames)
        chain.prepare(sampleRate: sampleRate, channelCount: 2)
        idleFrames = Int(Self.idleSeconds * sampleRate)
        fadeFrames = max(1, Int(Self.fadeSeconds * sampleRate))
        fadePosition = 0
        silentFrames = Int.max / 2
        silenceRun = SilenceRun(sampleRate: sampleRate)
        silentShared.store(0, ordering: .relaxed)
        preparedRate = max(sampleRate, 1)
        seenUnderruns = reader.stats().underruns
        ticksPerFrameStorage.pointee = RingReader.hostTicksPerSecond / max(sampleRate, 1)
        fadedOut.store(false, ordering: .relaxed)
        fadeOutRequested.store(false, ordering: .relaxed)
        enabled.store(true, ordering: .sequentiallyConsistent)
    }

    func setMuted(_ muted: Bool) { mutedFlag.store(muted, ordering: .relaxed) }

    /// How long the incoming audio has been exactly silent without a break,
    /// measured before the chain (so the chain's own mute does not count).
    /// 0 right after a (re)start, up to `SilenceRun.capSeconds`.
    var secondsOfSilence: Double {
        Double(silentShared.load(ordering: .relaxed)) / preparedRate
    }

    /// The stream went quiet: the next one starts at the shallow reserve again.
    func requestReservePolicyReset() { policyResetRequested.store(true, ordering: .relaxed) }

    /// Ramps the output to zero, then waits (bounded) until no render is running.
    func quiesce() {
        fadeOutRequested.store(true, ordering: .releasing)
        var waited = 0
        while !fadedOut.load(ordering: .acquiring), waited < 50 {
            usleep(1_000)
            waited += 1
        }
        enabled.store(false, ordering: .sequentiallyConsistent)
        waited = 0
        while inFlight.load(ordering: .sequentiallyConsistent) != 0, waited < 100 {
            usleep(1_000)
            waited += 1
        }
    }

    /// Render time / audio time since the last call.
    func takeLoad() -> Double {
        let busy = busyTicks.exchange(0, ordering: .relaxed)
        let period = periodTicks.exchange(0, ordering: .relaxed)
        return period > 0 ? min(1, Double(busy) / Double(period)) : 0
    }

    // MARK: Render thread

    func render(frameCount n: Int, buffers abl: UnsafeMutablePointer<AudioBufferList>) {
        let t0 = mach_absolute_time()
        inFlight.add(1, ordering: .sequentiallyConsistent)

        // Plain pointer arithmetic: UnsafeMutableAudioBufferListPointer lives in
        // a resilient overlay and calls into another dylib on every use.
        let count = Int(abl.pointee.mNumberBuffers)
        let list = (UnsafeMutableRawPointer(abl) + buffersOffset).assumingMemoryBound(to: AudioBuffer.self)
        var usable = 0
        if n > 0, enabled.load(ordering: .sequentiallyConsistent) {
            usable = min(count, 2)
            for i in 0 ..< usable {
                let b = list[i]
                guard let d = b.mData, b.mNumberChannels == 1,
                      Int(b.mDataByteSize) >= n * MemoryLayout<Float>.size else {
                    usable = 0
                    break
                }
                channelTable[i] = d.assumingMemoryBound(to: Float.self)
            }
        }

        if usable > 0 {
            if policyResetRequested.exchange(false, ordering: .relaxed) {
                policy.reset()
                EQTLinkReceiverSetReserveFrames(receiver, policy.reserve)
            }
            var offset = 0
            while offset < n {
                let k = min(n - offset, Self.maxFrames)
                for c in 0 ..< usable { blockTable[c] = channelTable[c] + offset }
                let io = UnsafeMutableBufferPointer(start: blockTable, count: usable)
                let any = reader.render(into: io, frameCount: k)
                if reader.consumeDiscontinuity() { chain.requestReset() }
                // iOS may keep delivering zeros while nothing plays. Exact
                // silence needs no processing, so the chain rests through it.
                let audible = any && !Self.isExactlySilent(io, frames: k)
                if audible {
                    silentFrames = 0
                } else if silentFrames < idleFrames {
                    silentFrames += k
                }
                silenceRun.advance(k, silent: !audible)
                if silentFrames < idleFrames { chain.process(io, frameCount: k) }
                offset += k
            }
            silentShared.store(silenceRun.frames, ordering: .relaxed)

            // Raised while the reader is stopped by this underrun, so it
            // restarts at the deeper target (see LinkReservePolicy).
            let underruns = reader.stats().underruns
            if underruns != seenUnderruns {
                seenUnderruns = underruns
                var link = EQTLinkReceiverStats()
                EQTLinkReceiverGetStats(receiver, &link)    // atomics only
                if let reserve = policy.observeUnderrun(framesFromPeer: link.peerFrames) {
                    EQTLinkReceiverSetReserveFrames(receiver, reserve)
                }
            }

            if silentOutput || mutedFlag.load(ordering: .relaxed) {
                for c in 0 ..< usable { channelTable[c].update(repeating: 0, count: n) }
            }
            if fadeOutRequested.load(ordering: .acquiring) { applyFadeOut(usable, n) }
        } else if fadeOutRequested.load(ordering: .acquiring) {
            fadedOut.store(true, ordering: .releasing)
        }

        var i = usable
        while i < count {
            if let d = list[i].mData { _ = memset(d, 0, Int(list[i].mDataByteSize)) }
            i += 1
        }

        inFlight.subtract(1, ordering: .sequentiallyConsistent)
        busyTicks.add(mach_absolute_time() &- t0, ordering: .relaxed)
        periodTicks.add(UInt64(Double(max(n, 0)) * ticksPerFrameStorage.pointee), ordering: .relaxed)
    }

    /// Stops at the first non-zero sample, so real audio costs almost nothing.
    @inline(__always)
    private static func isExactlySilent(_ io: UnsafeMutableBufferPointer<UnsafeMutablePointer<Float>>,
                                        frames: Int) -> Bool {
        for c in 0 ..< io.count {
            let d = io[c]
            var i = 0
            while i < frames {
                if d[i] != 0 { return false }
                i += 1
            }
        }
        return true
    }

    private func applyFadeOut(_ channels: Int, _ n: Int) {
        let start = fadePosition
        let ramp = min(n, max(0, fadeFrames - start))
        let step = 1 / Float(fadeFrames)
        for c in 0 ..< channels {
            let d = channelTable[c]
            var i = 0
            while i < ramp {
                d[i] *= Float(fadeFrames - 1 - (start + i)) * step
                i += 1
            }
            if ramp < n { (d + ramp).update(repeating: 0, count: n - ramp) }
        }
        fadePosition = start + ramp
        if fadePosition >= fadeFrames { fadedOut.store(true, ordering: .releasing) }
    }
}
