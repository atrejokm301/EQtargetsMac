//
//  ProcessingChain.swift
//  EQtargets (macOS)
//
//  CONTRACT FILE — the signatures below are frozen (other modules build
//  against them). Replace the stub bodies; do not rename or re-shape the API
//  without updating docs/ARCHITECTURE.md and every caller.
//
//  The whole DSP chain, run inside ONE render callback on the output device's
//  real-time thread:
//
//    ring (system mix) → Target PEQ (preamp + 10 biquads)
//                      → Fine-Tune PEQ (preamp + 10 biquads)
//                      → Bass Style static shape (4 biquads + loudness-matched gain)
//                      → Punch / Rumble dynamic stage (TransientPunchDSPCore)
//                      → Output protection (lookahead safety limiter, −1 dBFS)
//                      → output gain / mute (digital volume fallback)
//
//  Layer rules (product invariants, from the iOS app):
//   • Target and Fine-Tune are independent layers; Fine-Tune never overwrites Target.
//   • Bass Style never mutates Target / Fine-Tune; it runs after both.
//   • Graph == DSP: the PEQ stages use the same RBJ formulas as `EQBiquad`.
//

import Foundation

/// Everything the render thread needs, as one value. Built on the main thread.
struct ChainParameters: Equatable {
    var dual: DualEQState = .flat
    var bass: BassProcessorState = .flat
    /// Transparent lookahead safety limiter at the end of the chain (ceiling
    /// −1 dBFS). On by default; it only acts on overs.
    var outputProtection: Bool = true
    /// Everything off: audio keeps flowing through the same route, samples untouched.
    var masterBypass: Bool = false
    /// Digital output gain in dB, applied last. Used when the real output
    /// device has no hardware volume control (volume mirroring falls back to it).
    var outputGainDB: Double = 0
    var outputMuted: Bool = false
}

/// Live values for the UI. All magnitudes in dB.
struct ChainMeters: Equatable {
    /// Punch attack boost / Rumble sustain lift currently applied (≥ 0).
    var punchBoostDB: Double = 0
    /// Punch sustain trim / Rumble attack softening currently applied (≥ 0).
    var punchTrimDB: Double = 0
    /// Safety limiter gain reduction (≥ 0).
    var limiterReductionDB: Double = 0
    /// Peak |x| entering the chain since the last `meters()` call, dBFS (−120 = silence).
    var inputPeakDB: Double = -120
    /// Peak |x| leaving the chain since the last `meters()` call, dBFS.
    var outputPeakDB: Double = -120
    /// Count of blocks where the chain output would have exceeded 0 dBFS
    /// without output protection (lifetime counter; UI shows "clipping" when it moves).
    var overCount: Int = 0
}

/// Real-time DSP chain. One instance per output stream.
///
/// Threading: `prepare` / `reset` on a non-RT thread with rendering stopped;
/// `setParameters` on the main thread at any time; `process` on the render
/// thread; `meters` from any thread. `process` must never allocate, lock,
/// call into the ObjC runtime, or touch a Swift array / class reference in a
/// way that retains.
final class ProcessingChain: @unchecked Sendable {

    init(maxFrames: Int = 4096, maxChannels: Int = 2) {}

    /// Non-RT. (Re)allocates all state for this format.
    func prepare(sampleRate: Double, channelCount: Int) {}

    /// Main thread. Computes every coefficient HERE (never on the render
    /// thread) and hands the result to the render thread lock-free. Parameter
    /// changes must glide — dragging a band or a slider never clicks or zips.
    func setParameters(_ parameters: ChainParameters) {}

    /// Render thread. Processes `frameCount` frames in place, non-interleaved float.
    func process(_ channels: UnsafeMutableBufferPointer<UnsafeMutablePointer<Float>>, frameCount: Int) {}

    /// Any thread, lock-free. Peak fields reset on read.
    func meters() -> ChainMeters { ChainMeters() }

    /// Non-RT: clear all filter / envelope / limiter state.
    func reset() {}

    /// RT-safe: clear filter state at the start of the next `process` call
    /// (used after the input stream jumps, so stale filter memory can't ring).
    func requestReset() {}

    /// Latency the chain adds (the safety limiter's lookahead), in frames.
    var latencyFrames: Int { 0 }
}
