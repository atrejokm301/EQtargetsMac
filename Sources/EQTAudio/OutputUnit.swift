//
//  OutputUnit.swift
//  EQtargets (macOS)
//
//  Plays the processed system mix on the REAL output device through an AUHAL
//  (kAudioUnitSubType_HALOutput) unit.
//
//  Per render: RingReader.render (ring → device rate, drift-locked)
//            → on a stream restart, ProcessingChain.requestReset()
//            → ProcessingChain.process (in place)
//            → CPU-load counters.
//
//  AUHAL rules (each one matters):
//   • EnableIO input = 0, output = 1. Never open input: on AirPods / Bluetooth
//     an input-capable stream forces the HFP headset profile (mono, 16 kHz).
//     The flag is read back after AudioUnitInitialize and the unit is refused
//     if input came on.
//   • The client format is non-interleaved Float32 stereo at the device's
//     NOMINAL rate, so AUHAL never resamples (RingReader already did, once).
//   • The render callback is a plain C function whose refCon is an unretained
//     `RenderContext`; inside it there is no allocation, no lock, no ObjC
//     message, and no retain/release (`_withUnsafeGuaranteedRef`, `let`
//     properties only). Checked in the Release machine code — see the
//     engine report.
//
//  Threading: everything except `RenderContext.render` runs on the main
//  thread. `ProcessingChain.prepare` and `RingReader.configure` run in `init`,
//  before the unit exists — never while any unit renders into them.
//

import AudioToolbox
import CoreAudio
import Darwin
import Foundation
import Synchronization

/// Everything the render thread touches. One per output unit (and one per
/// offline self-test case, which drives the very same callback).
final class RenderContext: @unchecked Sendable {

    let reader: RingReader
    let chain: ProcessingChain
    /// Keeps the shared memory `reader` points into mapped for as long as any
    /// render can run.
    let ring: RingMapping
    let sampleRate: Double

    private let channelTable: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private let placeholder: UnsafeMutablePointer<Float>
    private let ticksPerFrame: Double
    /// Byte offset of `mBuffers` in the C `AudioBufferList` (8 on Apple ABIs),
    /// computed here, off the render thread.
    private let buffersOffset: Int

    // Render → main counters. Relaxed: they are statistics, read at ~2 Hz.
    let busyTicks = Atomic<UInt64>(0)
    let periodTicks = Atomic<UInt64>(0)
    let renderCalls = Atomic<UInt64>(0)
    let discontinuities = Atomic<UInt64>(0)
    let rejectedBuffers = Atomic<UInt64>(0)
    let lastFrameCount = Atomic<Int>(0)

    // Teardown handshake. The render increments `inFlight` THEN reads
    // `enabled`; teardown clears `enabled` THEN waits for `inFlight == 0`.
    // With sequentially consistent ordering one of the two always sees the
    // other, so once `quiesce()` returns no render is inside reader / chain and
    // none will enter — whether or not AudioOutputUnitStop is synchronous.
    private let enabled = Atomic<Bool>(true)
    private let inFlight = Atomic<Int>(0)

    // Teardown fade (main → render). Stopping cut the device to digital zero
    // mid-waveform: one audible tick on power-off, quit and every reroute.
    // `requestFadeOut()` makes the render ramp its output linearly to zero over
    // `fadeFrames` (5 ms, the reader's own declick length) and stay at zero;
    // `isFadedOut` turns true once the ramp is complete. The ramp position is
    // render-thread state in raw memory (no exclusivity checks, no retain).
    private let fadeOutRequested = Atomic<Bool>(false)
    private let fadedOut = Atomic<Bool>(false)
    private let fadePosition: UnsafeMutablePointer<Int>
    let fadeFrames: Int

    init(reader: RingReader, chain: ProcessingChain, ring: RingMapping, sampleRate: Double) {
        self.reader = reader
        self.chain = chain
        self.ring = ring
        self.sampleRate = sampleRate.isFinite && sampleRate > 0 ? sampleRate : 48_000
        placeholder = .allocate(capacity: 1)
        placeholder.initialize(to: 0)
        channelTable = .allocate(capacity: 2)
        channelTable.initialize(repeating: placeholder, count: 2)
        ticksPerFrame = RingReader.hostTicksPerSecond / self.sampleRate
        buffersOffset = MemoryLayout<AudioBufferList>.offset(of: \AudioBufferList.mBuffers) ?? 8
        fadeFrames = max(1, Int((self.sampleRate * RingReader.fadeSeconds).rounded()))
        fadePosition = .allocate(capacity: 1)
        fadePosition.initialize(to: 0)
    }

    deinit {
        channelTable.deallocate()
        placeholder.deallocate()
        fadePosition.deallocate()
    }

    /// Main thread: from the next render on, ramp the output to zero and keep
    /// it there. One-way (the context is discarded with its unit).
    func requestFadeOut() { fadeOutRequested.store(true, ordering: .releasing) }

    /// True once a requested fade-out has reached zero (or nothing was audible).
    var isFadedOut: Bool { fadedOut.load(ordering: .acquiring) }

    /// Render thread. Fills `abl` (non-interleaved Float32) with `n` processed frames.
    func render(frameCount n: Int, buffers abl: UnsafeMutablePointer<AudioBufferList>,
                flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>) {
        let t0 = mach_absolute_time()
        inFlight.add(1, ordering: .sequentiallyConsistent)

        // Plain pointer arithmetic on the C layout — NOT
        // UnsafeMutableAudioBufferListPointer: that type lives in the CoreAudio
        // Swift overlay and is resilient, so in Release every use called into
        // another dylib (type-metadata accessor, value witnesses, a `read`
        // coroutine). Found by disassembling this function.
        let count = Int(abl.pointee.mNumberBuffers)
        let list = (UnsafeMutableRawPointer(abl) + buffersOffset).assumingMemoryBound(to: AudioBuffer.self)
        var usable = 0
        if n > 0, enabled.load(ordering: .sequentiallyConsistent) {
            usable = min(count, 2)
            for i in 0 ..< usable {
                let b = list[i]
                guard let d = b.mData, b.mNumberChannels == 1,
                      Int(b.mDataByteSize) >= n * MemoryLayout<Float>.size else { usable = 0; break }
                channelTable[i] = d.assumingMemoryBound(to: Float.self)
            }
            if usable == 0 { rejectedBuffers.add(1, ordering: .relaxed) }
        }

        if usable > 0 {
            let io = UnsafeMutableBufferPointer(start: channelTable, count: usable)
            reader.render(into: io, frameCount: n)
            // A restarted stream (first start, driver StartIO / rate change,
            // resync after a dropout) must not ring through stale filter and
            // limiter state; the chain ducks 3 ms around the clear (no click).
            if reader.consumeDiscontinuity() {
                chain.requestReset()
                discontinuities.add(1, ordering: .relaxed)
            }
            chain.process(io, frameCount: n)
            if fadeOutRequested.load(ordering: .acquiring) { fadeOut(io, frameCount: n) }
        } else if fadeOutRequested.load(ordering: .acquiring) {
            fadedOut.store(true, ordering: .releasing)          // silent already: nothing to ramp
        }
        // Silence whatever we did not write (extra buffers, or everything).
        var i = usable
        while i < count {
            if let d = list[i].mData { _ = memset(d, 0, Int(list[i].mDataByteSize)) }
            i += 1
        }
        if usable == 0 { flags.pointee.insert(.unitRenderAction_OutputIsSilence) }

        inFlight.subtract(1, ordering: .sequentiallyConsistent)
        let t1 = mach_absolute_time()
        busyTicks.add(t1 &- t0, ordering: .relaxed)
        periodTicks.add(UInt64(Double(max(n, 0)) * ticksPerFrame), ordering: .relaxed)
        renderCalls.add(1, ordering: .relaxed)
        lastFrameCount.store(n, ordering: .relaxed)
    }

    /// Render thread: continue the linear ramp to zero, then write zeros.
    private func fadeOut(_ io: UnsafeMutableBufferPointer<UnsafeMutablePointer<Float>>, frameCount n: Int) {
        let len = fadeFrames
        let start = fadePosition.pointee
        let ramp = min(n, max(0, len - start))       // frames of this buffer still on the ramp
        let step = 1 / Float(len)
        for ch in 0 ..< io.count {
            let d = io[ch]
            var i = 0
            while i < ramp {
                d[i] *= Float(len - 1 - (start + i)) * step   // (len−1)/len … 0
                i += 1
            }
            if ramp < n { (d + ramp).update(repeating: 0, count: n - ramp) }
        }
        fadePosition.pointee = start + ramp
        if start + ramp >= len { fadedOut.store(true, ordering: .releasing) }
    }

    /// Main thread: no render may touch reader / chain after this returns
    /// true. Bounded wait (a render is ~0.05 ms; the bound only guards against
    /// a wedged IO thread).
    @discardableResult
    func quiesce(timeoutSeconds: Double = 0.5) -> Bool {
        enabled.store(false, ordering: .sequentiallyConsistent)
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while inFlight.load(ordering: .sequentiallyConsistent) != 0 {
            if Date() > deadline { return false }
            usleep(200)
        }
        return true
    }
}

/// The AUHAL render callback. C convention; `refCon` is an unretained
/// `RenderContext` that the owning `OutputUnit` keeps alive until the unit is
/// disposed. `_withUnsafeGuaranteedRef` borrows it without retain/release.
func EQTRenderCallback(_ refCon: UnsafeMutableRawPointer,
                       _ ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                       _ inTimeStamp: UnsafePointer<AudioTimeStamp>,
                       _ inBusNumber: UInt32,
                       _ inNumberFrames: UInt32,
                       _ ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    guard let ioData else { return noErr }
    Unmanaged<RenderContext>.fromOpaque(refCon)._withUnsafeGuaranteedRef {
        $0.render(frameCount: Int(inNumberFrames), buffers: ioData, flags: ioActionFlags)
    }
    return noErr
}

/// One AUHAL bound to one real device, with its render context.
final class OutputUnit {

    struct Failure: Error, Equatable {
        let step: String
        let status: OSStatus
        var message: String { "couldn't \(step) (Core Audio error \(HAL.describe(status)))" }
    }

    /// IO buffer requested on the real device, in device frames (macOS's
    /// default is 512). This buffer is paid twice — once in the ring's target
    /// fill and once in the device's presentation latency — so 128 instead of
    /// 512 removes about 768 frames (≈ 16 ms at 48 kHz). Devices may round it
    /// up (AirPods run 256: ≈ 11 ms saved). The render work per frame is
    /// unchanged; only the callback rate goes up.
    static let preferredBufferFrames = 128

    let device: AudioObjectID
    let context: RenderContext
    let sampleRate: Double
    /// The IO buffer the device actually runs for this process, frames.
    let bufferFrames: Int
    let maxFrames: Int
    /// Device latency + safety offset + stream latency + IO buffer, frames.
    /// Read once: it only changes with the device's format, which rebuilds the unit.
    let presentationLatencyFrames: Int
    private var unit: AudioUnit?
    private(set) var isRunning = false

    /// Main thread, with NO other unit rendering into `chain`. Prepares the
    /// chain and a fresh reader for this device's format, then builds and
    /// initializes the AUHAL (stopped).
    init(device: AudioObjectID, ring: RingMapping, chain: ProcessingChain) throws {
        guard let rate = HAL.nominalSampleRate(device) else {
            throw Failure(step: "read the device's sample rate", status: kAudioHardwareUnknownPropertyError)
        }
        // Ask for a small IO buffer first: the ring target and the device's
        // presentation latency below both grow with it.
        let buffer = max(16, HAL.requestBufferFrameSize(device, atMost: Self.preferredBufferFrames) ?? 512)
        self.device = device
        sampleRate = rate
        bufferFrames = buffer
        // AUHAL pulls one device buffer per render (no rate conversion inside
        // AUHAL, since the client format runs at the device rate). Headroom for
        // devices that run large buffers; reader and chain sub-block anyway.
        maxFrames = min(max(4_096, buffer), 16_384)
        presentationLatencyFrames = HAL.outputPresentationLatencyFrames(device)

        chain.prepare(sampleRate: rate, channelCount: 2)
        let reader = RingReader(header: ring.header)
        reader.configure(outputSampleRate: rate, outputMaxFrames: maxFrames, outputBufferFrames: buffer)
        context = RenderContext(reader: reader, chain: chain, ring: ring, sampleRate: rate)
        unit = try Self.makeAUHAL(device: device, sampleRate: rate, maxFrames: maxFrames, context: context)
    }

    deinit { dispose() }

    func start() throws {
        guard let unit, !isRunning else { return }
        let s = AudioOutputUnitStart(unit)
        guard s == noErr else { throw Failure(step: "start the output", status: s) }
        isRunning = true
    }

    /// Idle stop (keeps the unit configured for an instant restart).
    func stop() {
        guard let unit, isRunning else { return }
        AudioOutputUnitStop(unit)
        isRunning = false
    }

    /// Stop for good. After this returns no render touches the chain.
    func dispose() {
        guard let u = unit else { return }
        unit = nil
        // A running unit on a live device fades out first (≈ 5 ms) instead of
        // stopping mid-waveform. A stopped (idle) unit plays nothing, and a
        // dead device renders nothing: no wait then.
        if isRunning, HAL.isAlive(device) { fadeOutAndWait() }
        context.quiesce()          // renders from here on output silence…
        AudioOutputUnitStop(u)     // …and stop arriving
        context.quiesce()          // wait out any render still inside
        AudioUnitUninitialize(u)
        AudioComponentInstanceDispose(u)
        isRunning = false
    }

    /// Bounded wait for the render to finish the fade: one IO buffer (the
    /// next render) plus the ramp, at most 50 ms on the main thread. If the
    /// device stopped calling us (reconfiguration) the timeout just passes.
    private func fadeOutAndWait() {
        context.requestFadeOut()
        let timeout = Self.fadeWaitSeconds(bufferFrames: bufferFrames, sampleRate: sampleRate)
        let deadline = Date().addingTimeInterval(timeout)
        while !context.isFadedOut, Date() < deadline { usleep(500) }
    }

    /// Two IO buffers + the 5 ms ramp + 5 ms slack, capped at 50 ms.
    static func fadeWaitSeconds(bufferFrames: Int, sampleRate: Double) -> Double {
        guard sampleRate.isFinite, sampleRate > 0 else { return 0.05 }
        return min(0.05, 2 * Double(max(0, bufferFrames)) / sampleRate + RingReader.fadeSeconds + 0.005)
    }

    /// Input-side IO flag as the unit reports it (must be 0).
    var inputEnabled: Bool {
        guard let unit else { return false }
        var v: UInt32 = 1
        var size = UInt32(MemoryLayout<UInt32>.size)
        let s = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &v, &size)
        return s != noErr || v != 0
    }

    /// The device the AUHAL is actually bound to.
    var boundDevice: AudioObjectID? {
        guard let unit else { return nil }
        var v = HAL.unknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let s = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &v, &size)
        return s == noErr ? v : nil
    }

    private static func makeAUHAL(device: AudioObjectID, sampleRate: Double, maxFrames: Int,
                                  context: RenderContext) throws -> AudioUnit {
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                             componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw Failure(step: "find the HAL output unit", status: kAudioUnitErr_InvalidElement)
        }
        var instance: AudioUnit?
        let created = AudioComponentInstanceNew(component, &instance)
        guard created == noErr, let au = instance else { throw Failure(step: "create the output unit", status: created) }

        func check(_ s: OSStatus, _ step: String) throws {
            if s != noErr { throw Failure(step: step, status: s) }
        }
        do {
            let u32 = UInt32(MemoryLayout<UInt32>.size)
            // Input off BEFORE the device is bound (see header: Bluetooth HFP).
            var off: UInt32 = 0
            var on: UInt32 = 1
            try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &off, u32),
                      "turn the output unit's input off")
            try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &on, u32),
                      "turn the output unit's output on")
            var dev = device
            try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                           &dev, UInt32(MemoryLayout<AudioObjectID>.size)),
                      "select the output device")
            var format = AudioStreamBasicDescription(
                mSampleRate: sampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
            try check(AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                                           &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
                      "set the output format")
            var slice = UInt32(maxFrames)
            try check(AudioUnitSetProperty(au, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &slice, u32),
                      "set the output buffer limit")
            var callback = AURenderCallbackStruct(inputProc: EQTRenderCallback,
                                                  inputProcRefCon: Unmanaged.passUnretained(context).toOpaque())
            try check(AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                                           &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                      "install the render callback")
            try check(AudioUnitInitialize(au), "initialize the output unit")

            // Read back: input must still be off, and the device must be ours.
            var inputFlag: UInt32 = 1
            var size = u32
            try check(AudioUnitGetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &inputFlag, &size),
                      "verify the output unit's input is off")
            if inputFlag != 0 { throw Failure(step: "keep the output unit's input off", status: kAudioUnitErr_InvalidProperty) }
            return au
        } catch {
            AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
            throw error
        }
    }
}
