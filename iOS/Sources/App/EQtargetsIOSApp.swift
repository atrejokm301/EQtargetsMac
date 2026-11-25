//
//  EQtargetsIOSApp.swift
//  EQtargets (iOS)
//
//  One engine, one model. The engine starts the first time the app really opens,
//  after the first frame, because activating the audio session can take a while on
//  the main thread and must not hold up launch.
//

import SwiftUI
#if EQT_HAS_EXTENSION
import WidgetKit
#endif

@main
struct EQtargetsIOSApp: App {
    @State private var model: AppModel
    #if DEBUG && !EQT_HAS_EXTENSION
    /// Held for the life of the app. It plays the extension's role in `--demo`.
    @State private var demoFeeder: DemoFeeder?
    #endif

    init() {
        // Before the first unlock after a restart the saved EQ can't be read, and a
        // model built now would later save an empty one over it. iOS can only start
        // the app in the background then, so leaving is invisible.
        if LinkKey.settingsAreLocked() { exit(0) }
        #if DEBUG
        DebugLaunch.prepareDefaults()
        #endif
        let model = AppModel(engine: Self.makeEngine(), defaults: .standard, mode: .live)
        #if EQT_HAS_EXTENSION
        Self.connectControls(to: model)
        #endif
        #if DEBUG
        DebugLaunch.apply(to: model)
        #endif
        _model = State(initialValue: model)
        #if DEBUG && !EQT_HAS_EXTENSION
        _demoFeeder = State(initialValue: DemoFeeder.isRequested ? DemoFeeder(port: Self.linkPort) : nil)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model) {
                model.start()
                #if DEBUG && !EQT_HAS_EXTENSION
                demoFeeder?.start()   // after the engine is powered and listening
                #endif
            }
        }
    }

    private static var linkPort: UInt16 {
        #if DEBUG
        DebugLaunch.linkPort ?? UInt16(EQT_LINK_PORT)
        #else
        UInt16(EQT_LINK_PORT)
        #endif
    }

    #if EQT_HAS_EXTENSION
    /// Here and not in a view: iOS can launch the app just to run a tile's action,
    /// and then no window ever appears.
    @MainActor
    private static func connectControls(to model: AppModel) {
        EQControlBridge.handler = model
        let store = EQControlStore()
        model.controlOutput = EQControlOutput(
            save: { store.save($0) },
            redraw: {
                ControlCenter.shared.reloadControls(ofKind: EQControlID.powerKind)
                ControlCenter.shared.reloadControls(ofKind: EQControlID.bassKind)
            })
    }
    #endif

    @MainActor
    private static func makeEngine() -> any EngineDriving {
        #if DEBUG
        if DebugLaunch.usesStandIn { return StandInEngine() }
        #endif
        return LinkEngine(port: linkPort)
    }
}

extension AppModel: EQControlHandling {}

/// Owns the scene-phase wiring, which needs a view's environment.
private struct RootView: View {
    let model: AppModel
    let onFirstAppear: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var didStart = false

    var body: some View {
        MainView()
            .environment(model)
            .environment(\.sceneIsActive, scenePhase == .active)
            .onChange(of: scenePhase, initial: true) { _, phase in
                model.sceneDidChange(isActive: phase == .active, isBackground: phase == .background)
                // Not while iOS has connected this scene in the background for a
                // tile: "Turn on when EQtargets opens" means really opening it.
                guard phase != .background, !didStart else { return }
                didStart = true
                Task {
                    // Activating the audio session blocks the main thread, so the
                    // first frame has to reach the screen before it starts.
                    try? await Task.sleep(for: .milliseconds(150))
                    onFirstAppear()
                }
            }
    }
}
