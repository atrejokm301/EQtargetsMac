//
//  RingReader.swift
//  EQtargets (macOS)
//
//  CONTRACT FILE — signatures frozen; replace the stub bodies.
//
//  Reads the system mix out of the driver's shared-memory ring (see
//  Shared/EQTRingProtocol.h) and delivers it at the OUTPUT device's rate.
//
//  The virtual device and the real output device run on different clocks.
//  Even at the same nominal rate they drift (measured on the previous driver:
//  +0.24 %), so a plain copy would eventually underrun or overrun. This
//  reader therefore:
//    • resamples with a high-quality fractional (windowed-sinc) interpolator;
//    • runs a PLL on the ring fill level: the resample ratio is nudged so the
//      distance between the driver's write head and our read position holds
//      at a target latency. Corrections are bounded (±1 %) and slow enough to
//      be inaudible as pitch;
//    • resyncs (with a short fade) on generation change, underrun or overrun —
//      never plays stale audio, never clicks.
//

import Foundation

struct RingReaderStats: Equatable {
    enum Lock: Equatable {
        /// No valid ring or the driver is not writing (nothing playing).
        case waiting
        /// Streaming, PLL in its capture range.
        case locked
        /// Streaming, PLL still converging after a resync.
        case acquiring
    }
    var lock: Lock = .waiting
    /// Smoothed distance between write head and read position, in source frames.
    var fillFrames: Double = 0
    var targetFillFrames: Double = 0
    /// Current source frames consumed per output frame.
    var ratio: Double = 1
    /// (ratio / nominal ratio − 1) × 1e6 — the clock drift being absorbed.
    var driftPPM: Double = 0
    var underruns: Int = 0
    var overruns: Int = 0
    var resyncs: Int = 0
    var generation: UInt64 = 0
    /// Nominal rate the driver reports for the ring.
    var sourceSampleRate: Double = 0
    /// Latency the ring adds right now, in seconds (fill / source rate).
    var latencySeconds: Double = 0
}

/// Single consumer of an `EQTRingHeader` ring. Owned by the output engine.
///
/// Threading: `init` / `configure` on a non-RT thread with rendering stopped;
/// `render` on the output render thread; `stats` from any thread.
final class RingReader: @unchecked Sendable {

    /// `header` must stay mapped (and point at `EQT_RING_TOTAL_BYTES`) for the
    /// reader's whole lifetime. Tests pass plain allocated memory.
    init(header: UnsafePointer<EQTRingHeader>) {}

    /// Non-RT. `outputBufferFrames` is the device's IO buffer size, used to
    /// size the target latency; `outputMaxFrames` bounds a single `render`.
    func configure(outputSampleRate: Double, outputMaxFrames: Int, outputBufferFrames: Int) {}

    /// Render thread. Fills exactly `frameCount` frames in each channel
    /// (stereo; a mono destination gets the L/R average). Returns `true` if
    /// any real audio was produced, `false` if it wrote silence.
    @discardableResult
    func render(into channels: UnsafeMutableBufferPointer<UnsafeMutablePointer<Float>>, frameCount: Int) -> Bool {
        for ch in 0 ..< channels.count {
            channels[ch].update(repeating: 0, count: frameCount)
        }
        return false
    }

    /// Any thread, lock-free snapshot.
    func stats() -> RingReaderStats { RingReaderStats() }

    /// True once `render` has seen the stream restart since the last call
    /// (generation change / resync). The engine uses it to `requestReset()` the chain.
    func consumeDiscontinuity() -> Bool { false }
}
