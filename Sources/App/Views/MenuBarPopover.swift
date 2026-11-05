//
//  MenuBarPopover.swift
//  EQtargets (macOS)
//
//  Menu bar extra, `.window` style, 360 pt wide (DESIGN §5.5): quick power,
//  status, output, both layers, hold-to-compare and Bass Style with the mini
//  meter. Same components as the main window so they look and behave the same.
//

import SwiftUI
import AppKit

struct MenuBarPopover: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var windowVisible = false

    var body: some View {
        let d = model.display
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("EQtargets").font(Typo.bodySemibold)
                Spacer()
                PowerToggle()
            }
            .frame(height: 32)
            HStack(spacing: 6) {
                statusDot(d)
                Text(StatusCopy.text(d))
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.bottom, Space.s2)

            Divider().padding(.vertical, Space.s1)

            if d.status == .driverMissing {
                VStack(alignment: .leading, spacing: Space.s2) {
                    Text("Audio driver not installed").font(Typo.body)
                    Button("Install Driver\u{2026}") {
                        model.onboardingStep = .driver
                        openWindow(id: "onboarding")
                        NSApp.activate()
                    }
                }
                .padding(.vertical, Space.s2)
            } else {
                row("Output") {
                    Menu {
                        OutputMenuItems()
                    } label: {
                        Text(outputTitle(d)).lineLimit(1).truncationMode(.middle)
                    }
                    .menuStyle(.button)
                }
                row("Correction") { PresetMenu(kind: .correction) }
                row("Your tuning") { PresetMenu(kind: .tuning) }
                CompareButton(fullWidth: true)
                    .padding(.vertical, Space.s2)
            }

            Divider().padding(.vertical, Space.s1)

            VStack(alignment: .leading, spacing: Space.s2) {
                Text("Bass Style").font(Typo.bodySemibold)
                StyleChips()
                if model.bass.style.hasDynamics {
                    ActivityMeterView(size: .mini)
                }
            }
            .padding(.vertical, Space.s2)

            Divider().padding(.vertical, Space.s1)

            HStack {
                Button("Open EQtargets") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                Spacer()
                SettingsLink { Text("Settings\u{2026}") }
                    .buttonStyle(.borderless)
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.borderless)
                    .keyboardShortcut("q")
            }
            .frame(height: 32)
        }
        .padding(Space.s3)
        .frame(width: 360)
        .environment(\.windowIsVisible, windowVisible)
        .background(WindowObserver { _, visible in
            if windowVisible != visible { windowVisible = visible }
        })
    }

    private func outputTitle(_ d: EngineDisplay) -> String {
        if let pin = model.pinnedOutputUID, let dev = d.outputDevices.first(where: { $0.uid == pin }) {
            return dev.name
        }
        return "Follow macOS" + ((d.currentOutput?.name).map { " (\($0))" } ?? "")
    }

    private func row<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: Space.s2) {
            Text(title).font(Typo.body).foregroundStyle(Palette.textSecondary)
                .frame(width: 84, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 32)
    }

    @ViewBuilder
    private func statusDot(_ d: EngineDisplay) -> some View {
        switch d.status {
        case .running: StatusDot(color: Palette.positive)
        case .idle: StatusDot(color: Palette.textSecondary, filled: false)
        case .driverMissing: Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(Palette.warning)
        case .error: Image(systemName: "xmark.octagon.fill").font(.system(size: 10)).foregroundStyle(Palette.danger)
        case .starting: ProgressView().controlSize(.mini)
        case .off: Image(systemName: "power").font(.system(size: 10)).foregroundStyle(Palette.textSecondary)
        }
    }
}

/// Menu bar glyph (§13): On = slider.vertical.3, Off = same at 45%, attention = warning triangle.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // Status / power only — never `display` (its stats change twice a
        // second while audio plays, and this label is always alive).
        let powered = model.displayIsPowered
        switch model.displayStatus {
        case .driverMissing, .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .accessibilityLabel("EQtargets needs attention")
        default:
            Image(systemName: "slider.vertical.3")
                .opacity(powered ? 1 : 0.45)
                .accessibilityLabel(powered ? "EQtargets, on" : "EQtargets, off")
        }
    }
}
