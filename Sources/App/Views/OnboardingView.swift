//
//  OnboardingView.swift
//  EQtargets (macOS)
//
//  First run / "Install Driver…" (DESIGN §5.6). 560 × 460, not resizable.
//  The Driver step says plainly what installing does and does NOT do: no
//  microphone access, no orange dot, nothing recorded.
//
//  Honest progress: `EngineController.installDriver()` reports no sub-steps, so
//  the Installing step lists what happens with ONE indeterminate indicator
//  instead of pretending to tick items off.
//

import SwiftUI
import AppKit
import ServiceManagement

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch model.onboardingStep {
                case .welcome: welcome.transition(stepTransition)
                case .driver: driver.transition(stepTransition)
                case .installing: installing.transition(stepTransition)
                case .done: done.transition(stepTransition)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .animation(reduceMotion ? Motion.reduced : Motion.screen, value: model.onboardingStep)
            .animation(reduceMotion ? Motion.reduced : Motion.screen, value: model.installState)

            HStack {
                stepDots
                Spacer()
                buttons
            }
        }
        .padding(Space.s8)
        .frame(width: 560, height: 460)
    }

    private var stepTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(x: 8)),
                                              removal: .opacity.combined(with: .offset(x: -8)))
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            HStack {
                Spacer()
                // By asset name: `applicationIconImage` is only loaded once the
                // app has finished launching (not in snapshot mode).
                Image(nsImage: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage ?? NSImage())
                    .resizable()
                    .frame(width: 96, height: 96)
                    .accessibilityHidden(true)
                Spacer()
            }
            Text("Better sound for everything on your Mac").font(Typo.display)
            VStack(alignment: .leading, spacing: Space.s3) {
                feature("headphones", "Headphone correction", "Import your headphones\u{2019} AutoEQ profile in one drop.", Palette.targetStroke)
                feature("slider.horizontal.3", "Your tuning", "Shape the sound on top, without losing the correction.", Palette.fineStroke)
                feature("waveform.path", "Bass Style", "Punch or Rumble that reacts to the music.", Palette.bassStroke)
            }
        }
    }

    private var driver: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            Text(titleForDriverStep).font(Typo.display)
            Text(bodyForDriverStep)
                .font(Typo.body).foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if case .failed = model.installState {} else if model.installState != .cancelled {
                VStack(alignment: .leading, spacing: Space.s3) {
                    feature("key.fill", "One password prompt", "macOS asks once, to install the driver.", Palette.textSecondary)
                    feature("mic.slash.fill", "No microphone access", "No orange dot. EQtargets never listens to your mic.", Palette.textSecondary)
                    feature("record.circle", "Nothing recorded", "Sound is shaped live and never saved or sent anywhere.", Palette.textSecondary)
                    feature("trash", "Easy to remove", "Uninstall anytime in Settings \u{2192} Driver.", Palette.textSecondary)
                }
                Text("Sound pauses for a few seconds while macOS restarts its audio.")
                    .font(Typo.caption).foregroundStyle(Palette.textSecondary)
            }
        }
    }

    private var titleForDriverStep: String {
        switch model.installState {
        case .cancelled: return "Installation cancelled"
        case .failed: return "Installation didn\u{2019}t finish"
        default: return "One small audio driver"
        }
    }

    private var bodyForDriverStep: String {
        switch model.installState {
        case .cancelled: return "Nothing was changed. EQtargets needs the driver to shape your Mac\u{2019}s sound."
        case .failed(let e): return e
        default: return "EQtargets adds an audio device called \u{201C}EQtargets Audio\u{201D}. Your Mac sends sound to it, EQtargets shapes it, and plays it on your speakers or headphones."
        }
    }

    private var installing: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            Text("Installing\u{2026}").font(Typo.display)
            VStack(alignment: .leading, spacing: Space.s2) {
                ForEach(["Copying the driver", "Restarting macOS audio", "Waiting for EQtargets Audio"], id: \.self) { s in
                    Label(s, systemImage: "circle.dotted").font(Typo.body).foregroundStyle(Palette.textSecondary)
                }
            }
            ProgressView().progressViewStyle(.linear)
            Text("Sound may pause for a few seconds.").font(Typo.caption).foregroundStyle(Palette.textSecondary)
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            HStack {
                Spacer()
                Image(systemName: "checkmark.circle.fill").font(.system(size: 48)).foregroundStyle(Palette.positive)
                    .accessibilityHidden(true)
                Spacer()
            }
            Text("You\u{2019}re all set").font(Typo.display)
            Text("Listening on \(model.display.currentOutput?.name ?? "your Mac\u{2019}s output").")
                .font(Typo.body)
            Text("Pick headphones in Control Center as usual \u{2014} EQtargets follows them.")
                .font(Typo.body).foregroundStyle(Palette.textSecondary)
            @Bindable var model = model
            Toggle("Show in menu bar", isOn: $model.showMenuBarExtra).toggleStyle(.checkbox)
            LoginItemToggle(title: "Open at login", checkbox: true)
        }
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String, _ tint: Color) -> some View {
        HStack(alignment: .top, spacing: Space.s3) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Typo.bodySemibold)
                Text(detail).font(Typo.caption).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Footer

    private var stepDots: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStep.allCases, id: \.self) { s in
                Circle()
                    .fill(s == model.onboardingStep ? Palette.accentStroke : Palette.textPrimary.opacity(0.15))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(model.onboardingStep.rawValue + 1) of \(OnboardingStep.allCases.count)")
    }

    @ViewBuilder
    private var buttons: some View {
        switch model.onboardingStep {
        case .welcome:
            Button("Continue") { model.onboardingStep = .driver }
                .keyboardShortcut(.defaultAction)
        case .driver:
            switch model.installState {
            case .failed(let e):
                Button("Copy Details") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(e, forType: .string)
                }
                Button("Try Again") { Task { await model.installDriver() } }.keyboardShortcut(.defaultAction)
            case .cancelled:
                Button("Not Now") { notNow() }
                Button("Try Again") { Task { await model.installDriver() } }.keyboardShortcut(.defaultAction)
            default:
                Button("Not Now") { notNow() }
                Button("Install Driver") { Task { await model.installDriver() } }.keyboardShortcut(.defaultAction)
            }
        case .installing:
            Button("Install Driver") {}.disabled(true)
        case .done:
            Button("Start EQtargets") {
                model.setPowered(true)
                dismissWindow(id: "onboarding")
                openWindow(id: "main")
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private func notNow() {
        model.onboardingCompleted = true      // don't nag on every launch; the banner stays
        model.installState = .idle
        dismissWindow(id: "onboarding")
    }
}

// MARK: - Login item

/// "Open at login" via SMAppService. Reads the real registration status so the
/// checkbox never lies; only changes anything when the user clicks it.
struct LoginItemToggle: View {
    let title: String
    var checkbox = false
    @State private var enabled = SMAppService.mainApp.status == .enabled
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if checkbox {
                Toggle(title, isOn: Binding(get: { enabled }, set: { set($0) })).toggleStyle(.checkbox)
            } else {
                Toggle(title, isOn: Binding(get: { enabled }, set: { set($0) }))
            }
            if let error {
                Text(error).font(Typo.caption).foregroundStyle(Palette.danger)
            }
        }
    }

    private func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        enabled = SMAppService.mainApp.status == .enabled
    }
}
