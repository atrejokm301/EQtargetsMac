//
//  UISelfTest.swift
//  EQtargets (macOS) — DEBUG builds only.
//
//  `EQtargets --ui-selftest` runs behavioural checks of the app-side logic and
//  exits with the number of failures (0 = all passed). It lives in the app
//  target because EQTCoreTests compiles only EQTCore, and adding a test target
//  would mean editing project.yml (owned by the skeleton). Every check drives
//  the real code with a `StandInEngine` — no audio device is touched.
//
//  Each check is written to FAIL if the behaviour breaks (several were proven
//  by mutating the implementation; see the UI build report).
//

#if DEBUG
import Foundation
import AppKit

@MainActor
enum UISelfTest {
    private static var failures = 0
    private static var passes = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if ok { passes += 1; print("PASS  \(name)") }
        else { failures += 1; print("FAIL  \(name) \(detail())") }
    }

    private static func near(_ a: Double, _ b: Double, _ tol: Double) -> Bool { abs(a - b) <= tol }

    /// Private UserDefaults suite for a check (never the app's own domain).
    private static func scratchSuite(_ name: String) -> String { "com.eqtargets.app.selftest.\(name)" }

    static func runAndExit() -> Never {
        _ = NSApplication.shared
        formatting()
        graphTruth()
        ballistics()
        throttle()
        chips()
        importReport()
        presetStore()
        modelBehaviour()
        meterHub()
        symbols()
        quitAndInstallSeams()
        reviewFixes()
        realEngineSeam()          // LAST: leaves EQT_DEVICE_UID_OVERRIDE set until exit
        print("ui-selftest: \(passes) passed, \(failures) failed")
        exit(Int32(min(failures, 125)))
    }

    // MARK: Formatting / parsing (§6.3)

    static func formatting() {
        let n = EQFormat.nbsp, m = EQFormat.minus
        check("format 31.5 Hz", EQFormat.frequency(31.5) == "31.5\(n)Hz", EQFormat.frequency(31.5))
        check("format 63 Hz", EQFormat.frequency(63) == "63\(n)Hz", EQFormat.frequency(63))
        check("format 125 Hz", EQFormat.frequency(125) == "125\(n)Hz")
        check("format 1.25 kHz", EQFormat.frequency(1_250) == "1.25\(n)kHz", EQFormat.frequency(1_250))
        check("format 999.6 Hz rounds into kHz", EQFormat.frequency(999.6) == "1.00\(n)kHz", EQFormat.frequency(999.6))
        check("format 9996 Hz → 10.0 kHz (3 sig. digits)", EQFormat.frequency(9_996) == "10.0\(n)kHz", EQFormat.frequency(9_996))
        check("format gain +4.0", EQFormat.gain(4) == "+4.0\(n)dB")
        check("format gain uses U+2212", EQFormat.gain(-3) == "\(m)3.0\(n)dB")
        check("format gain −0.04 → 0.0", EQFormat.gain(-0.04) == "0.0\(n)dB", EQFormat.gain(-0.04))
        check("parse 1200", EQFormat.parseFrequency("1200") == 1_200)
        check("parse 1.2k", EQFormat.parseFrequency("1.2k") == 1_200)
        check("parse 1.2 kHz", EQFormat.parseFrequency("1.2 kHz") == 1_200)
        check("parse 1,200 (thousands)", EQFormat.parseFrequency("1,200") == 1_200)
        check("parse 1,5 (decimal comma)", EQFormat.parseQ("1,5") == 1.5)
        check("parse −3 (U+2212)", EQFormat.parseGain("\(m)3") == -3)
        check("parse +3 dB", EQFormat.parseGain("+3 dB") == 3)
        check("parse garbage → nil", EQFormat.parseGain("loud") == nil && EQFormat.parseFrequency("") == nil)
        check("format sample rates", EQFormat.sampleRate(44_100) == "44.1\(n)kHz" && EQFormat.sampleRate(48_000) == "48\(n)kHz")
    }

    // MARK: Graph == DSP (§7.1, QA G-1)

    static func graphTruth() {
        var dual = DualEQState.flat
        dual.fineTune.bands[5] = EQBand(frequency: 1_000, gain: 12, q: 10)
        let c = ResponseMath.curves(dual: dual, sampleRate: 48_000, count: 256)
        let peak = c.total.max() ?? 0
        check("G-1 +12 dB Q10 apex drawn at +12.0 ±0.1", near(peak, 12, 0.1), "got \(peak)")
        // Negative control: the 96-point fixed grid really does miss it.
        let old = FrequencyResponse.curves(dual: dual).combined.map(\.magnitudeDB).max() ?? 0
        check("G-1 control: old 96-pt grid undershoots (> 1 dB low)", old < 11, "old \(old)")

        // Same formula as EQBiquad at an arbitrary frequency, preamp included.
        var layer = EQLayerState.flat
        layer.preamp = -3
        layer.bands[2] = EQBand(frequency: 125, gain: 4, q: 1.41)
        layer.bands[9] = EQBand(frequency: 9_000, gain: -5, q: 0.71, filterType: .highShelf)
        let f = 3_333.0, sr = 44_100.0
        let trig = ResponseMath.Trig(frequencies: [f], sampleRate: sr)
        let got = ResponseMath.layerDB(layer, trig: trig, sampleRate: sr)[0]
        let want = -3 + EQBiquad(type: .peak, frequency: 125, gainDB: 4, q: 1.41, sampleRate: sr).magnitudeDB(at: f, sampleRate: sr)
            + EQBiquad(type: .highShelf, frequency: 9_000, gainDB: -5, q: 0.71, sampleRate: sr).magnitudeDB(at: f, sampleRate: sr)
        check("graph matches EQBiquad (incl. preamp) to 1e-9", near(got, want, 1e-9), "\(got) vs \(want)")

        // Running sample rate changes the drawn shape near Nyquist.
        var hs = EQLayerState.flat
        hs.bands[9] = EQBand(frequency: 16_000, gain: 6, q: 0.71, filterType: .highShelf)
        let g441 = ResponseMath.layerDB(hs, trig: .init(frequencies: [19_000], sampleRate: 44_100), sampleRate: 44_100)[0]
        let g96 = ResponseMath.layerDB(hs, trig: .init(frequencies: [19_000], sampleRate: 96_000), sampleRate: 96_000)[0]
        check("G-1 16 kHz shelf differs between 44.1 and 96 kHz", abs(g441 - g96) > 0.1, "\(g441) vs \(g96)")

        // Bypassed layer contributes nothing — not even its preamp (DSP rule).
        var bp = DualEQState.flat
        bp.target.preamp = -6
        bp.target.bands[0].gain = 5
        bp.target.isBypassed = true
        let z = ResponseMath.curves(dual: bp, sampleRate: 48_000, count: 256).total
        check("bypassed layer draws 0 dB (preamp ignored)", ResponseMath.maxAbs(z) < 1e-12)

        check("grid merges band centres", ResponseMath.grid(count: 256, centres: [1_000, 1_234.5]).contains(1_234.5))
        check("point count clamps 256…1024", ResponseMath.pointCount(plotWidth: 100) == 256 && ResponseMath.pointCount(plotWidth: 5_000) == 1_024)
    }

    // MARK: Meter ballistics (§8.2)

    static func ballistics() {
        var b = MeterBallistics(intervalSeconds: 1.0 / 30)
        b.feed(boostDB: 6, trimDB: 0)
        check("meter: instant rise", b.boostDB == 6)
        b.feed(boostDB: 0, trimDB: 0, elapsed: 0.150)
        check("meter: −45% after 150 ms (0.82^3)", near(b.boostDB, 6 * pow(0.82, 3), 1e-9), "\(b.boostDB)")
        var c = MeterBallistics(intervalSeconds: 1.0 / 30)
        c.feed(boostDB: 6, trimDB: 0)
        for _ in 0 ..< 3 { c.feed(boostDB: 0, trimDB: 0, elapsed: 0.050) }
        check("meter: fall is rate-independent", near(c.boostDB, b.boostDB, 1e-9))
        check("meter: nominal decay at 30 Hz = 0.876", near(MeterBallistics(intervalSeconds: 1.0 / 30).decay, 0.8761, 0.0005))
        var r = MeterBallistics(intervalSeconds: 1.0 / 30)
        r.feed(boostDB: 1, trimDB: 2.5)
        check("meter: readout shows larger side, U+2212", r.readout == "\(EQFormat.minus)2.5\(EQFormat.nbsp)dB", r.readout)
        check("meter: 9 dB full scale, clamped", MeterBallistics.fraction(4.5) == 0.5 && MeterBallistics.fraction(20) == 1)
        var idle = MeterBallistics(intervalSeconds: 1.0 / 30)
        idle.feed(boostDB: 0.01, trimDB: 0.02)
        check("meter: idle below 0.05 dB", idle.isIdle && idle.readout == "0.0\(EQFormat.nbsp)dB")
        let p = MeterCeilings.ceilings(for: .transientPunch), q = MeterCeilings.ceilings(for: .sustainRumble)
        check("meter: ceiling marks 6/9 and 4/7", p?.left == 6 && p?.right == 9 && q?.left == 4 && q?.right == 7)
    }

    // MARK: Throttle (≤ 60 Hz + trailing)

    static func throttle() {
        var gate = ThrottleGate(interval: 1.0 / 60)
        var scheduled: Double?
        var sends: [(t: Double, v: Int)] = []
        var latest = 0
        for i in 0 ..< 1_000 {
            let t = Double(i) / 1_000
            if let s = scheduled, s <= t { gate.trailingFired(now: s); sends.append((s, latest)); scheduled = nil }
            latest = i
            switch gate.offer(now: t) {
            case .fire: sends.append((t, i))
            case .schedule(let d): scheduled = t + d
            case .coalesce: break
            }
        }
        if let s = scheduled { gate.trailingFired(now: s); sends.append((s, latest)) }
        let gaps = zip(sends.dropFirst(), sends).map { $0.t - $1.t }
        check("throttle: ≤ 61 sends for 1000 events in 1 s", sends.count <= 61 && sends.count >= 55, "\(sends.count)")
        check("throttle: no two sends closer than 1/60 s", (gaps.min() ?? 1) >= 1.0 / 60 - 1e-9, "\(gaps.min() ?? -1)")
        check("throttle: last value always delivered", sends.last?.v == 999)
        check("throttle: first event is not delayed", sends.first?.t == 0)
    }

    // MARK: Status chips (§6.7)

    static func chips() {
        var t = StatusChipTracker()
        var m = ChainMeters()
        m.overCount = 40
        t.observe(meters: m, underruns: 3, protectionOn: true, now: 0)
        check("chips: first reading is a baseline, not an event", t.chip(now: 0) == nil)
        m.overCount = 41
        t.observe(meters: m, underruns: 3, protectionOn: true, now: 1)
        check("chips: overCount moving with protection → Limiting", t.chip(now: 1) == .limiting)
        check("chips: Limiting holds 2 s then clears", t.chip(now: 2.9) == .limiting && t.chip(now: 3.1) == nil)
        m.overCount = 42
        t.observe(meters: m, underruns: 5, protectionOn: false, now: 4)
        check("chips: protection off → Clipping outranks the rest", t.chip(now: 4) == .clipping)
        check("chips: dropouts counted for 10 s", t.chip(now: 7) == .dropouts(2) && t.chip(now: 14.5) == nil)
        var l = StatusChipTracker()
        var lm = ChainMeters()
        lm.limiterReductionDB = 0.5
        l.observe(meters: lm, underruns: 0, protectionOn: true, now: 0)
        check("chips: limiter reduction > 0.1 dB → Limiting", l.chip(now: 0) == .limiting)
    }

    // MARK: Import (§6.5)

    static func importReport() {
        switch AutoEQImport.parse(text: SnapshotRenderer.sampleTwelve, sourceName: "x", fileName: "Sennheiser HD 600 ParametricEQ.txt") {
        case .success(let c):
            check("import: 12 filters counted", c.filtersInFile == 12, "\(c.filtersInFile)")
            check("import: the 2 smallest were dropped", c.dropped.count == 2
                  && c.dropped.contains { $0.frequency == 6_100 } && c.dropped.contains { $0.frequency == 14_000 }, "\(c.dropped)")
            check("import: file preamp read", c.filePreampDB == -6.2)
            check("import: preamp never positive", c.measuredPreampDB <= 0)
            check("import: name cleaned", c.suggestedName == "Sennheiser HD 600", c.suggestedName)
        case .failure(let f):
            check("import: sample parses", false, "\(f)")
        }
        check("import: empty → .empty", AutoEQImport.parse(text: "  \n", sourceName: "e", fileName: nil) == .failure(.empty))
        check("import: GraphicEQ → .noFilters",
              AutoEQImport.parse(text: "GraphicEQ: 20 -3.1; 21 -3.0", sourceName: "g", fileName: nil) == .failure(.noFilters))
        let binary = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01])
        if case .failure(.unreadable) = AutoEQImport.parse(data: binary, sourceName: "a.png", fileName: "a.png") {
            check("import: binary file → unreadable (not 'no filters')", true)
        } else { check("import: binary file → unreadable (not 'no filters')", false) }
        let big = Data(repeating: 0x41, count: AutoEQImport.maxBytes + 1)
        check("import: > 1 MB → tooLarge", AutoEQImport.parse(data: big, sourceName: "b", fileName: nil) == .failure(.tooLarge))
        check("import: underscore names", AutoEQImport.suggestedName(fileName: "oratory1990_HD_650.txt") == "oratory1990 HD 650")
        let shelves = "Preamp: -3 dB\nFilter 1: ON LSC Fc 105 Hz Gain 3 dB Q 0.7\nFilter 2: ON HSC Fc 8000 Hz Gain -2 dB Q 0.7"
        if case .success(let s) = AutoEQImport.parse(text: shelves, sourceName: "s", fileName: nil) {
            check("import: shelves kept, 2 filters", s.filtersInFile == 2 && s.layer.bands[0].filterType == .lowShelf
                  && s.layer.bands[1].filterType == .highShelf && s.dropped.isEmpty)
        } else { check("import: shelves parse", false) }
        check("paste: detects filters", AutoEQImport.containsFilters(SnapshotRenderer.sampleCorrection) && !AutoEQImport.containsFilters("hello"))
    }

    // MARK: Presets (tolerant decoding, stable keys)

    static func presetStore() {
        let suite = "com.eqtargets.app.selftest"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        defer { d.removePersistentDomain(forName: suite) }
        let json = """
        [ {"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","name":"Good","layer":{"preamp":-2,"bands":[{"frequency":100,"gain":3}]}},
          {"id":12345,"name":["bad"]},
          {"name":"No id, bad band","layer":{"bands":[{"gain":"x"},{"frequency":2000,"gain":-1,"q":2}]}},
          "garbage" ]
        """
        d.set(Data(json.utf8), forKey: PresetStore.Keys.corrections)
        let s = PresetStore(defaults: d, persist: true)
        let names = s.user(.correction).map(\.name)
        check("presets: corrupt records skipped, good ones kept", names == ["Good", "No id, bad band"], "\(names)")
        let good = s.user(.correction).first
        check("presets: short band list padded to 10 + clamped", good?.layer.bands.count == 10 && good?.layer.preamp == -2)
        let second = s.user(.correction).dropFirst().first
        check("presets: bad band dropped, good band kept", second?.layer.bands.first?.frequency == 2_000)
        let a = s.add(.correction, name: "Good", layer: .flat)
        check("presets: unique names get ' 2'", a.name == "Good 2", a.name)
        s.bind(deviceUID: "dev", deviceName: "Dev", to: a.key)
        let reloaded = PresetStore(defaults: d)
        check("presets: round-trip + binding persisted", reloaded.user(.correction).count == 3 && reloaded.boundKey(for: "dev") == a.key)
        reloaded.delete(a.key, .correction)
        check("presets: delete drops its bindings", reloaded.boundKey(for: "dev") == nil)
    }

    // MARK: AppModel behaviour

    static func spin(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    /// Runs the main run loop until `done` or `timeout`: a real-time sleep
    /// inside the code under test may take longer on a loaded machine.
    static func spinUntil(_ timeout: Double, _ done: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !done(), Date() < deadline { spin(0.01) }
    }

    static func modelBehaviour() {
        let suite = "com.eqtargets.app.selftest.model"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        defer { d.removePersistentDomain(forName: suite) }
        let engine = StandInEngine()
        let model = AppModel(engine: engine, defaults: d, mode: .preview)
        var now = 100.0
        model.clock = { now }

        // Throttle through the model: a burst at one instant → 1 send + 1 trailing.
        let before = engine.applied.count
        for g in 1 ... 50 { model.updateBand(3) { $0.gain = Double(g) / 10 } }
        check("model: burst sends once immediately", engine.applied.count == before + 1, "\(engine.applied.count - before)")
        now += 1
        spinUntil(2) { abs((engine.applied.last?.dual.fineTune.bands[3].gain ?? 0) - 5.0) < 1e-9 }
        check("model: trailing update delivers the final value",
              abs((engine.applied.last?.dual.fineTune.bands[3].gain ?? 0) - 5.0) < 1e-9, "\(engine.applied.last?.dual.fineTune.bands[3].gain ?? -1)")
        let n = engine.applied.count
        model.selectLayer(.target)
        check("model: switching edited layer is not a DSP change", engine.applied.count == n)
        model.compareHeld = true
        check("model: compare bypasses the throttle (instant)", engine.applied.last?.masterBypass == true)
        model.compareHeld = false

        // Undo: one step per gesture.
        let um = UndoManager()
        um.groupsByEvent = false
        model.undoManager = um
        model.selectLayer(.fineTune)
        let g0 = model.band(2).gain
        model.beginGesture()
        for k in 1 ... 30 { model.updateBand(2) { $0.gain = g0 + Double(k) * 0.1 } }
        um.beginUndoGrouping(); model.endGesture("Move Band 3"); um.endUndoGrouping()
        check("undo: action name", um.undoActionName == "Move Band 3", um.undoActionName)
        um.undo()
        check("undo: one step reverts the whole drag", near(model.band(2).gain, g0, 1e-12) && !um.canUndo)
        um.redo()
        check("redo: restores the drag end", near(model.band(2).gain, g0 + 3, 1e-9))

        // Import: Your tuning untouched, binding by UID, one undo step.
        model.displayOverride = SnapshotRenderer.running()
        let fineBefore = model.dual.fineTune
        var p = ImportPreview(result: AutoEQImport.parse(text: SnapshotRenderer.sampleCorrection, sourceName: "f", fileName: "Foo ParametricEQ.txt"))
        p.bindToCurrentOutput = true
        um.beginUndoGrouping(); model.applyImport(p); um.endUndoGrouping()
        check("import: Your tuning stays exactly as it is", model.dual.fineTune == fineBefore)
        check("import: editing layer becomes Your tuning", model.dual.editingLayer == .fineTune)
        check("import: bound to current output UID", model.presets.boundKey(for: SnapshotRenderer.airpods.uid) == model.correctionKey)
        check("import: correction named from file", model.currentEntry(.correction)?.name == "Foo")
        um.undo()
        check("import: one undo step reverts the curve", model.dual.target.isFlat)
        um.redo()
        // The rest doesn't test undo; this manager needs explicit groups.
        model.undoManager = nil

        // Device binding: output change loads the bound correction.
        model.loadPreset(model.presets.builtins(.correction)[0], .correction)
        model.outputDidChange(SnapshotRenderer.airpods)
        check("binding: output change loads bound correction", !model.dual.target.isFlat && model.toast?.text.contains("AirPods Pro") == true)

        // Headroom fix: total never exceeds 0 dB afterwards.
        model.loadPreset(model.presets.builtins(.correction)[0], .correction)
        model.updateBand(4, layer: .fineTune) { $0.gain = 9; $0.q = 2 }
        model.setPreamp(0, layer: .fineTune)
        model.applyHeadroomFix()
        check("headroom fix: total peak ≤ 0 dB", model.totalPeakDB <= 0.01, "\(model.totalPeakDB)")
        check("headroom fix: rounded to 0.5 dB", near((model.dual.fineTune.preamp * 2).rounded(), model.dual.fineTune.preamp * 2, 1e-9))

        // Bass style chip applies the recommended cutoff (iOS semantics).
        model.selectBassStyle(.sustainRumble)
        check("bass: Rumble chip sets 55 Hz", model.bass.cutoff == 55 && model.bass.cutoffMatchesStyleRecommendation)

        // Persistence round trip (live mode on a scratch suite, stand-in engine).
        let live = AppModel(engine: StandInEngine(), defaults: d, mode: .live)
        live.updateBand(1, layer: .fineTune) { $0.gain = 4.5 }
        live.bass.selectStyle(.transientPunch)
        live.shutdown()
        let again = AppModel(engine: StandInEngine(), defaults: d, mode: .live)
        check("persist: layers and bass survive relaunch",
              again.dual.fineTune.bands[1].gain == 4.5 && again.bass.style == .transientPunch)
    }

    // MARK: Meter hub: no lease → no polling (QA B-2)

    static func meterHub() {
        let hub = MeterHub()
        var reads = 0
        hub.read = { reads += 1; var m = ChainMeters(); m.punchBoostDB = 3; return m }
        spin(0.2)
        check("hub: zero polls without a lease", reads == 0 && !hub.isPolling)
        let lease = hub.acquire(.activity)
        spin(0.3)
        let during = reads
        check("hub: ~30 Hz while an activity lease is held", during >= 5 && during <= 12, "\(during) reads in 0.3 s")
        check("hub: activity feeds the ballistics", hub.activity.boostDB > 2.9)
        hub.release(lease)
        spin(0.05)
        let after = reads
        spin(0.3)
        check("hub: polling stops when the last lease is released", reads == after && !hub.isPolling, "\(reads - after) extra")
        check("hub: meter resets when nobody watches", hub.activity.isIdle)
        let s = hub.acquire(.status)
        spin(0.5)
        check("hub: status lease polls slowly (≈5 Hz)", reads - after >= 1 && reads - after <= 4, "\(reads - after)")
        hub.release(s)
    }

    // MARK: SF Symbols (QA SF-1)

    static func symbols() {
        let names = ["laptopcomputer", "headphones", "airpods", "airpodspro", "airpodsmax", "hifispeaker", "display",
                     "airplayaudio", "bolt.horizontal", "speaker.wave.2", "slider.vertical.3", "exclamationmark.triangle.fill",
                     "xmark.octagon.fill", "power", "circle.lefthalf.filled", "lock.fill", "square.and.arrow.down",
                     "sidebar.right", "link", "pencil", "arrow.counterclockwise", "info.circle", "water.waves",
                     "waveform.path", "leaf", "speaker.slash.fill", "arrow.down.to.line", "arrow.up.to.line",
                     "chevron.up.chevron.down", "key.fill", "mic.slash.fill", "record.circle", "trash",
                     "checkmark.circle.fill", "circle.dotted", "nosign", "slider.horizontal.3", "speaker.slash"]
        let missing = names.filter { !TransportSymbol.exists($0) }
        check("SF-1 every SF Symbol used exists", missing.isEmpty, "missing: \(missing)")
    }

    // MARK: Integration seams: quit, termination signals, driver install

    /// The app ⇄ engine seams that need no audio device: quit hands the output
    /// back (live only), SIGTERM becomes a normal quit, the installer's real
    /// error mapping reaches the right onboarding state, and the driver the
    /// engine installs is the one embedded in THIS app.
    static func quitAndInstallSeams() {
        let suite = "com.eqtargets.app.selftest.seams"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        defer { d.removePersistentDomain(forName: suite) }

        // Quit → engine.shutdown() (restores macOS's default output) in live mode only.
        let liveEngine = StandInEngine()
        AppModel(engine: liveEngine, defaults: d, mode: .live).shutdown()
        check("quit: live model calls engine.shutdown() once", liveEngine.shutdownCalls == 1, "\(liveEngine.shutdownCalls)")
        let previewEngine = StandInEngine()
        AppModel(engine: previewEngine, defaults: d, mode: .preview).shutdown()
        check("quit: preview/snapshot model never calls engine.shutdown()", previewEngine.shutdownCalls == 0)

        // SIGTERM must reach the handler instead of killing the process. If the
        // SIG_IGN + dispatch-source pairing breaks, this kill() ends the self-test
        // with a non-zero status — a failure either way.
        var received: Int32 = 0
        TerminationSignals.install([SIGTERM]) { received = $0 }
        kill(getpid(), SIGTERM)
        spin(0.3)
        check("quit: SIGTERM is delivered to the quit handler (process survives to quit cleanly)", received == SIGTERM, "\(received)")

        // The engine's real osascript error mapping → onboarding state.
        let stand = StandInEngine()
        let model = AppModel(engine: stand, defaults: d, mode: .preview)
        func install(_ result: Result<Void, Error>) -> InstallState {
            stand.installResult = result
            model.installState = .idle
            Task { @MainActor in await model.installDriver() }
            let deadline = Date().addingTimeInterval(2)
            while model.installState == .idle || model.installState == .installing, Date() < deadline { spin(0.01) }
            return model.installState
        }
        let cancelErr = DriverInstaller.error(from: .init(status: 1, stdout: "", stderr: "0:183: execution error: User canceled. (-128)"))
        check("install: osascript −128 maps to an error", cancelErr != nil)
        if let cancelErr {
            check("install: cancelled password → .cancelled, back on the Driver step",
                  install(.failure(cancelErr)) == .cancelled && model.onboardingStep == .driver && !model.onboardingCompleted,
                  "\(model.installState)")
        }
        let denied = DriverInstaller.error(from: .init(status: 1, stdout: "", stderr: "0:183: execution error: ditto: /Library/Audio/Plug-Ins/HAL: Operation not permitted (1)"))
        if let denied {
            let s = install(.failure(denied))
            if case .failed(let m) = s {
                check("install: real failure → .failed with the system's message", m.contains("Operation not permitted"), m)
            } else {
                check("install: real failure → .failed with the system's message", false, "\(s)")
            }
        } else {
            check("install: non-zero osascript status maps to an error", false)
        }
        if case .failed = install(.failure(DriverInstallError.timedOut(installing: true))) {
            check("install: device never appeared → .failed (not cancelled)", true)
        } else {
            check("install: device never appeared → .failed (not cancelled)", false, "\(model.installState)")
        }
        check("install: success → .done and onboarding completed",
              install(.success(())) == .done && model.onboardingStep == .done && model.onboardingCompleted)

        // EngineController.installDriver() installs DriverInstaller.embeddedDriver(),
        // i.e. the copy inside this very app.
        let embedded = DriverInstaller.embeddedDriver()
        check("install source is <this app>/Contents/Resources/EQtargetsAudio.driver",
              embedded.path == Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/EQtargetsAudio.driver").path,
              embedded.path)
        var valid = true
        do { try DriverInstaller.validate(embedded) } catch { valid = false }
        check("embedded driver validates (bundle id, executable)", valid)
    }

    /// The REAL `EngineController` under the REAL `AppModel`, on the real HAL,
    /// with the installed driver hidden (`EQT_DEVICE_UID_OVERRIDE`, DEBUG only):
    /// first run without a driver must show onboarding, request power without
    /// routing, survive launch recovery, apply/meters and quit — and macOS's
    /// default and alert outputs must never change.
    ///
    /// INTERLOCK: if the override does not hide the driver, nothing that could
    /// route is ever called. The override stays set until the process exits, and
    /// the engine is shut down (inert) before this returns.
    static func realEngineSeam() {
        setenv("EQT_DEVICE_UID_OVERRIDE", "com.eqtargets.selftest.no-such-device", 1)
        guard DeviceCatalog.virtualDevice() == nil else {
            check("seam: override hides the installed driver (interlock)", false, "driver still visible: real-engine checks skipped")
            return
        }
        let defaultBefore = HAL.defaultOutputDevice()
        let alertBefore = HAL.defaultSystemOutputDevice()
        func untouched() -> Bool { HAL.defaultOutputDevice() == defaultBefore && HAL.defaultSystemOutputDevice() == alertBefore }

        let suite = "com.eqtargets.app.selftest.realengine"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        defer { d.removePersistentDomain(forName: suite) }

        let engine = EngineController()
        let model = AppModel(engine: engine, defaults: d, mode: .live)
        check("seam: real engine reports .driverMissing", engine.status == .driverMissing && !engine.isDriverInstalled, "\(engine.status)")
        check("seam: first run without driver offers onboarding", model.shouldOfferOnboarding)
        check("seam: the toolbar's display agrees", model.display.status == .driverMissing && !model.display.driverInstalled)

        model.start()
        check("seam: start() requests power (auto-starts once the driver appears)", engine.isPowered)
        check("seam: start() wires onOutputChanged", engine.onOutputChanged != nil)
        spin(2.0)                                        // past the engine's 1.5 s launch-recovery deferral
        check("seam: still .driverMissing and nothing routed after launch",
              engine.status == .driverMissing && engine.currentOutput == nil, "\(engine.status)")
        check("seam: launch never touched macOS default/alert output", untouched())

        for g in 0 ..< 120 { model.updateBand(0, layer: .fineTune) { $0.gain = Double(g % 12) } }
        spin(0.1)
        let m = engine.meters()
        check("seam: drag-rate apply + meters with no stream: silent meters, output untouched",
              m.outputPeakDB <= -119.9 && m.inputPeakDB <= -119.9 && untouched(), "\(m)")

        model.onboardingCompleted = true
        check("seam: onboarding is not offered again once completed/dismissed", !model.shouldOfferOnboarding)

        model.shutdown()
        check("seam: quit leaves default/alert output as they were (nothing of ours to restore)", untouched())
        engine.setPowered(true)
        spin(0.2)
        check("seam: engine is inert after shutdown (setPowered ignored)",
              engine.currentOutput == nil && untouched(), "\(engine.status)")
    }
}
// BEGIN review-fix checks — 2026-11-05 review fixes. Self-contained: the review
// harness compiles this region verbatim against the real Logic/Model sources.
extension UISelfTest {
    static func reviewFixes() {
        valueFieldCommitRules()
        importEncodings()
        presetKeysAreNames()
        boundCorrectionKeepsEdits()
        inspectorCommitsTargetTheirLayer()
        settingsRenameByKey()
        limiterPreampFix()
        holdBCompare()
        launchPowerFollowsCheckbox()
        statusReadersSkipStats()
        singleInstanceDecision()
        spokenFrequencies()
    }

    /// Box for `withObservationTracking`'s @Sendable onChange.
    final class Flag: @unchecked Sendable { var fired = false }

    // Inspector fields commit only what the user typed (finding: blur re-commit).
    static func valueFieldCommitRules() {
        let n = EQFormat.nbsp, m = EQFormat.minus
        let gain = EQFormat.gain, pGain = EQFormat.parseGain
        let freq = EQFormat.frequency, pFreq = EQFormat.parseFrequency
        let pre = EQLayerState.preampRange, fr = EQBand.frequencyRange

        // Kevin's AirPods Max 2 preamp −10.531 shows as −10.5; tabbing through must not write −10.5.
        var e = ValueFieldEditor()
        e.reset(to: -10.530832, format: gain)
        check("field: shows the rounded value", e.text == "\(m)10.5\(n)dB", e.text)
        check("field: focus + blur with nothing typed never commits",
              e.finish(value: -10.530832, format: gain, parse: pGain, range: pre) == .none)
        var f = ValueFieldEditor()
        f.reset(to: 1_371, format: freq)
        check("field: untouched 1371 Hz is not rounded to 1370 on Return / blur",
              f.finish(value: 1_371, format: freq, parse: pFreq, range: fr) == .none)

        // Typed once, committed once; the blur after Return re-commits nothing (1234 must not become 1230).
        var t = ValueFieldEditor()
        t.reset(to: 1_000, format: freq)
        t.userEdited("1234")
        check("field: typed 1234 commits 1234", t.finish(value: 1_000, format: freq, parse: pFreq, range: fr) == .commit(1_234))
        check("field: the blur after Return commits nothing",
              t.finish(value: 1_234, format: freq, parse: pFreq, range: fr) == .none && t.text == "1.23\(n)kHz", t.text)

        // A clean field follows the model even while focused (stepper, scroll-to-Q, drag, undo).
        var c = ValueFieldEditor()
        c.reset(to: 0, format: gain)
        c.sync(to: 3, format: gain)
        check("field: a clean field follows a model change", c.text == "+3.0\(n)dB", c.text)
        check("field: … and then commits nothing on blur", c.finish(value: 3, format: gain, parse: pGain, range: EQBand.gainRange) == .none)

        // Typing in progress survives a model change and wins on commit.
        var d = ValueFieldEditor()
        d.reset(to: 0, format: gain)
        d.userEdited("6")
        d.sync(to: 3, format: gain)
        check("field: typing in progress survives a model change", d.text == "6", d.text)
        check("field: … and commits the typed value", d.finish(value: 3, format: gain, parse: pGain, range: EQBand.gainRange) == .commit(6))

        // Garbage → invalid + revert; out of range → clamped.
        var g = ValueFieldEditor()
        g.reset(to: 2, format: gain)
        g.userEdited("loud")
        check("field: unparsable typing → invalid, text reverted",
              g.finish(value: 2, format: gain, parse: pGain, range: EQBand.gainRange) == .invalid && g.text == gain(2), g.text)
        var o = ValueFieldEditor()
        o.reset(to: 0, format: gain)
        o.userEdited("+99")
        check("field: out-of-range typing is clamped",
              o.finish(value: 0, format: gain, parse: pGain, range: EQBand.gainRange) == .commit(EQBand.gainRange.upperBound))

        // Typing back exactly what was shown is not an edit; an echo of the same text is not typing.
        var r = ValueFieldEditor()
        r.reset(to: 1_371, format: freq)
        r.userEdited("1.3")
        r.userEdited(freq(1_371))
        check("field: typing back the shown text commits nothing", r.finish(value: 1_371, format: freq, parse: pFreq, range: fr) == .none)
        var echo = ValueFieldEditor()
        echo.reset(to: 1_371, format: freq)
        echo.userEdited(echo.text)
        check("field: the binding echoing the same text is not typing", !echo.dirty)

        // Arrow keys step from the exact value, not the rounded text.
        var a = ValueFieldEditor()
        a.reset(to: 1_371, format: freq)
        check("field: arrow-key base is the exact model value", a.stepBase(value: 1_371, parse: pFreq) == 1_371)
        a.userEdited("2k")
        check("field: arrow-key base is the typed value while typing", a.stepBase(value: 1_371, parse: pFreq) == 2_000)
    }

    /// Kevin's "Apple AirPods Max 2 Filters.txt", byte for byte (CRLF, 500 bytes).
    static let airPodsMax2Lines = [
        "Preamp: -10.5 dB",
        "Filter 1: ON PK Fc 28 Hz Gain -6.6 dB Q 0.500",
        "Filter 2: ON PK Fc 38 Hz Gain 1.1 dB Q 2.500",
        "Filter 3: ON PK Fc 75 Hz Gain -1.0 dB Q 2.700",
        "Filter 4: ON PK Fc 210 Hz Gain -1.5 dB Q 1.100",
        "Filter 5: ON PK Fc 850 Hz Gain -1.2 dB Q 0.700",
        "Filter 6: ON PK Fc 5000 Hz Gain 10.0 dB Q 3.000",
        "Filter 7: ON PK Fc 6300 Hz Gain 2.5 dB Q 0.500",
        "Filter 8: ON PK Fc 6500 Hz Gain -6.0 dB Q 3.000",
        "Filter 9: ON PK Fc 9300 Hz Gain -4.4 dB Q 3.000",
        "Filter 10: ON PK Fc 13000 Hz Gain -4.9 dB Q 3.000",
    ]

    static func importEncodings() {
        let text = airPodsMax2Lines.joined(separator: "\r\n") + "\r\n"
        let utf8 = Data(text.utf8)
        check("import fixture: same 500 bytes as the real file", utf8.count == 500, "\(utf8.count)")
        func verify(_ label: String, _ data: Data) {
            switch AutoEQImport.parse(data: data, sourceName: "Apple AirPods Max 2 Filters.txt", fileName: "Apple AirPods Max 2 Filters.txt") {
            case .success(let c):
                let b = c.layer.bands[5]
                check("import \(label): 10 filters, none dropped, file preamp −10.5",
                      c.filtersInFile == 10 && c.dropped.isEmpty && c.filePreampDB == -10.5, "\(c.filtersInFile) \(c.dropped.count) \(String(describing: c.filePreampDB))")
                check("import \(label): measured preamp −10.53 from the realized filters", near(c.measuredPreampDB, -10.5308, 0.001), "\(c.measuredPreampDB)")
                check("import \(label): band 6 is +10 dB at 5 kHz, Q 3", b.frequency == 5_000 && b.gain == 10 && b.q == 3 && b.isEnabled)
                check("import \(label): name from the file", c.suggestedName == "Apple AirPods Max 2 Filters", c.suggestedName)
            case .failure(let f):
                check("import \(label): parses", false, "\(f)")
            }
        }
        verify("UTF-8 CRLF", utf8)
        var le = Data([0xFF, 0xFE]); le.append(text.data(using: .utf16LittleEndian)!)
        verify("UTF-16LE with BOM", le)
        var be = Data([0xFE, 0xFF]); be.append(text.data(using: .utf16BigEndian)!)
        verify("UTF-16BE with BOM", be)
        // Binary that merely starts like a BOM is still refused as binary.
        if case .failure(.unreadable) = AutoEQImport.parse(data: Data([0xFF, 0xFE, 0x00, 0xD8, 0x00, 0x00]), sourceName: "x", fileName: nil) {
            check("import: invalid UTF-16 after a BOM → unreadable (binary)", true)
        } else { check("import: invalid UTF-16 after a BOM → unreadable (binary)", false) }
        // Final-review follow-up: the preview must count what Apply applies — a pasted
        // single-line list used to show "1 filter" while 2 were applied.
        let oneLine = "Filter 1: ON PK Fc 100 Hz Gain -3.0 dB Q 1.00 Filter 2: ON PK Fc 2000 Hz Gain 2.0 dB Q 2.00"
        if case .success(let c) = AutoEQImport.parse(text: oneLine, sourceName: "paste", fileName: nil) {
            let applied = c.layer.bands.filter { $0.isEnabled }.count
            check("import: single-line paste of 2 filters → preview says 2 and 2 are applied, none dropped",
                  c.filtersInFile == 2 && applied == 2 && c.dropped.isEmpty, "\(c.filtersInFile) \(applied) \(c.dropped.count)")
        } else { check("import: single-line paste of 2 filters parses", false) }
    }

    // Replaces "builtin keys are stable across launches", which compared two stores in ONE process.
    static func presetKeysAreNames() {
        let suite = scratchSuite("presetkeys")
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        defer { d.removePersistentDomain(forName: suite) }
        let s = PresetStore(defaults: d, persist: false)
        check("presets: built-in keys are \"builtin:<name>\" (stable across launches)",
              s.builtins(.tuning).allSatisfy { $0.key.rawValue == "builtin:" + $0.name }
                && s.builtins(.correction).allSatisfy { $0.key.rawValue == "builtin:" + $0.name })
        // A key persisted by an earlier launch, as JSON text, still resolves.
        let name = s.builtins(.tuning).last?.name ?? ""
        let json = try? JSONEncoder().encode(["key": "builtin:" + name])
        let decoded = json.flatMap { try? JSONDecoder().decode([String: PresetKey].self, from: $0) }?["key"]
        check("presets: a persisted \"builtin:…\" key resolves to its preset", s.entry(decoded, .tuning)?.name == name && !name.isEmpty)
    }

    // An edited bound Correction survives the nil → same-device reports of launch, Off→On and Try Again.
    static func boundCorrectionKeepsEdits() {
        let suite = scratchSuite("binding")
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        defer { d.removePersistentDomain(forName: suite) }
        let model = AppModel(engine: StandInEngine(), defaults: d, mode: .preview)
        model.displayOverride = SnapshotRenderer.running()
        var p = ImportPreview(result: AutoEQImport.parse(text: SnapshotRenderer.sampleCorrection, sourceName: "f", fileName: "Foo ParametricEQ.txt"))
        p.bindToCurrentOutput = true
        model.applyImport(p)
        let fooKey = model.correctionKey
        model.loadPreset(model.presets.builtins(.correction)[0], .correction)
        model.outputDidChange(SnapshotRenderer.airpods)
        check("binding: flat → bound device loads its Correction", model.correctionKey == fooKey && !model.dual.target.isFlat)

        model.updateBand(5, layer: .target) { $0.gain = -7 }
        let edited = model.dual.target
        model.toast = nil
        model.outputDidChange(nil)                         // teardown (Off, error)
        model.outputDidChange(SnapshotRenderer.airpods)    // … and the same device again
        check("binding: an edited bound Correction is KEPT when its device is reported again",
              model.dual.target == edited && model.toast == nil && model.isEdited(.correction))

        var l = EQLayerState.flat
        l.bands[0] = EQBand(frequency: 200, gain: 2, q: 1)
        let spk = model.presets.add(.correction, name: "Speakers EQ", layer: l)
        model.presets.bind(deviceUID: SnapshotRenderer.speakers.uid, deviceName: SnapshotRenderer.speakers.name, to: spk.key)
        model.outputDidChange(SnapshotRenderer.speakers)
        check("binding: a device bound to ANOTHER Correction still loads it",
              model.correctionKey == spk.key && LayerCompare.sameSound(model.dual.target, l) && model.toast != nil)
    }

    // Inspector commits carry their own layer (stale field after ⌘1 / ⌘2).
    static func inspectorCommitsTargetTheirLayer() {
        let suite = scratchSuite("layers")
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        defer { d.removePersistentDomain(forName: suite) }
        let model = AppModel(engine: StandInEngine(), defaults: d, mode: .preview)
        model.setPreamp(-10.5, layer: .target)
        model.selectLayer(.target)                          // ⌘1 while the Tuning preamp field had focus
        model.commitPreamp(0, layer: .fineTune)             // that field's late commit
        check("inspector: a preamp commit lands on ITS layer after a layer switch",
              model.dual.target.preamp == -10.5 && model.dual.fineTune.preamp == 0)
        let targetBand = model.dual.target.bands[2]
        model.commitBandField(2, layer: .fineTune, name: "Move Band 3") { $0.frequency = 777 }   // not a default frequency
        check("inspector: a band commit lands on ITS layer after a layer switch",
              model.dual.fineTune.bands[2].frequency == 777 && model.dual.target.bands[2] == targetBand)
        model.commitBandField(2, name: "Move Band 3") { $0.gain = 1.5 }
        check("inspector: no layer given → the edited layer (old callers unchanged)", model.dual.target.bands[2].gain == 1.5)
    }

    // Settings renames by key: no preset load, no sound change.
    static func settingsRenameByKey() {
        let suite = scratchSuite("rename")
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        defer { d.removePersistentDomain(forName: suite) }
        let model = AppModel(engine: StandInEngine(), defaults: d, mode: .preview)
        var la = EQLayerState.flat; la.bands[1].gain = 3
        var lb = EQLayerState.flat; lb.bands[1].gain = -3
        let a = model.presets.add(.correction, name: "Review A", layer: la)
        let b = model.presets.add(.correction, name: "Review B", layer: lb)
        model.loadPreset(a, .correction)
        model.requestSaveAs(.tuning)                        // a main-window prompt is open meanwhile
        let mainPrompt = model.namePrompt
        let before = model.editSnapshot
        model.completeNamePrompt(NamePrompt(kind: .correction, purpose: .rename, name: "Review B renamed", key: b.key))
        check("settings: rename by key renames THAT preset", model.presets.entry(b.key, .correction)?.name == "Review B renamed"
              && model.presets.entry(a.key, .correction)?.name == "Review A")
        check("settings: … without loading it (sound and selection unchanged)", model.editSnapshot == before)
        check("settings: … and leaves the main window's open prompt alone", mainPrompt != nil && model.namePrompt?.id == mainPrompt?.id)
        model.completeNamePrompt(NamePrompt(kind: .correction, purpose: .rename, name: "Review A2"))
        check("rename without a key still renames the selected preset", model.presets.entry(a.key, .correction)?.name == "Review A2")
    }

    // The Limiting chip's fix follows what the limiter did, not only the EQ curve.
    static func limiterPreampFix() {
        var t = StatusChipTracker()
        var m = ChainMeters()
        for (db, at) in [(0.4, 0.0), (2.3, 0.2), (1.0, 0.4)] {
            m.limiterReductionDB = db
            t.observe(meters: m, underruns: 0, protectionOn: true, now: at)
        }
        check("chips: a Limiting episode remembers its largest reduction", t.overDB(now: 0.5) == 2.3 && t.chip(now: 0.5) == .limiting)
        check("chips: no over amount once the chip is gone", t.overDB(now: 3) == 0)
        m.limiterReductionDB = 0.6
        t.observe(meters: m, underruns: 0, protectionOn: true, now: 5)
        check("chips: a new episode starts from its own reduction", t.overDB(now: 5) == 0.6)
        var c = StatusChipTracker()
        var cm = ChainMeters()
        cm.outputPeakDB = 1.7
        c.observe(meters: cm, underruns: 0, protectionOn: false, now: 0)
        check("chips: protection off → the clipped peak above 0 dBFS", near(c.overDB(now: 0), 1.7, 1e-12) && c.chip(now: 0) == .clipping)

        let suite = scratchSuite("fix")
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        defer { d.removePersistentDomain(forName: suite) }
        let model = AppModel(engine: StandInEngine(), defaults: d, mode: .preview)
        check("fix: flat EQ and nothing over → no button", model.preampFixDB(overDB: 0) == nil && model.headroomFixPreampDB == nil)
        check("fix: flat EQ but the limiter took 1.2 dB → Lower Preamp to −1.5 dB",
              model.preampFixDB(overDB: 1.2) == -1.5, "\(String(describing: model.preampFixDB(overDB: 1.2)))")
        model.setPreamp(-19.8, layer: .fineTune)
        check("fix: clamped to −20 dB", model.preampFixDB(overDB: 3) == -20)
        model.setPreamp(-20, layer: .fineTune)
        check("fix: no room below −20 dB → no button", model.preampFixDB(overDB: 1.2) == nil)
        model.setPreamp(0, layer: .fineTune)
        model.updateBand(4, layer: .fineTune) { $0.gain = 6; $0.q = 1 }
        let peak = model.totalPeakDB
        let x = model.preampFixDB(overDB: 1) ?? 0
        check("fix: the EQ peak still counts when it is the larger one", x <= -peak && x > -peak - 0.5 - 1e-9, "\(x) vs peak \(peak)")
        model.applyPreampFix(to: -1.5)
        check("fix: applies exactly the value on the button", model.dual.fineTune.preamp == -1.5)
    }

    // Hold-B can't stick in bypass.
    static func holdBCompare() {
        let suite = scratchSuite("holdb")
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        defer { d.removePersistentDomain(forName: suite) }
        let model = AppModel(engine: StandInEngine(), defaults: d, mode: .preview)
        check("hold-B: an eligible press holds Compare",
              model.handleCompareKey(isDown: true, isRepeat: false, eligible: true) && model.compareHeld)
        _ = model.handleCompareKey(isDown: true, isRepeat: true, eligible: true)
        check("hold-B: releasing B with ⌘ held (ineligible key-up) still ends the hold",
              model.handleCompareKey(isDown: false, isRepeat: false, eligible: false) && !model.compareHeld)
        _ = model.handleCompareKey(isDown: true, isRepeat: false, eligible: true)
        model.appDidResignActive()
        check("hold-B: ⌘-Tab away (app resigns active) ends the hold", !model.compareHeld)
        check("hold-B: a stray B key-up after that passes through",
              !model.handleCompareKey(isDown: false, isRepeat: false, eligible: false))
        check("hold-B: B typed into a text field passes through",
              !model.handleCompareKey(isDown: true, isRepeat: false, eligible: false) && !model.compareHeld)
        model.compareHeld = true                            // held with the mouse on Compare
        _ = model.handleCompareKey(isDown: false, isRepeat: false, eligible: false)
        check("hold-B: an unrelated B key-up doesn't end a mouse hold", model.compareHeld)
        model.compareHeld = false
    }

    // "Turn on when EQtargets opens" decides launch power (the last toggle no longer overrides an unchecked box).
    static func launchPowerFollowsCheckbox() {
        let suite = scratchSuite("launch")
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        for (turnOn, lastPowered) in [(false, true), (false, false), (true, false), (true, true)] {
            d.removePersistentDomain(forName: suite)
            d.set(turnOn, forKey: AppModel.Keys.turnOnAtLaunch)
            d.set(lastPowered, forKey: AppModel.Keys.powered)
            let engine = StandInEngine()
            AppModel(engine: engine, defaults: d, mode: .live).start()
            check("launch: box \(turnOn ? "checked" : "unchecked"), quit while \(lastPowered ? "On" : "Off") → opens \(turnOn ? "On" : "Off")",
                  engine.poweredCalls == [turnOn], "\(engine.poweredCalls)")
        }
    }

    // Status-only views don't depend on the 2 Hz engine stats.
    static func statusReadersSkipStats() {
        let suite = scratchSuite("observe")
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        defer { d.removePersistentDomain(forName: suite) }
        let engine = StandInEngine()
        engine.status = .running
        engine.isPowered = true
        let model = AppModel(engine: engine, defaults: d, mode: .preview)
        check("status readers agree with display", model.displayStatus == model.display.status
              && model.displayIsPowered == model.display.isPowered && model.displayIsProcessing == model.display.isProcessing
              && model.currentOutput == model.display.currentOutput)
        let lean = Flag()
        withObservationTracking {
            _ = model.displayStatus; _ = model.displayIsPowered; _ = model.displayIsProcessing; _ = model.currentOutput
        } onChange: { lean.fired = true }
        var st = EngineStats()
        st.cpuLoad = 0.42
        st.latencyMs = 21
        engine.stats = st
        check("perf: status/power readers are NOT invalidated by a stats tick", !lean.fired)
        engine.status = .idle
        check("perf: … but are by a status change", lean.fired)
        let full = Flag()
        withObservationTracking { _ = model.display } onChange: { full.fired = true }
        engine.stats = EngineStats()
        check("perf control: `display` IS invalidated by a stats tick", full.fired)
        model.displayOverride = EngineDisplay(status: .driverMissing, isPowered: false, outputDevices: [], currentOutput: nil, stats: EngineStats())
        check("status readers honour the snapshot override",
              model.displayStatus == .driverMissing && !model.displayIsPowered && !model.displayIsProcessing && model.currentOutput == nil)
    }

    // One instance at a time, but a copy that is still quitting (pkill + relaunch) doesn't block the launch.
    static func singleInstanceDecision() {
        check("single instance: nothing else running → launch",
              SingleInstance.survivor(of: [], ownPID: 10, grace: 1, isAlive: { _ in true }, sleep: { _ in }) == nil)
        check("single instance: only this process → launch",
              SingleInstance.survivor(of: [10], ownPID: 10, grace: 1, isAlive: { _ in true }, sleep: { _ in }) == nil)
        var slept = 0.0
        let other = SingleInstance.survivor(of: [10, 42], ownPID: 10, grace: 1.5, isAlive: { _ in true }, sleep: { slept += $0 })
        check("single instance: another live copy → defer to it, after the quit grace",
              other == 42 && slept >= 1.5 - 1e-9 && slept < 1.6, "\(String(describing: other)) after \(slept) s")
        var polls = 0
        check("single instance: a copy that exits within the grace → launch",
              SingleInstance.survivor(of: [42], ownPID: 10, grace: 1.5, isAlive: { _ in polls += 1; return polls < 4 }, sleep: { _ in }) == nil)
        check("single instance: grace leaves time for a quit to hand the output back", SingleInstance.quitGrace >= 1)
    }

    static func spokenFrequencies() {
        check("VoiceOver: 5 kHz reads \"kilohertz\", not \"khertz\"", EQFormat.spokenFrequency(5_000) == "5.00\(EQFormat.nbsp)kilohertz",
              EQFormat.spokenFrequency(5_000))
        check("VoiceOver: 125 Hz reads \"hertz\"", EQFormat.spokenFrequency(125) == "125\(EQFormat.nbsp)hertz")
    }
}
// END review-fix checks
#endif
