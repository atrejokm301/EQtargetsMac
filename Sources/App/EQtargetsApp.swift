//
//  EQtargetsApp.swift
//  EQtargets (macOS)
//
//  Entry point. Three launch modes:
//    • normal                         → the SwiftUI app below (one instance only)
//    • --render-snapshots <dir>       → render QA snapshots offscreen, exit(0)
//                                       (never constructs the real engine)
//    • --ui-selftest (DEBUG builds)   → run the UI-logic self-test, exit(code)
//  The two offline modes run even while the app is open; they never route.
//
//  Scenes: one main Window (single document utility — no ⌘N, one UndoManager,
//  one set of meter consumers), the onboarding Window, a `.window`-style
//  MenuBarExtra and Settings. Closing the last window keeps the app alive in
//  the menu bar; quitting hands macOS its output back via `engine.shutdown()`.
//

import SwiftUI
import AppKit

@main
enum EQtargetsMain {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-snapshots") {
            let dir = i + 1 < args.count ? args[i + 1] : "snapshots"
            MainActor.assumeIsolated { SnapshotRenderer.run(outputDirectory: dir) }
        }
        #if DEBUG
        if args.contains("--ui-selftest") {
            MainActor.assumeIsolated { UISelfTest.runAndExit() }
        }
        #endif
        // Before `EQtargetsApp.main()`: `AppModel.shared` is lazy, so no engine
        // exists yet and nothing has been routed.
        if let other = SingleInstance.otherInstance(
            bundleID: Bundle.main.bundleIdentifier ?? "com.eqtargets.app", ownPID: getpid()) {
            let path = other.bundleURL?.path ?? "?"
            FileHandle.standardError.write(Data("EQtargets is already running (pid \(other.processIdentifier), \(path)); bringing it forward. Quit it first to run this copy.\n".utf8))
            other.activate()
            exit(0)
        }
        EQtargetsApp.main()
    }
}

/// One EQtargets at a time. A second copy (another build folder,
/// /Applications, an Xcode run — LaunchServices starts those side by side)
/// would read the same settings, power on and run its OWN output unit on the
/// same device: two full renders of the system mix summed into it (+6 dB into
/// the limiter's ceiling, or comb-filtered when the two readers' phases
/// differ), and either one's quit would hand macOS's output back under the other.
enum SingleInstance {
    /// Kevin's relaunch habit is `pkill EQtargets` then open: give a copy that
    /// is still quitting (handing the output back) this long before deciding.
    static let quitGrace: TimeInterval = 1.5

    /// Another running EQtargets that stays alive through `quitGrace`, or nil.
    static func otherInstance(bundleID: String, ownPID: pid_t) -> NSRunningApplication? {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        let pid = survivor(of: others.map(\.processIdentifier), ownPID: ownPID, grace: quitGrace,
                           isAlive: { kill($0, 0) == 0 || errno == EPERM },
                           sleep: { usleep(useconds_t($0 * 1_000_000)) })
        return pid.flatMap { p in others.first { $0.processIdentifier == p } }
    }

    /// Pure decision (self-tested): the first pid other than ours that is still
    /// alive after waiting up to `grace` for it to exit; nil if none is left.
    static func survivor(of pids: [pid_t], ownPID: pid_t, grace: TimeInterval, step: TimeInterval = 0.05,
                         isAlive: (pid_t) -> Bool, sleep: (TimeInterval) -> Void) -> pid_t? {
        let others = pids.filter { $0 != ownPID && $0 > 0 }
        guard !others.isEmpty else { return nil }
        var waited: TimeInterval = 0
        while true {
            let alive = others.filter(isAlive)
            if alive.isEmpty { return nil }
            if waited >= grace { return alive.first }
            sleep(step)
            waited += step
        }
    }
}

extension AppModel {
    /// The live model: real engine, standard defaults.
    static let shared = AppModel(engine: EngineController(), defaults: .standard, mode: .live)
}

struct EQtargetsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("EQtargets", id: "main") {
            MainView()
                .environment(model)
        }
        .defaultSize(width: 1180, height: 740)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { AppCommands(model: model) }

        Window("Welcome to EQtargets", id: "onboarding") {
            OnboardingView()
                .environment(model)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        MenuBarExtra(isInserted: Binding(get: { model.showMenuBarExtra }, set: { model.showMenuBarExtra = $0 })) {
            MenuBarPopover()
                .environment(model)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        TerminationSignals.install { _ in NSApp.terminate(nil) }
        AppModel.shared.start()
    }

    /// Synchronous: restores macOS's default output and stops processing.
    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.shutdown()
    }

    /// The menu bar extra keeps working with every window closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// SIGTERM / SIGINT / SIGHUP (`pkill EQtargets`, Ctrl-C in a terminal, a
/// script) would otherwise end the process WITHOUT `applicationWillTerminate`,
/// leaving macOS's default output on EQtargets Audio with nobody playing it —
/// a silent Mac until EQtargets is launched again. They are turned into a
/// normal quit so `engine.shutdown()` hands the output back. (SIGKILL cannot
/// be caught; the engine's launch recovery covers that on the next launch.)
@MainActor
enum TerminationSignals {
    private static var sources: [DispatchSourceSignal] = []

    static func install(_ signals: [Int32] = [SIGTERM, SIGINT, SIGHUP],
                        handler: @escaping @MainActor (Int32) -> Void) {
        for sig in signals {
            signal(sig, SIG_IGN)            // the dispatch source replaces the default action (exit)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler { MainActor.assumeIsolated { handler(sig) } }
            s.resume()
            sources.append(s)
        }
    }
}

// MARK: - Menus and shortcuts (DESIGN §6.9)

struct AppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    /// A text field is being edited → standard editing keys belong to it.
    @MainActor private var textFocused: Bool { NSApp.keyWindow?.firstResponder is NSText }

    @MainActor private func send(_ action: Selector) {
        NSApp.sendAction(action, to: nil, from: nil)
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Import AutoEQ File\u{2026}") {
                openWindow(id: "main")
                model.showFileImporter = true
            }
            .keyboardShortcut("o")
            Button("Paste AutoEQ from Clipboard") {
                openWindow(id: "main")
                model.pasteAutoEQ()
            }
            Divider()
            Button("Save Changes") { model.saveChanges(PresetKind(model.editingLayer)) }
                .keyboardShortcut("s")
            Button("Save As\u{2026}") { model.requestSaveAs(PresetKind(model.editingLayer)) }
                .keyboardShortcut("s", modifiers: [.command, .shift])
        }

        // ⌘V is shared: a focused text field gets a normal paste; anywhere else
        // it previews AutoEQ filters from the clipboard (§6.5).
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { send(#selector(NSText.cut(_:))) }.keyboardShortcut("x")
            Button("Copy") { send(#selector(NSText.copy(_:))) }.keyboardShortcut("c")
            Button("Paste") {
                if textFocused { send(#selector(NSText.paste(_:))) } else { model.pasteAutoEQ() }
            }
            .keyboardShortcut("v")
            Button("Select All") { send(#selector(NSText.selectAll(_:))) }.keyboardShortcut("a")
        }

        CommandGroup(after: .undoRedo) {
            Divider()
            Button("Reset Band") {
                if textFocused { send(#selector(NSResponder.deleteToBeginningOfLine(_:))) } else { model.resetBandGain() }
            }
            .keyboardShortcut(.delete, modifiers: .command)
            Button("Reset Your Tuning") { model.resetTuning() }
                .keyboardShortcut(.delete, modifiers: [.command, .option])
        }

        CommandMenu("EQ") {
            // displayIs… / displayStatus, not `display`: menus rebuilt from the
            // 2 Hz engine stats otherwise.
            Button(model.displayIsPowered ? "Turn EQtargets Off" : "Turn EQtargets On") {
                model.setPowered(!model.displayIsPowered)
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
            .disabled(model.displayStatus == .driverMissing)
            Button("Compare (Lock)") { model.toggleCompareLatch() }
                .keyboardShortcut("b")
                .disabled(!model.displayIsProcessing)
            Divider()
            Button("Edit Headphone Correction") { model.selectLayer(.target) }.keyboardShortcut("1")
            Button("Edit Your Tuning") { model.selectLayer(.fineTune) }.keyboardShortcut("2")
            Divider()
            Button("Previous Band") { model.selectAdjacentBand(-1) }.keyboardShortcut("[")
            Button("Next Band") { model.selectAdjacentBand(1) }.keyboardShortcut("]")
            Divider()
            Menu("Bass Style") {
                ForEach(Array(BassStyle.allCases.enumerated()), id: \.offset) { i, style in
                    Button(style.compactTitle) { model.selectBassStyle(style) }
                        .keyboardShortcut(KeyEquivalent(Character("\(i)")), modifiers: [.command, .control])
                }
            }
        }

        CommandGroup(after: .sidebar) {
            Button("Show / Hide Bass Style") { model.toggleBassPanel() }
                .keyboardShortcut("b", modifiers: [.command, .option])
            Menu("Graph Scale") {
                ForEach(GraphScale.allCases) { s in
                    Button(s.title) { model.graphScale = s }
                }
            }
            Button(model.showCorrectionCurve ? "Hide Correction Curve" : "Show Correction Curve") {
                model.showCorrectionCurve.toggle()
            }
            Button(model.showTuningCurve ? "Hide Your Tuning Curve" : "Show Your Tuning Curve") {
                model.showTuningCurve.toggle()
            }
            Divider()
        }

        CommandGroup(replacing: .help) {
            Link("AutoEQ Website", destination: URL(string: "https://autoeq.app")!)
        }
    }
}
