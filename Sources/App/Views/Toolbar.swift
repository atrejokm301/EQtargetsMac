//
//  Toolbar.swift
//  EQtargets (macOS)
//
//  Power · Output status pill (+ Limiting / Clipping / Dropouts chip) ·
//  Compare (DESIGN §6.4, §6.7, §10). Everything here is "Honest": the pill
//  always names the REAL device, its rate and latency, and says when the
//  safety limiter acts.
//

import SwiftUI
import AppKit

// MARK: - Power

struct PowerToggle: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // Status / power / output only — not `display`, whose stats change
        // twice a second while audio plays.
        let status = model.displayStatus
        let powered = model.displayIsPowered
        Toggle(isOn: Binding(get: { powered && status != .driverMissing },
                             set: { model.setPowered($0) })) {
            Text("EQtargets")
        }
        .toggleStyle(PowerToggleStyle(starting: status == .starting))
        .disabled(status == .driverMissing)
        .help(helpText(status: status, powered: powered))
    }

    private func helpText(status: EngineStatus, powered: Bool) -> String {
        if status == .driverMissing { return "Install the audio driver first." }
        if powered {
            return "Turn EQtargets off \u{2014} macOS plays straight to \(model.currentOutput?.name ?? "your output") (\u{2325}\u{2318}P)"
        }
        return "Turn EQtargets on (\u{2325}\u{2318}P)"
    }
}

/// 28 × 64 capsule: On = accent fill + white label; Off = clear + separator border.
struct PowerToggleStyle: ToggleStyle {
    let starting: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 5) {
                if starting {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "power").font(.system(size: 11, weight: .bold))
                }
                Text(configuration.isOn ? "On" : "Off").font(Typo.captionSemibold)
            }
            .foregroundStyle(configuration.isOn ? Color.white : Palette.textSecondary)
            .frame(width: 64, height: 28)
            .background {
                if configuration.isOn {
                    Capsule().fill(Palette.accentFill)
                } else {
                    HairlineCapsule(fill: hovering ? Palette.textPrimary.opacity(0.06) : Color(nsColor: .windowBackgroundColor))
                }
            }
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .accessibilityRepresentation {
            Toggle("EQtargets", isOn: configuration.$isOn)
        }
    }
}

// MARK: - Status pill

struct StatusPill: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openWindow) private var openWindow
    @State private var showError = false
    @State private var showChipInfo = false

    var body: some View {
        let d = model.display
        HStack(spacing: Space.s2) {
            if d.status == .driverMissing {
                pillBody(d)
                    .onTapGesture { openOnboarding() }
                Button("Install\u{2026}") { openOnboarding() }
                    .controlSize(.small)
            } else if let message = d.errorMessage {
                pillBody(d)
                Button("Details") { showError = true }
                    .controlSize(.small)
                    .popover(isPresented: $showError, arrowEdge: .bottom) { ErrorDetails(message: message) }
            } else {
                Menu {
                    OutputMenuItems()
                } label: {
                    pillBody(d)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            if let chip = model.meters.chip {
                StatusChipView(chip: chip, showInfo: $showChipInfo)
                    .transition(.opacity.animation(.easeOut(duration: 0.3)))
            }
        }
        .animation(.easeOut(duration: 0.3), value: model.meters.chip)
    }

    private func openOnboarding() {
        model.onboardingStep = .driver
        openWindow(id: "onboarding")
    }

    private func pillBody(_ d: EngineDisplay) -> some View {
        HStack(spacing: Space.s2) {
            leadingGlyph(d)
            Text(statusText(d))
                .font(Typo.body)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            if d.status != .driverMissing && d.errorMessage == nil {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .padding(.horizontal, Space.s3)
        .frame(minWidth: 220, maxWidth: 520, minHeight: 28, maxHeight: 28)
        .background(Capsule().fill(scheme == .dark ? Color.white.opacity(0.08) : Palette.textPrimary.opacity(0.06)))
        .contentShape(Capsule())
        .help(helpText(d))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Output")
        .accessibilityValue(statusText(d).replacingOccurrences(of: "kHz", with: "kilohertz").replacingOccurrences(of: " ms", with: " milliseconds"))
    }

    @ViewBuilder
    private func leadingGlyph(_ d: EngineDisplay) -> some View {
        switch d.status {
        case .starting:
            ProgressView().controlSize(.mini)
        case .driverMissing:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.warning)
        case .error:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(Palette.danger)
        case .off:
            Image(systemName: "power").foregroundStyle(Palette.textSecondary)
        case .running, .idle:
            if d.currentOutput == nil {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.warning)
            } else {
                HStack(spacing: 6) {
                    StatusDot(color: d.status == .running ? Palette.positive : Palette.textSecondary,
                              filled: d.status == .running)
                    Image(systemName: TransportSymbol.name(for: d.currentOutput))
                        .foregroundStyle(Palette.textSecondary)
                }
            }
        }
    }

    func statusText(_ d: EngineDisplay) -> String {
        StatusCopy.text(d)
    }

    private func helpText(_ d: EngineDisplay) -> String {
        switch d.status {
        case .running: return "Sound from every app is being shaped and played on \(d.currentOutput?.name ?? "your output")."
        case .idle: return "Nothing is playing. EQtargets uses no power until sound starts."
        case .error(let m): return m
        case .driverMissing: return "Install the audio driver to process sound."
        default: return StatusCopy.text(d)
        }
    }
}

/// Status line copy (§11.1), shared by the toolbar pill and the menu bar popover.
enum StatusCopy {
    static func text(_ d: EngineDisplay) -> String {
        let device = d.currentOutput?.name
        switch d.status {
        case .running:
            guard let device else { return "No output device" }
            return "\(device) \u{00B7} \(EQFormat.sampleRate(d.stats.sampleRate)) \u{00B7} \(EQFormat.latency(d.stats.latencyMs))"
        case .idle:
            guard let device else { return "No output device" }
            return "\(device) \u{00B7} Waiting for sound"
        case .off:
            return device.map { "Off \u{00B7} macOS plays directly to \($0)" } ?? "Off"
        case .starting:
            return "Starting\u{2026}"
        case .driverMissing:
            return "Audio driver not installed"
        case .error(let m):
            return m
        }
    }
}

private struct ErrorDetails: View {
    let message: String
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            Text("Something went wrong").font(Typo.bodySemibold)
            Text(message).font(Typo.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Copy Details") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message, forType: .string)
                }
                Spacer()
                Button("Try Again") { model.setPowered(true) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.s4)
        .frame(width: 320)
    }
}

/// "Play through" output menu: Follow macOS + every real device + Sound Settings.
struct OutputMenuItems: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let d = model.display
        let followName = model.pinnedOutputUID == nil ? (d.currentOutput?.name).map { " (\($0))" } ?? "" : ""
        Section("Play through") {
            Toggle("Follow macOS\(followName)", isOn: Binding(get: { model.pinnedOutputUID == nil },
                                                             set: { _ in model.selectOutput(uid: nil) }))
            ForEach(d.outputDevices) { dev in
                Toggle(isOn: Binding(get: { model.pinnedOutputUID == dev.uid }, set: { _ in model.selectOutput(uid: dev.uid) })) {
                    Label("\(dev.name) \u{2014} \(EQFormat.sampleRate(dev.nominalSampleRate))",
                          systemImage: TransportSymbol.name(for: dev))
                }
            }
        }
        Divider()
        Button("Sound Settings\u{2026}") {
            if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

// MARK: - Status chip

struct StatusChipView: View {
    let chip: StatusChipTracker.Chip
    @Binding var showInfo: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        let (title, help, danger) = copy
        Button { showInfo.toggle() } label: {
            Text(title)
                .font(Typo.captionSemibold)
                .foregroundStyle(danger ? Palette.onDanger : Palette.warning)
                .padding(.horizontal, Space.s2)
                .frame(height: 22)
                .background(Capsule().fill(danger ? Palette.danger : Palette.warning.opacity(0.14)))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel("Warning: \(title.lowercased())")
        .popover(isPresented: $showInfo, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: Space.s3) {
                Text(help).font(Typo.body).fixedSize(horizontal: false, vertical: true)
                if !isDropouts, let x = model.preampFixDB(overDB: model.meters.recentOverDB) {
                    Button("Lower Preamp to \(EQFormat.gain(x))") {
                        model.applyPreampFix(to: x)      // exactly what the button says
                        showInfo = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(Space.s4)
            .frame(width: 300)
        }
    }

    private var isDropouts: Bool { if case .dropouts = chip { return true }; return false }

    private var copy: (String, String, Bool) {
        switch chip {
        case .limiting:
            // Not "your EQ": the limiter also catches a hot master, Punch or Bass post gain.
            return ("Limiting", "The sound went past \u{2212}1\u{00A0}dB. The safety limiter caught it, so nothing clipped \u{2014} lowering the preamp keeps it cleaner.", false)
        case .clipping:
            return ("Clipping", "The sound is clipping. Lower the preamp, or turn on the safety limiter in Settings \u{2192} Audio.", true)
        case .dropouts(let n):
            return ("Dropouts", "The audio briefly ran dry \(n) times in the last few seconds. If you hear crackles, open Settings \u{2192} Driver \u{2192} Diagnostics.", false)
        }
    }
}

// MARK: - Compare

/// Hold to peek, click to lock (§6.4). A press shorter than 250 ms toggles the
/// latch; a longer hold is momentary. Bypass engages at press-DOWN (no delay)
/// and drives only `masterBypass` — never power or routing — so it is instant
/// and can't glitch.
struct CompareButton: View {
    var fullWidth = false
    @Environment(AppModel.self) private var model
    @State private var pressStart: Date?

    var body: some View {
        let enabled = model.displayIsProcessing
        let active = model.isComparing
        HStack(spacing: 6) {
            Image(systemName: model.compareLatched ? "lock.fill" : "circle.lefthalf.filled")
                .font(.system(size: 11, weight: .semibold))
            Text(fullWidth ? (active ? "Original" : "Hold to Compare") : (active ? "Original" : "Compare"))
                .font(Typo.bodySemibold)
        }
        .foregroundStyle(active ? Color(nsColor: .windowBackgroundColor) : Palette.textPrimary)
        .padding(.horizontal, Space.s3)
        .frame(maxWidth: fullWidth ? .infinity : nil)
        .frame(height: fullWidth ? 32 : 28)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(active ? Palette.textPrimary : Palette.textPrimary.opacity(0.06))
        )
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.separator, lineWidth: active ? 0 : 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .opacity(enabled ? 1 : 0.4)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard enabled, pressStart == nil else { return }
                    pressStart = Date()
                    model.compareHeld = true
                }
                .onEnded { _ in
                    guard let start = pressStart else { return }
                    pressStart = nil
                    if Date().timeIntervalSince(start) < 0.25 { model.compareLatched.toggle() }
                    model.compareHeld = false
                }
        )
        .help(enabled ? "Hold to hear your Mac without EQtargets. Click to lock (\u{2318}B)." : "Turn EQtargets on to compare.")
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Compare with original")
        .accessibilityValue(model.compareLatched ? "Locked" : (active ? "On" : "Off"))
        .accessibilityAction { model.toggleCompareLatch() }
    }
}
