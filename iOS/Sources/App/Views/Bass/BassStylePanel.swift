//
//  BassStylePanel.swift
//  EQtargets (iOS)
//
//  Bass Style (DESIGN §8.1). Chips call `selectStyle(_, applyRecommendedCutoff:
//  true)`; Strength, Cutoff and Post gain shape the static stage; Dynamics drives
//  the shared Punch / Rumble stage and shows the live activity meter.
//
//  The stage runs after both EQ layers and never edits a band. The footer says
//  so, and it is deliberately not drawn on the graph.
//

import SwiftUI

struct BassStylePanel: View {
    @Environment(AppModel.self) private var model
    @State private var showInfo = false

    var body: some View {
        let style = model.bass.style
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack {
                Text("Bass Style")
                    .font(Typo.title)
                    .foregroundStyle(Palette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button {
                    showInfo = true
                } label: {
                    Image(systemName: "info")
                }
                .buttonStyle(CircleButtonStyle(diameter: 32))
                .accessibilityLabel("About the Bass Styles")
                .popover(isPresented: $showInfo) {
                    Text("Punch tightens kicks. Rumble lets low notes ring longer. Clean is a gentle, steady lift. Every style is loudness-matched, so you compare character, not volume.")
                        .font(Typo.body)
                        .foregroundStyle(Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(Space.s4)
                        .frame(width: 280)
                        .presentationCompactAdaptation(.popover)
                }
            }

            VStack(alignment: .leading, spacing: Space.s1) {
                StyleChips()
                Text(style == .none ? "Pick a style to add weight without touching your EQ." : style.subtitle)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if style != .none {
                Divider()
                ShapeSection()
            }
            if style.hasDynamics {
                Divider()
                DynamicsSection()
            } else if style == .naturalClean {
                Text("Clean is a steady, gentle lift \u{2014} it has no dynamic stage.")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Runs after both EQ layers. Never changes your bands. Not drawn on the graph.")
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .eqtCard()
    }
}

// MARK: - Style chips

struct StyleChips: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // Four EQUAL-width chips (§8.1). Icons when the widest chip still fits
        // four across; then the whole row drops them together; at the largest
        // text sizes, two rows of two.
        ViewThatFits(in: .horizontal) {
            row(BassStyle.allCases, icons: true)
            row(BassStyle.allCases, icons: false)
            VStack(spacing: Space.s1) {
                row(Array(BassStyle.allCases.prefix(2)), icons: false)
                row(Array(BassStyle.allCases.suffix(2)), icons: false)
            }
        }
    }

    private func row(_ styles: [BassStyle], icons: Bool) -> some View {
        EqualWidthHStack(spacing: Space.s1) {
            ForEach(styles) { style in
                StyleChip(style: style, selected: model.bass.style == style, showIcon: icons) {
                    model.selectBassStyle(style)
                }
            }
        }
    }
}

private struct StyleChip: View {
    let style: BassStyle
    let selected: Bool
    var showIcon = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s1) {
                if showIcon {
                    Image(systemName: style.systemImage)
                        .font(Typo.captionSemibold)
                        .foregroundStyle(selected ? Palette.bassOnFill : Palette.bassInk)
                        .accessibilityHidden(true)
                }
                Text(style.compactTitle)
                    .font(Typo.captionSemibold)
                    .foregroundStyle(selected ? Palette.bassOnFill : Palette.textPrimary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, Space.s2)
            .padding(.vertical, Space.s1)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 34)
            .background(Capsule().fill(selected ? Palette.bassFill : Palette.textPrimary.opacity(0.08)))
            .frame(minHeight: Space.touch)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(style.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("bass.style.\(style.rawValue)")
    }
}

// MARK: - Shape

private struct ShapeSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let b = model.bass
        VStack(alignment: .leading, spacing: Space.s2) {
            LabeledSlider(title: "Strength", valueText: EQFormat.percent(b.strength),
                          value: binding(\.strength), range: BassProcessorState.strengthRange,
                          onEditing: editing, onMoved: moved)
            VStack(alignment: .leading, spacing: 0) {
                LabeledSlider(title: b.cutoffMatchesStyleRecommendation ? "Cutoff \u{00B7} recommended" : "Cutoff",
                              valueText: EQFormat.cutoff(b.cutoff),
                              value: binding(\.cutoff), range: BassProcessorState.cutoffRange,
                              onEditing: editing, onMoved: moved)
                if !b.cutoffMatchesStyleRecommendation, let rec = b.style.recommendedCutoffHz {
                    Button {
                        model.restoreRecommendedCutoff()
                    } label: {
                        Label(EQFormat.cutoff(rec), systemImage: "arrow.counterclockwise")
                            .font(Typo.captionSemibold)
                    }
                    .buttonStyle(PillButtonStyle())
                    .accessibilityLabel("Back to the recommended cutoff, \(EQFormat.cutoff(rec))")
                }
            }
            LabeledSlider(title: "Post gain", valueText: EQFormat.gain(b.postGain),
                          value: binding(\.postGain), range: BassProcessorState.postGainRange,
                          onEditing: editing, onMoved: moved)
        }
    }

    private func binding(_ key: WritableKeyPath<BassProcessorState, Double>) -> Binding<Double> {
        Binding(get: { model.bass[keyPath: key] }, set: { v in model.updateBass { $0[keyPath: key] = v } })
    }

    /// One undo step per slider drag.
    private func editing(_ active: Bool) {
        if active {
            model.beginGesture(owner: "bass.tone", name: "Change Bass Style")
        } else {
            model.endGesture("Change Bass Style", owner: "bass.tone")
        }
    }

    private func moved() {
        model.resumeGesture(owner: "bass.tone", name: "Change Bass Style")
    }
}

// MARK: - Dynamics

private struct DynamicsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let rumble = model.bass.style == .sustainRumble
        let b = model.bass
        VStack(alignment: .leading, spacing: Space.s2) {
            HStack(spacing: 6) {
                Image(systemName: rumble ? "water.waves" : "waveform.path")
                    .accessibilityHidden(true)
                Text("Dynamics").textCase(.uppercase).tracking(0.6)
            }
            .font(Typo.captionSemibold)
            .foregroundStyle(Palette.textSecondary)
            .accessibilityAddTraits(.isHeader)

            // Boosting half.
            LabeledSlider(title: rumble ? "Sustain length" : "Attack emphasis",
                          valueText: EQFormat.percentOrOff(rumble ? b.rumbleSustain : b.punchAttack),
                          value: Binding(get: { rumble ? model.bass.rumbleSustain : model.bass.punchAttack },
                                         set: { v in model.updateBass { if rumble { $0.rumbleSustain = v } else { $0.punchAttack = v } } }),
                          range: 0 ... 1, onEditing: editing, onMoved: moved)
                .id(rumble ? "rumble-boost" : "punch-boost")    // a held slider must not retarget
            // Cutting half.
            LabeledSlider(title: rumble ? "Attack softening" : "Sustain control",
                          valueText: EQFormat.percentOrOff(rumble ? b.rumbleSoften : b.punchSustain),
                          value: Binding(get: { rumble ? model.bass.rumbleSoften : model.bass.punchSustain },
                                         set: { v in model.updateBass { if rumble { $0.rumbleSoften = v } else { $0.punchSustain = v } } }),
                          range: 0 ... 1, onEditing: editing, onMoved: moved)
                .id(rumble ? "rumble-cut" : "punch-cut")

            ActivityMeterView()
                .padding(.vertical, Space.s1)

            Text(rumble
                 ? "Sustain holds a note up as it decays, so the low end rings on longer \u{2014} it only acts once the note is already falling, so steady bass keeps its level. Attack softening rounds the leading edge, the deliberate opposite of Punch."
                 : "Attack lifts the leading edge of kicks. Sustain control trims what sits behind them \u{2014} raise it for a tighter, drier low end.")
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func editing(_ active: Bool) {
        if active {
            model.beginGesture(owner: "bass.dynamics", name: "Change Bass Style")
        } else {
            model.endGesture("Change Bass Style", owner: "bass.dynamics")
        }
    }

    private func moved() {
        model.resumeGesture(owner: "bass.dynamics", name: "Change Bass Style")
    }
}
