//
//  DemoFeeder.swift
//  EQtargets (iOS)
//
//  Debug Preview builds only. The extension cannot exist on the simulator, so with the
//  `--demo` launch argument this plays its role: it sends a synthetic drum-and-
//  bass loop through the REAL sender, socket, receiver, reader and DSP chain.
//

#if DEBUG && !EQT_HAS_EXTENSION

import Foundation

final class DemoFeeder: @unchecked Sendable {

    static let isRequested = ProcessInfo.processInfo.arguments.contains("--demo")

    private let sender: OpaquePointer
    private let queue = DispatchQueue(label: "com.eqtargets.demo", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var frame: Int64 = 0
    private var firstTick: UInt64 = 0
    private var buffer = [Float](repeating: 0, count: 8_192)

    init?(port: UInt16 = UInt16(EQT_LINK_PORT)) {
        guard let s = EQTLinkSenderCreate(port) else { return nil }
        if let key = LinkKey.loadOrCreate() { EQTLinkSenderSetKey(s, key) }
        sender = s
    }

    deinit {
        timer?.cancel()
        EQTLinkSenderDestroy(sender)
    }

    func start() {
        guard timer == nil else { return }
        _ = EQTLinkSenderStart(sender)
        firstTick = mach_absolute_time()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.pump() }
        t.resume()
        timer = t
    }

    private func pump() {
        let ticks = RingReader.hostTicksPerSecond
        let due = Int64(Double(mach_absolute_time() &- firstTick) / ticks * EQT_LINK_SAMPLE_RATE)
        while frame + 480 <= due {
            for i in 0 ..< 480 {
                let (l, r) = Self.sample(frame + Int64(i))
                buffer[i * 2] = l
                buffer[i * 2 + 1] = r
            }
            frame += 480
            let written = firstTick + UInt64(Double(frame) / EQT_LINK_SAMPLE_RATE * ticks)
            buffer.withUnsafeBufferPointer {
                EQTLinkSenderPush(sender, $0.baseAddress!, 480, 2, written)
            }
        }
    }

    /// A 120 BPM kick, a sustained bass note and a quiet chord.
    private static func sample(_ frame: Int64) -> (Float, Float) {
        let t = Double(frame) / EQT_LINK_SAMPLE_RATE
        let beat = t.truncatingRemainder(dividingBy: 0.5)
        let tau = 2.0 * Double.pi
        let kickHz: Double = 48.0 + 60.0 * exp(-beat * 45.0)
        let kick: Double = 0.42 * exp(-beat * 22.0) * sin(tau * kickHz * beat)
        let bassEnvelope: Double = 0.6 + 0.4 * exp(-beat * 4.0)
        let bass: Double = 0.14 * sin(tau * 55.0 * t) * bassEnvelope
        let a: Double = sin(tau * 440.0 * t)
        let cSharp: Double = sin(tau * 554.37 * t)
        let e: Double = sin(tau * 659.25 * t)
        let chord: Double = 0.035 * (a + cSharp + e)
        let air: Double = 0.012 * sin(tau * 5_200.0 * t)
        let left: Double = kick + bass + chord + air
        let right: Double = kick + bass + 0.8 * chord - air
        return (Float(left), Float(right))
    }
}

#endif
