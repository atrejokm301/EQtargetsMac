//
//  main.swift
//  eqt-engine — the EQtargets engine without the UI.
//
//    eqt-engine status
//        Driver present? Output devices, macOS default output, ring header.
//        Read-only: changes nothing.
//    eqt-engine run [--seconds N] [--output UID]
//        Powers the real engine on (routes macOS output through EQtargets
//        Audio), prints stats every second, and ALWAYS restores macOS's
//        default output on exit — normal end, Ctrl-C (SIGINT), SIGTERM, SIGHUP.
//        Refuses (exit 2, nothing touched) when the driver is not installed.
//    eqt-engine --offline-selftest [--seconds N]
//        No driver, no device: logic checks + simulated sessions through the
//        real render callback. Exit 1 on any FAIL.
//    eqt-engine --auhal-selftest [--seconds N] [--output UID]
//        The real AUHAL path on a real device, chain muted (silence). Does not
//        change the default output or any setting.
//    eqt-engine --driver-selftest [--seconds N]
//        The installed driver end to end: a test tone played INTO EQtargets
//        Audio by this process, read back through the real ring, reader and
//        chain, captured and analysed (nothing is played, nothing changed).
//    eqt-engine install-driver PATH | uninstall-driver
//        One admin prompt; restarts coreaudiod.
//

import CoreAudio
import Darwin
import Foundation

func option(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func usage() -> Int32 {
    print("""
    usage: eqt-engine status
           eqt-engine run [--seconds N] [--output UID]
           eqt-engine --offline-selftest [--seconds N]
           eqt-engine --auhal-selftest [--seconds N] [--output UID] [--non-rt-writer]
           eqt-engine --driver-selftest [--seconds N]
           eqt-engine install-driver PATH/EQtargetsAudio.driver
           eqt-engine uninstall-driver
    """)
    return 64
}

// MARK: - status

func statusCommand() -> Int32 {
    let virtualID = DeviceCatalog.virtualDevice()
    let defaultID = HAL.defaultOutputDevice()
    let systemID = HAL.defaultSystemOutputDevice()

    print("EQtargets engine status")
    if let v = virtualID {
        let rate = HAL.nominalSampleRate(v).map { "\($0.f(0)) Hz" } ?? "?"
        let vol = HAL.volumeScalar(v, elements: [kAudioObjectPropertyElementMain]).map { "\(($0 * 100).rounded())%" } ?? "?"
        let mute = HAL.isMuted(v, elements: [kAudioObjectPropertyElementMain]).map { $0 ? "muted" : "unmuted" } ?? "?"
        let eqtl = HAL.isSettable(v, HAL.address(EQT_PROPERTY_CLIENT_LATENCY)) ? "settable" : "not supported"
        print("  driver: EQtargets Audio INSTALLED (object \(v), \(rate), running somewhere: \(HAL.isRunningSomewhere(v)), volume \(vol) \(mute), 'eqtl' \(eqtl))")
    } else {
        print("  driver: EQtargets Audio NOT INSTALLED (no device with UID \(DeviceCatalog.virtualDeviceUID))")
    }

    // The engine's own view (constructing it changes nothing; its launch
    // recovery is deferred and this command exits first).
    let summary: (EngineStatus, Bool, [OutputDevice]) = MainActor.assumeIsolated {
        let engine = EngineController()
        return (engine.status, engine.isDriverInstalled, engine.outputDevices)
    }
    print("  engine status: \(summary.0)   isDriverInstalled: \(summary.1)")

    print("  output devices (engine order; EQtargets Audio and loops excluded):")
    for d in summary.2 {
        var flags: [String] = []
        if d.objectID == defaultID { flags.append("default out") }
        if d.objectID == systemID { flags.append("alert out") }
        func pad(_ t: String, _ n: Int) -> String { t.count >= n ? t : t + String(repeating: " ", count: n - t.count) }
        print("    " + pad("\(d.objectID)", 5) + pad(d.name, 34) + pad(d.transport.rawValue, 12)
              + pad("\(Int(d.nominalSampleRate)) Hz", 10) + pad("hw volume: \(d.hasHardwareVolume ? "yes" : "no")", 16)
              + "uid \(d.uid)" + (flags.isEmpty ? "" : "  [\(flags.joined(separator: ", "))]"))
    }
    let defName = defaultID.flatMap { HAL.name($0) } ?? "none"
    let defUID = defaultID.flatMap { HAL.uid($0) } ?? "-"
    print("  macOS default output: \(defName) (\(defUID))\(defaultID != nil && defaultID == virtualID ? "  ← EQtargets Audio" : "")")
    print("  macOS alert output:   \(systemID.flatMap { HAL.name($0) } ?? "none")")

    switch RingMapping.open() {
    case .success(let m):
        let h = m.header.pointee
        print("  ring \(EQT_RING_SHM_NAME): valid \(m.isValid), version \(h.version), \(h.channels) ch, capacity \(h.capacityFrames), rate \(m.sampleRate.f(0)), generation \(m.generation), writeHead \(m.writeHead), ioRunning \(m.ioRunning), ioBuffer \(m.ioBufferFrames), lastWrite \(m.lastWriteHostTime)")
    case .failure(let e):
        print("  ring \(EQT_RING_SHM_NAME): not available (\(e))")
    }
    let last = UserDefaults.standard.string(forKey: EngineController.lastRealOutputKey) ?? "-"
    print("  last real output (this tool's defaults): \(last)")
    return 0
}

// MARK: - run

@MainActor
enum RunCommand {
    static var engine: EngineController?
    static var sources: [DispatchSourceSignal] = []
    static var ticker: DispatchSourceTimer?
    static var finished = false

    static func start(seconds: Double?, outputUID: String?) -> Int32? {
        guard DeviceCatalog.virtualDevice() != nil else {
            print("eqt-engine run: EQtargets Audio driver is not installed (no device with UID \(DeviceCatalog.virtualDeviceUID)).")
            print("Nothing was changed. Install it with scripts/install-driver.sh or `eqt-engine install-driver PATH`.")
            return 2
        }
        let e = EngineController()
        engine = e
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler { MainActor.assumeIsolated { finish(code: 128 + sig, reason: "signal \(sig)") } }
            s.resume()
            sources.append(s)
        }
        atexit { MainActor.assumeIsolated { RunCommand.engine?.shutdown() } }
        if let uid = outputUID { e.selectOutput(uid: uid) }
        e.setPowered(true)
        print("powered on: status \(e.status), output \(e.currentOutput?.name ?? "none")")

        var elapsed = 0
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler {
            MainActor.assumeIsolated {
                elapsed += 1
                guard let e = engine else { return }
                let s = e.stats
                let m = e.meters()
                let rs = e.readerStats
                print(String(format: "t=%3ds %@ out=%@  %5.0f Hz buf %4d  lat %6.1f ms  drift %+7.1f ppm  under %d resync %d  cpu %5.2f%%  lock %@  in %6.1f out %6.1f dBFS  punch +%.1f/-%.1f  GR %.1f  vol %.2f%@",
                             elapsed, "\(e.status)", (e.currentOutput?.name ?? "-") as NSString, s.sampleRate, s.outputBufferFrames,
                             s.latencyMs, s.driftPPM, s.underruns, s.resyncs, s.cpuLoad * 100, "\(rs?.lock ?? .waiting)",
                             m.inputPeakDB, m.outputPeakDB, m.punchBoostDB, m.punchTrimDB, m.limiterReductionDB,
                             e.systemVolume, e.systemMuted ? " muted" : ""))
                fflush(stdout)
                if let seconds, Double(elapsed) >= seconds { finish(code: 0, reason: "--seconds elapsed") }
            }
        }
        t.resume()
        ticker = t
        return nil
    }

    static func finish(code: Int32, reason: String) {
        guard !finished else { return }
        finished = true
        ticker?.cancel()
        engine?.shutdown()
        let def = HAL.defaultOutputDevice().flatMap { HAL.name($0) } ?? "none"
        print("stopped (\(reason)); macOS default output is now: \(def)")
        fflush(stdout)
        exit(code)
    }
}

// MARK: - install / uninstall

func driverCommand(install path: String?) -> Int32 {
    var code: Int32 = 0
    let done = DispatchSemaphore(value: 0)
    Task { @MainActor in
        let e = EngineController()
        do {
            if let path { try await e.installDriver(from: URL(fileURLWithPath: path)) } else { try await e.uninstallDriver() }
            print(path == nil ? "driver removed" : "driver installed; EQtargets Audio is present")
        } catch {
            print("failed: \(error.localizedDescription)")
            code = 1
        }
        e.shutdown()
        done.signal()
    }
    // Keep the main queue running while waiting (the engine lives on it).
    while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    return code
}

// MARK: - main

let args = Array(CommandLine.arguments.dropFirst())
let seconds = option("--seconds", in: args).flatMap(Double.init)
setvbuf(stdout, nil, _IOLBF, 0)

switch args.first {
case "status":
    exit(statusCommand())
case "run":
    let started: Int32? = MainActor.assumeIsolated {
        RunCommand.start(seconds: seconds, outputUID: option("--output", in: args))
    }
    if let code = started { exit(code) }
    dispatchMain()
case "--offline-selftest":
    let r = SelfTestReport()
    print("eqt-engine offline self-test (no driver, no device, simulated time)")
    OfflineSelfTest.run(r, seconds: seconds)
    r.summary()
    exit(r.failed == 0 ? 0 : 1)
case "--auhal-selftest":
    let r = SelfTestReport()
    AUHALCheck.run(r, seconds: seconds ?? 20, outputUID: option("--output", in: args),
                   realtimeWriter: !args.contains("--non-rt-writer"))
    r.summary()
    exit(r.failed == 0 ? 0 : 1)
case "--driver-selftest":
    let r = SelfTestReport()
    if let code = DriverCheck.run(r, seconds: seconds ?? 20) { exit(code) }
    r.summary()
    exit(r.failed == 0 ? 0 : 1)
case "install-driver":
    guard args.count >= 2 else { exit(usage()) }
    exit(driverCommand(install: args[1]))
case "uninstall-driver":
    exit(driverCommand(install: nil))
default:
    exit(usage())
}
