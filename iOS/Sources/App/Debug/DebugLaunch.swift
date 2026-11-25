//
//  DebugLaunch.swift
//  EQtargets (iOS)
//
//  Launch arguments for screenshots and QA. The simulator can't be tapped from
//  the command line, so every screen has to be reachable from here. Compiled out
//  of Release.
//
//    --demo                 Real pipeline, synthetic feeder (Preview builds)
//    --link-port=N          Private loopback port, for parallel runs on one Mac
//    --reset                Start from clean defaults
//    --seed                 A realistic Correction and tuning
//    --state=<status>       Show a state without audio: off, starting, waiting,
//                           idle, running, interrupted, feedback, passthrough, error
//    --scroll=<section>     output, graph, bands, bass
//    --open=settings        Open Settings
//    --open=import          Open the import preview (12 filters, 2 get dropped)
//    --open=import-failure  Open the import preview's failure state
//    --bass=punch|rumble|clean
//    --layer=target|tuning
//    --band=N               Select band N (1-10)
//    --chip=limiting|clipping|dropouts   Show a status chip
//    --offer                Show the Output card's "Use It" offer
//    --tuning-offer         The same offer for a Tuning saved for the Speaker
//

#if DEBUG

import Foundation

enum DebugLaunch {
    private static let arguments = ProcessInfo.processInfo.arguments

    static func value(_ name: String) -> String? {
        let prefix = "--\(name)="
        return arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    static func has(_ flag: String) -> Bool { arguments.contains("--\(flag)") }

    static var linkPort: UInt16? { value("link-port").flatMap(UInt16.init) }
    static var scrollTarget: String? { value("scroll") }
    /// A state screenshot must not start the real audio engine.
    static var usesStandIn: Bool { value("state") != nil }

    static func prepareDefaults() {
        guard has("reset"), let id = Bundle.main.bundleIdentifier else { return }
        UserDefaults.standard.removePersistentDomain(forName: id)
    }

    @MainActor
    static func apply(to model: AppModel) {
        if has("seed") { seed(model) }
        switch value("bass") {
        case "punch": model.selectBassStyle(.transientPunch)
        case "rumble": model.selectBassStyle(.sustainRumble)
        case "clean": model.selectBassStyle(.naturalClean)
        default: break
        }
        switch value("layer") {
        case "target": model.selectLayer(.target)
        case "tuning": model.selectLayer(.fineTune)
        default: break
        }
        if let n = value("band").flatMap(Int.init) { model.selectBand(n - 1) }
        if let state = value("state") { model.displayOverride = display(for: state) }
        switch value("chip") {
        case "limiting": seedChip(model, .limiting)
        case "clipping": seedChip(model, .clipping)
        case "dropouts": seedChip(model, .dropouts(3))
        default: break
        }
    }

    @MainActor
    private static func seedChip(_ model: AppModel, _ chip: StatusChipTracker.Chip) {
        model.meters.frozen = true
        model.meters.seed(boostDB: 2.4, trimDB: 0.8, chip: chip, overDB: 1.4)
    }

    /// Called once the main screen is up, because sheets need a presenter.
    @MainActor
    static func openRequestedSheet(_ model: AppModel) {
        if has("offer") {
            Task { @MainActor in
                // After `start()`, which re-evaluates the output and clears the offer.
                try? await Task.sleep(for: .milliseconds(500))
                let entry = model.presets.add(.correction, name: "Sennheiser HD 650", layer: model.dual.target)
                model.presets.bind(deviceUID: "debug-airpods", deviceName: "AirPods Max", to: entry.key)
                model.skippedCorrection = SkippedCorrection(key: entry.key, name: entry.displayName,
                                                            deviceUID: "debug-airpods", deviceName: "AirPods Max")
            }
        }
        if has("tuning-offer") {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                let entry = model.presets.add(.tuning, name: "Speaker Warm", layer: model.dual.fineTune)
                model.tuningBindings.bind(deviceUID: "debug-speaker", deviceName: "Speaker", to: entry.key)
                model.skippedTuning = SkippedCorrection(key: entry.key, name: entry.displayName,
                                                        deviceUID: "debug-speaker", deviceName: "Speaker")
            }
        }
        switch value("open") {
        case "settings":
            model.showSettings = true
        case "import":
            let filters = (1 ... 12).map { i -> String in
                let hz = Int(40 * pow(1.65, Double(i)))
                let gain = (i % 2 == 0 ? -1.0 : 1.0) * (Double(i % 5) + 0.6)
                return "Filter \(i): ON PK Fc \(hz) Hz Gain \(gain) dB Q 1.40"
            }
            let name = "Sennheiser HD 650 ParametricEQ.txt"
            model.importPreview = ImportPreview(result: AutoEQImport.parse(
                text: "Preamp: -3.1 dB\n" + filters.joined(separator: "\n"), sourceName: name, fileName: name))
        case "import-failure":
            model.importPreview = ImportPreview(result: AutoEQImport.parse(
                text: "This is not an EQ preset.", sourceName: "notes.txt", fileName: "notes.txt"))
        default:
            break
        }
    }

    @MainActor
    private static func seed(_ model: AppModel) {
        let text = """
        Preamp: -6.4 dB
        Filter 1: ON LSC Fc 105 Hz Gain 6.2 dB Q 0.70
        Filter 2: ON PK Fc 180 Hz Gain -3.1 dB Q 0.90
        Filter 3: ON PK Fc 420 Hz Gain 1.4 dB Q 1.20
        Filter 4: ON PK Fc 1250 Hz Gain -1.8 dB Q 2.00
        Filter 5: ON PK Fc 2900 Hz Gain 3.6 dB Q 1.80
        Filter 6: ON PK Fc 5300 Hz Gain -4.2 dB Q 3.50
        Filter 7: ON PK Fc 8100 Hz Gain 2.2 dB Q 2.60
        Filter 8: ON HSC Fc 11000 Hz Gain -2.4 dB Q 0.70
        """
        let result = AutoEQImport.parse(text: text, sourceName: "Sennheiser HD 600 ParametricEQ.txt",
                                        fileName: "Sennheiser HD 600 ParametricEQ.txt")
        var preview = ImportPreview(result: result)
        preview.bindToCurrentOutput = false
        model.applyImport(preview)
        if let tuning = model.presets.builtins(.tuning).first(where: { $0.name.hasPrefix("Bass Punch") }) {
            model.loadPreset(tuning, .tuning)
        }
        model.toast = nil
    }

    private static func display(for state: String) -> EngineDisplay {
        let headphones = OutputDevice(uid: "debug-airpods", name: "AirPods Max", transport: .bluetooth)
        var stats = EngineStats()
        stats.sampleRate = 48_000
        stats.outputBufferFrames = 480
        stats.latencyMs = 42
        stats.cpuLoad = 0.03
        func make(_ status: EngineStatus, powered: Bool = true,
                  output: OutputDevice? = headphones) -> EngineDisplay {
            EngineDisplay(status: status, isPowered: powered, currentOutput: output, stats: stats)
        }
        switch state {
        case "off": return make(.off, powered: false)
        case "starting": return make(.starting)
        case "waiting": return make(.waiting)
        case "idle": return make(.idle)
        case "running": return make(.running)
        case "interrupted": return make(.interrupted)
        case "feedback": return make(.feedbackGuard)
        case "passthrough": return make(.passThrough, powered: false)
        case "error":
            return make(.error("iOS would not start the audio session (561017449). Close other audio apps and try again."))
        default: return make(.waiting)
        }
    }
}

#endif
