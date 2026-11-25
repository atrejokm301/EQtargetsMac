//
//  Header.swift
//  EQtargets (iOS)
//
//  The fixed top bar: name, status pill, power and Settings. It reads status and
//  power only, never `display`, whose stats change up to 4 times a second.
//

import SwiftUI

struct HeaderBar: View {
    var onStatusTap: () -> Void = {}
    let onSettings: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: Space.s2) {
            Text("EQtargets")
                .font(Typo.title)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .layoutPriority(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            // At large sizes the row can't hold it, and the Output card directly
            // below says the same thing in full.
            if typeSize <= .xLarge {
                StatusPill(onTap: onStatusTap)
            }
            PowerToggle()
            Button(action: onSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(CircleButtonStyle())
            .accessibilityLabel("Settings")
            .accessibilityShowsLargeContentViewer {
                Label("Settings", systemImage: "gearshape")
            }
            .accessibilityIdentifier("settings.open")
        }
        // A fixed bar: like the system's own bars its text stops growing, and a
        // long press shows the Large Content Viewer.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .padding(.horizontal, Space.s4)
    }
}

// MARK: - Power

struct PowerToggle: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let powered = model.displayIsPowered
        let status = model.displayStatus
        Toggle(isOn: Binding(get: { powered }, set: { model.setPowered($0) })) {
            Text("EQtargets")
        }
        .toggleStyle(PowerToggleStyle(starting: status == .starting))
        .accessibilityShowsLargeContentViewer {
            Label(powered ? "EQtargets On" : "EQtargets Off", systemImage: "power")
        }
        .accessibilityHint(powered ? "Turns the EQ off" : "Turns the EQ on")
        .accessibilityIdentifier("power")
    }
}

/// On = accent fill and white label; Off = quiet capsule.
struct PowerToggleStyle: ToggleStyle {
    let starting: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: Space.s1) {
                if starting {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(configuration.isOn ? .white : Palette.textSecondary)
                } else {
                    Image(systemName: "power").font(Typo.captionSemibold)
                }
                Text(configuration.isOn ? "On" : "Off").font(Typo.captionSemibold)
            }
            .foregroundStyle(configuration.isOn ? Color.white : Palette.textSecondary)
            .padding(.horizontal, Space.s3)
            .frame(minWidth: 64, minHeight: 32)
            .background(Capsule().fill(configuration.isOn ? Palette.accentFill : Palette.textPrimary.opacity(0.08)))
            .frame(minHeight: Space.touch)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .animation(reduceMotion ? nil : Motion.select, value: configuration.isOn)
        .accessibilityRepresentation {
            Toggle("EQtargets", isOn: configuration.$isOn)
        }
    }
}

// MARK: - Status pill

struct StatusPill: View {
    var onTap: () -> Void = {}
    @Environment(AppModel.self) private var model

    var body: some View {
        let status = model.displayStatus
        let content = OutputCardContent.make(status: status, output: model.currentOutput,
                                             bypass: model.outputBypass)
        Button(action: onTap) {
            HStack(spacing: 6) {
                if status == .starting {
                    ProgressView().controlSize(.mini)
                } else {
                    StatusDot(color: content.tone.color, filled: status != .idle && status != .off)
                }
                Text(content.pill)
                    .font(Typo.captionSemibold)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
            }
            .padding(.horizontal, Space.s3)
            .frame(minHeight: 32)
            .background(Capsule().fill(Palette.textPrimary.opacity(0.08)))
            .frame(minHeight: Space.touch)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("Status")
        .accessibilityValue(content.title)
        .accessibilityHint("Shows the output card")
        .accessibilityIdentifier("status.pill")
    }
}
