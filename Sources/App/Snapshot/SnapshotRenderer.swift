//
//  SnapshotRenderer.swift
//  EQtargets (macOS)
//
//  `EQtargets --render-snapshots <dir>` renders representative states of every
//  surface in light AND dark appearance to PNGs, then exits. Used for visual QA
//  without installing the driver or touching the audio system:
//  • the real `EngineController` is never constructed — a `StandInEngine`
//    stands in, and engine-derived values (status, device, meter levels) are
//    injected through `EngineDisplay` / `MeterHub.seed`;
//  • nothing is shown on screen: windows are never ordered in;
//  • rendering uses NSHostingView + `cacheDisplay`, not `ImageRenderer`,
//    because ImageRenderer can't draw AppKit-backed controls (menus, fields,
//    tables, sliders, toggles) — and those are most of the UI.
//
//  The sample filter values below are illustrative, not a real measurement.
//

import SwiftUI
import AppKit
import CoreAudio

@MainActor
enum SnapshotRenderer {

    // MARK: Sample data

    static let sampleCorrection = """
    Preamp: -6.2 dB
    Filter 1: ON LSC Fc 105 Hz Gain 6.5 dB Q 0.70
    Filter 2: ON PK Fc 161 Hz Gain -2.9 dB Q 0.44
    Filter 3: ON PK Fc 1176 Hz Gain -1.4 dB Q 1.36
    Filter 4: ON PK Fc 2093 Hz Gain 2.4 dB Q 2.34
    Filter 5: ON PK Fc 3213 Hz Gain -1.5 dB Q 3.47
    Filter 6: ON PK Fc 5328 Hz Gain -2.8 dB Q 3.62
    Filter 7: ON PK Fc 7186 Hz Gain 2.6 dB Q 2.20
    Filter 8: ON PK Fc 9112 Hz Gain -3.7 dB Q 2.24
    Filter 9: ON PK Fc 13145 Hz Gain -1.2 dB Q 1.00
    Filter 10: ON HSC Fc 10000 Hz Gain -3.1 dB Q 0.70
    """

    /// 12 filters → the preview must say two were dropped.
    static let sampleTwelve = sampleCorrection + """

    Filter 11: ON PK Fc 6100 Hz Gain 0.3 dB Q 4.00
    Filter 12: ON PK Fc 14000 Hz Gain -0.2 dB Q 2.00
    """

    nonisolated static let airpods = OutputDevice(objectID: 81, uid: "sample.airpods", name: "AirPods Pro",
                                      transport: .bluetooth, nominalSampleRate: 48_000, hasHardwareVolume: true)
    nonisolated static let speakers = OutputDevice(objectID: 82, uid: "sample.builtin", name: "MacBook Pro Speakers",
                                       transport: .builtIn, nominalSampleRate: 48_000, hasHardwareVolume: true)
    nonisolated static let dac = OutputDevice(objectID: 83, uid: "sample.dac", name: "Schiit Modi+",
                                  transport: .usb, nominalSampleRate: 96_000, hasHardwareVolume: false)

    static func running(on device: OutputDevice = airpods) -> EngineDisplay {
        var stats = EngineStats()
        stats.sampleRate = 48_000
        stats.latencyMs = 21.3
        stats.outputBufferFrames = 512
        stats.cpuLoad = 0.02
        return EngineDisplay(status: .running, isPowered: true, outputDevices: [airpods, speakers, dac],
                             currentOutput: device, stats: stats)
    }

    // MARK: Scenarios

    struct Scenario {
        enum Surface { case mainWindow(CGSize), view(width: CGFloat, height: CGFloat?) }
        let name: String
        let surface: Surface
        let configure: (AppModel) -> Void
        let content: (AppModel) -> AnyView
    }

    static func makeModel() -> AppModel {
        let suite = "com.eqtargets.app.snapshots"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let model = AppModel(engine: StandInEngine(), defaults: defaults, mode: .preview)
        model.meters.frozen = true
        return model
    }

    static func loadSampleCorrection(_ m: AppModel, name: String = "Sample HD 600") {
        guard let layer = try? AutoEQParser.parse(text: sampleCorrection) else { return }
        let e = m.presets.add(.correction, name: name, layer: layer)
        m.applyCorrection(e, keepEditingLayer: false)
        m.presets.bind(deviceUID: airpods.uid, deviceName: airpods.name, to: e.key)
    }

    static func tweakTuning(_ m: AppModel) {
        m.selectLayer(.fineTune)
        m.updateBand(1) { $0.gain = 3.0; $0.q = 0.9 }
        m.updateBand(2) { $0.gain = 2.0; $0.frequency = 110; $0.q = 1.2 }
        m.updateBand(7) { $0.gain = -2.0; $0.frequency = 3_500; $0.q = 2.0 }
        m.updateBand(9) { $0.gain = 1.5; $0.filterType = .highShelf; $0.frequency = 10_000; $0.q = 0.71 }
        m.setPreamp(-2.5, layer: .fineTune)
        m.tuningKey = nil
        m.selectBand(2)
    }

    static var scenarios: [Scenario] {
        let main: (AppModel) -> AnyView = { AnyView(MainView().environment($0)) }
        return [
            Scenario(name: "01-main-punch", surface: .mainWindow(CGSize(width: 1180, height: 740)), configure: { m in
                m.displayOverride = running()
                loadSampleCorrection(m)
                tweakTuning(m)
                m.bass.selectStyle(.transientPunch)
                m.bass.punchSustain = 0.35
                m.meters.seed(boostDB: 3.2, trimDB: 0.6)
            }, content: main),
            Scenario(name: "02-main-rumble-correction", surface: .mainWindow(CGSize(width: 1180, height: 740)), configure: { m in
                m.displayOverride = running()
                loadSampleCorrection(m)
                tweakTuning(m)
                m.selectLayer(.target)
                m.selectBand(3)
                m.bass.selectStyle(.sustainRumble)
                m.bass.rumbleSoften = 0.4
                m.meters.seed(boostDB: 4.6, trimDB: 1.1, chip: .limiting)
            }, content: main),
            Scenario(name: "03-main-compact-punch", surface: .mainWindow(CGSize(width: 960, height: 640)), configure: { m in
                m.displayOverride = running(on: speakers)
                loadSampleCorrection(m)
                tweakTuning(m)
                m.bass.selectStyle(.transientPunch)
                m.meters.seed(boostDB: 2.4, trimDB: 0)
                m.isCompactWidth = true
            }, content: main),
            Scenario(name: "04-main-driver-missing", surface: .mainWindow(CGSize(width: 1180, height: 740)), configure: { m in
                m.displayOverride = EngineDisplay(status: .driverMissing, isPowered: false, outputDevices: [],
                                                  currentOutput: nil, stats: EngineStats())
            }, content: main),
            Scenario(name: "05-main-compare", surface: .mainWindow(CGSize(width: 1180, height: 740)), configure: { m in
                m.displayOverride = running()
                loadSampleCorrection(m)
                tweakTuning(m)
                m.compareLatched = true
                m.bassPanelRegular = false
            }, content: main),
            Scenario(name: "14-bass-panel-rumble", surface: .view(width: 300, height: nil), configure: { m in
                m.displayOverride = running()
                m.bass.selectStyle(.sustainRumble)
                m.bass.rumbleSoften = 0.4
                m.bass.cutoff = 70        // not the recommendation → shows the ↺ 55 Hz restore
                m.meters.seed(boostDB: 4.6, trimDB: 1.1)
            }, content: { m in AnyView(BassStylePanel(scrolls: false).environment(m).background(Palette.canvas)) }),
            Scenario(name: "15-bass-panel-idle-clean", surface: .view(width: 300, height: nil), configure: { m in
                m.displayOverride = EngineDisplay(status: .idle, isPowered: true, outputDevices: [airpods], currentOutput: airpods, stats: EngineStats())
                m.bass.selectStyle(.naturalClean)
            }, content: { m in AnyView(BassStylePanel(scrolls: false).environment(m).background(Palette.canvas)) }),
            Scenario(name: "16-bass-panel-punch-idle", surface: .view(width: 300, height: nil), configure: { m in
                m.displayOverride = EngineDisplay(status: .idle, isPowered: true, outputDevices: [airpods], currentOutput: airpods, stats: EngineStats())
                m.bass.selectStyle(.transientPunch)
            }, content: { m in AnyView(BassStylePanel(scrolls: false).environment(m).background(Palette.canvas)) }),
            Scenario(name: "06-import-preview", surface: .view(width: 520, height: nil), configure: { m in
                m.displayOverride = running()
            }, content: { m in
                let preview = ImportPreview(result: AutoEQImport.parse(text: sampleTwelve, sourceName: "Sample HD 600 ParametricEQ.txt",
                                                                       fileName: "Sample HD 600 ParametricEQ.txt"))
                return AnyView(ImportPreviewSheet(preview: preview).environment(m).background(Palette.canvas))
            }),
            Scenario(name: "07-import-error", surface: .view(width: 520, height: nil), configure: { m in
                m.displayOverride = running()
            }, content: { m in
                let preview = ImportPreview(result: AutoEQImport.parse(text: "GraphicEQ: 20 -3.1; 21 -3.0", sourceName: "GraphicEQ.txt", fileName: "GraphicEQ.txt"))
                return AnyView(ImportPreviewSheet(preview: preview).environment(m).background(Palette.canvas))
            }),
            Scenario(name: "08-menu-popover", surface: .view(width: 360, height: nil), configure: { m in
                m.displayOverride = running()
                loadSampleCorrection(m)
                m.bass.selectStyle(.sustainRumble)
                m.meters.seed(boostDB: 3.8, trimDB: 0)
            }, content: { m in AnyView(MenuBarPopover().environment(m).background(Palette.canvas)) }),
            Scenario(name: "09-onboarding-welcome", surface: .view(width: 560, height: 460), configure: { m in
                m.displayOverride = EngineDisplay(status: .driverMissing, isPowered: false, outputDevices: [], currentOutput: nil, stats: EngineStats())
                m.onboardingStep = .welcome
            }, content: { m in AnyView(OnboardingView().environment(m).background(Palette.canvas)) }),
            Scenario(name: "10-onboarding-driver", surface: .view(width: 560, height: 460), configure: { m in
                m.displayOverride = EngineDisplay(status: .driverMissing, isPowered: false, outputDevices: [], currentOutput: nil, stats: EngineStats())
                m.onboardingStep = .driver
            }, content: { m in AnyView(OnboardingView().environment(m).background(Palette.canvas)) }),
            Scenario(name: "11-onboarding-failed", surface: .view(width: 560, height: 460), configure: { m in
                m.displayOverride = EngineDisplay(status: .driverMissing, isPowered: false, outputDevices: [], currentOutput: nil, stats: EngineStats())
                m.onboardingStep = .driver
                m.installState = .failed("The driver could not be copied to /Library/Audio/Plug-Ins/HAL (permission denied).")
            }, content: { m in AnyView(OnboardingView().environment(m).background(Palette.canvas)) }),
            Scenario(name: "12-settings-general", surface: .view(width: 560, height: nil), configure: { m in
                m.displayOverride = running()
            }, content: { m in AnyView(SettingsView().environment(m).background(Palette.canvas)) }),
            Scenario(name: "13-settings-driver", surface: .view(width: 560, height: nil), configure: { m in
                m.displayOverride = running()
            }, content: { m in AnyView(SettingsView(tab: .driver).environment(m).background(Palette.canvas)) }),
        ]
    }

    // MARK: Run

    static func run(outputDirectory: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let dir = URL(fileURLWithPath: outputDirectory, isDirectory: true).standardizedFileURL
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("snapshot: cannot create \(dir.path): \(error)\n".utf8))
            exit(2)
        }
        var written = 0, failed = 0
        // EQT_SNAPSHOT_ONLY=04 renders only scenarios whose name contains "04".
        let only = ProcessInfo.processInfo.environment["EQT_SNAPSHOT_ONLY"]
        for scenario in scenarios where only.map({ scenario.name.contains($0) }) ?? true {
            for dark in [false, true] {
                let file = dir.appendingPathComponent("\(scenario.name)-\(dark ? "dark" : "light").png")
                if let data = render(scenario, dark: dark) {
                    do { try data.write(to: file); written += 1; print("snapshot: wrote \(file.path)") }
                    catch { failed += 1; print("snapshot: FAILED writing \(file.path): \(error)") }
                } else {
                    failed += 1
                    print("snapshot: FAILED rendering \(scenario.name) (\(dark ? "dark" : "light"))")
                }
            }
        }
        UserDefaults.standard.removePersistentDomain(forName: "com.eqtargets.app.snapshots")
        print("snapshot: \(written) written, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }

    private static func render(_ scenario: Scenario, dark: Bool) -> Data? {
        let model = makeModel()
        scenario.configure(model)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = scenario.content(model)
            .environment(\.colorScheme, dark ? .dark : .light)

        switch scenario.surface {
        case .mainWindow(let size):
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.appearance = appearance
            window.toolbarStyle = .unified
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: root)
            host.sceneBridgingOptions = [.toolbars, .title]
            window.contentView = host
            window.setContentSize(size)
            settle(host)
            let frameView = window.contentView?.superview ?? host
            if ProcessInfo.processInfo.environment["EQT_SNAPSHOT_DUMP"] != nil { dump(frameView, 0) }
            defer { window.close() }
            // macOS 26+ hosts the inspector column inside an NSGlassEffectView,
            // whose portal layers `cacheDisplay` can't capture (the column comes
            // out transparent although its content is laid out — verified with
            // EQT_SNAPSHOT_DUMP). Capture the inspector's own hosting view and
            // composite it over a solid window-background fill, below the toolbar.
            let inspectors = find(in: frameView) { String(describing: type(of: $0)).contains("InspectorStyleContext") }
            return composite(frameView, overlays: inspectors, contentRect: window.contentLayoutRect, appearance: appearance) { size in
                // Opaque background: a non-opaque capture loses its alpha when
                // composited (transparent → black, 4% fills → solid).
                AnyView(BassStylePanel(scrolls: false).environment(model)
                    .frame(width: size.width, height: size.height, alignment: .top)
                    .background(Palette.canvas)
                    .environment(\.colorScheme, dark ? .dark : .light))
            }
        case .view(let width, let height):
            let host = NSHostingView(rootView: root.frame(width: width, height: height))
            host.appearance = appearance
            let fit = host.fittingSize
            host.frame = NSRect(x: 0, y: 0, width: width, height: height ?? max(fit.height, 1))
            // Offscreen windows give the view a backing scale (2× on Retina).
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = appearance
            window.isReleasedWhenClosed = false
            window.contentView = host
            settle(host)
            if ProcessInfo.processInfo.environment["EQT_SNAPSHOT_DUMP"] != nil { dump(host, 0) }
            defer { window.close() }
            return png(of: host)
        }
    }

    private static func dump(_ v: NSView, _ depth: Int) {
        guard depth < 14 else { return }
        print(String(repeating: "  ", count: depth) + "\(type(of: v)) \(v.frame.integral) hidden=\(v.isHidden) alpha=\(v.alphaValue) layer=\(v.wantsLayer)")
        for s in v.subviews { dump(s, depth + 1) }
    }

    /// Let SwiftUI finish layout, onAppear and geometry-change updates.
    private static func settle(_ view: NSView) {
        for _ in 0 ..< 4 {
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        }
    }

    private static func find(in v: NSView, _ match: (NSView) -> Bool) -> [NSView] {
        (match(v) ? [v] : []) + v.subviews.flatMap { find(in: $0, match) }
    }

    private static func composite(_ base: NSView, overlays: [NSView], contentRect: NSRect,
                                  appearance: NSAppearance?, stand: (CGSize) -> AnyView) -> Data? {
        let bounds = base.bounds
        guard let baseRep = base.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        base.cacheDisplay(in: bounds, to: baseRep)
        guard !overlays.isEmpty else { return baseRep.representation(using: .png, properties: [:]) }
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: baseRep.pixelsWide, pixelsHigh: baseRep.pixelsHigh,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: out) else { return nil }
        out.size = bounds.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        // A bitmap context's user space is in pixels; draw in points.
        ctx.cgContext.scaleBy(x: CGFloat(baseRep.pixelsWide) / bounds.width, y: CGFloat(baseRep.pixelsHigh) / bounds.height)
        baseRep.draw(in: bounds)
        for v in overlays where v.bounds.width > 0 && v.bounds.height > 0 {
            // The column's own pixels are unreachable; render the same panel
            // (same model, same appearance) standalone at the column's size.
            let r = v.convert(v.bounds, to: base).intersection(contentRect)
            guard r.width > 0, r.height > 0 else { continue }
            let host = NSHostingView(rootView: stand(r.size))
            host.appearance = appearance
            host.frame = NSRect(origin: .zero, size: r.size)
            let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.appearance = appearance
            w.isReleasedWhenClosed = false
            w.contentView = host
            settle(host)
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { w.close(); continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            w.close()
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: r).setClip()
            (appearance ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
                NSColor.windowBackgroundColor.setFill()
                r.fill()
            }
            rep.draw(in: r)
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.restoreGraphicsState()
        return out.representation(using: .png, properties: [:])
    }

    private static func png(of view: NSView) -> Data? {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
