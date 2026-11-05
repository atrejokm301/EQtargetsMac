//
//  BassStylePanel.swift
//  EQtargets (macOS)
//
//  Bass Style inspector (DESIGN §8.1) with the iOS BassStyleEditorSheet's
//  semantics: chips call `selectStyle(_, applyRecommendedCutoff: true)`;
//  Strength / Cutoff / Post gain shape the static stage; the Dynamics card
//  drives the shared Punch / Rumble stage with mirrored wording (one slider
//  boosts, one cuts) and shows the live activity meter.
//
//  The stage runs after both EQ layers and never edits a band — the footer
//  says so, and it is deliberately not drawn on the graph.
//

import SwiftUI

struct BassStylePanel: View {
    /// false only for snapshot rendering (the panel is captured without its scroll view).
    var scrolls = true
    @Environment(AppModel.self) private var model
    @State private var showInfo = false

    var body: some View {
        if scrolls {
            ScrollView { content }
        } else {
            content
        }
    }

    private var content: some View {
            VStack(alignment: .leading, spacing: Space.s3) {
                HStack {
                    Text("Bass Style").font(Typo.title)
                    Spacer()
                    Button { showInfo.toggle() } label: {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("About the Bass Styles")
                    .accessibilityLabel("About the Bass Styles")
                    .popover(isPresented: $showInfo, arrowEdge: .bottom) {
                        Text("Punch tightens kicks. Rumble lets low notes ring longer. Clean is a gentle, steady lift. Every style is loudness-matched, so you compare character, not volume.")
                            .font(Typo.body)
                            .frame(width: 260)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(Space.s4)
                    }
                }

                VStack(alignment: .leading, spacing: Space.s2) {
                    StyleChips()
                    Text(model.bass.style == .none
                         ? "Pick a style to add weight without touching your EQ."
                         : model.bass.style.subtitle)
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if model.bass.style != .none {
                    ShapeCard()
                }
                if model.bass.style.hasDynamics {
                    DynamicsCard()
                } else if model.bass.style == .naturalClean {
                    Text("Clean is a steady, gentle lift \u{2014} it has no dynamic stage.")
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .eqtCard(padding: Space.s3)
                }

                Text("Runs after both EQ layers. Never changes your bands. Not drawn on the graph.")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Space.s4)
    }
}

// MARK: - Style chips (shared with the popover and the compact row)

struct StyleChips: View {
    var compact = false
    @Environment(AppModel.self) private var model

    var body: some View {
        // Four EQUAL-width chips (§8.1). Icons when the widest chip still fits
        // four across; otherwise the whole row drops icons together — never
        // truncated labels, never chips that differ from each other.
        ViewThatFits(in: .horizontal) {
            row(icons: true)
            row(icons: false)
        }
    }

    private func row(icons: Bool) -> some View {
        EqualWidthHStack(spacing: compact ? Space.s1 : 6, fill: !compact) {
            ForEach(BassStyle.allCases) { style in
                StyleChip(style: style, selected: model.bass.style == style, showIcon: icons) {
                    model.selectBassStyle(style)
                }
            }
        }
    }
}

/// Lays children out at one shared width. Its ideal width is
/// widest-child × count, which is exactly what `ViewThatFits` needs to decide
/// whether the icon row fits (a plain HStack reports the SUM of ideals and
/// then hands out unequal widths).
struct EqualWidthHStack: Layout {
    var spacing: CGFloat
    /// Take the whole proposed width (inspector / popover) or only what's needed (compact row).
    var fill: Bool

    private func measure(_ subviews: Subviews) -> (width: CGFloat, height: CGFloat) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return (sizes.map(\.width).max() ?? 0, sizes.map(\.height).max() ?? 0)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let m = measure(subviews)
        let needed = m.width * CGFloat(subviews.count) + spacing * CGFloat(subviews.count - 1)
        guard fill, let w = proposal.width, w.isFinite else { return CGSize(width: needed, height: m.height) }
        return CGSize(width: max(w, needed), height: m.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let n = CGFloat(subviews.count)
        let w = (bounds.width - spacing * (n - 1)) / n
        var x = bounds.minX
        for sv in subviews {
            sv.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                     proposal: ProposedViewSize(width: w, height: bounds.height))
            x += w + spacing
        }
    }
}

private struct StyleChip: View {
    let style: BassStyle
    let selected: Bool
    var showIcon = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s1) {
                if showIcon {
                    Image(systemName: style.systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(selected ? Palette.bassOnFill : Palette.bassStroke)
                        .accessibilityHidden(true)
                }
                Text(style.compactTitle)
                    .font(Typo.captionSemibold)
                    .foregroundStyle(selected ? Palette.bassOnFill : Palette.textPrimary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, Space.s2)
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background {
                // §10: default = solid bg.card + 0.5 pt border (an opaque fill
                // keeps the hairline and the capsule edge on the same curve);
                // hover = +4% primary; selected = bass.fill.
                if selected {
                    Capsule().fill(Palette.bassFill)
                } else {
                    HairlineCapsule(fill: Palette.card)
                        .overlay(Capsule().fill(Palette.textPrimary.opacity(hovering ? 0.04 : 0)).padding(0.5))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .onHover { h in withAnimation(Motion.hover) { hovering = h } }
        .accessibilityLabel(style.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Shape card

private struct ShapeCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let b = model.bass
        VStack(alignment: .leading, spacing: Space.s3) {
            LabeledSlider(title: "Strength", valueText: EQFormat.percent(b.strength),
                          value: binding(\.strength), range: BassProcessorState.strengthRange,
                          help: "How much of the style you hear. Loudness stays matched, so more isn\u{2019}t just louder.",
                          onEditing: editing)
            VStack(alignment: .leading, spacing: Space.s1) {
                LabeledSlider(title: b.cutoffMatchesStyleRecommendation ? "Cutoff \u{00B7} recommended" : "Cutoff",
                              valueText: EQFormat.cutoff(b.cutoff),
                              value: binding(\.cutoff), range: BassProcessorState.cutoffRange,
                              help: "Where the bass shaping is centred. Picking a style sets the recommended value.",
                              onEditing: editing)
                if !b.cutoffMatchesStyleRecommendation, let rec = b.style.recommendedCutoffHz {
                    Button("\u{21BA} \(EQFormat.cutoff(rec))") { model.restoreRecommendedCutoff() }
                        .buttonStyle(.link)
                        .font(Typo.caption)
                        .foregroundStyle(Palette.bassInk)
                        .help("Back to the recommended cutoff")
                }
            }
            LabeledSlider(title: "Post gain", valueText: EQFormat.gain(b.postGain),
                          value: binding(\.postGain), range: BassProcessorState.postGainRange,
                          help: "Extra level after the bass stage, if the style feels quieter or louder than you like.",
                          onEditing: editing)
        }
        .eqtCard()
    }

    private func binding(_ key: WritableKeyPath<BassProcessorState, Double>) -> Binding<Double> {
        Binding(get: { model.bass[keyPath: key] }, set: { v in model.updateBass { $0[keyPath: key] = v } })
    }

    /// One undo step per slider drag.
    private func editing(_ active: Bool) {
        if active { model.beginGesture() } else { model.endGesture("Change Bass Style") }
    }
}

// MARK: - Dynamics card

private struct DynamicsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let rumble = model.bass.style == .sustainRumble
        let b = model.bass
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack(spacing: 6) {
                Image(systemName: rumble ? "water.waves" : "waveform.path")
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
                          range: 0 ... 1, onEditing: editing)
            // Cutting half.
            LabeledSlider(title: rumble ? "Attack softening" : "Sustain control",
                          valueText: EQFormat.percentOrOff(rumble ? b.rumbleSoften : b.punchSustain),
                          value: Binding(get: { rumble ? model.bass.rumbleSoften : model.bass.punchSustain },
                                         set: { v in model.updateBass { if rumble { $0.rumbleSoften = v } else { $0.punchSustain = v } } }),
                          range: 0 ... 1, onEditing: editing)

            ActivityMeterView(size: .full)

            Text(rumble
                 ? "Sustain holds a note up as it decays, so the low end rings on longer \u{2014} it only acts once the note is already falling, so steady bass keeps its level. Attack softening rounds the leading edge, the deliberate opposite of Punch."
                 : "Attack lifts the leading edge of kicks. Sustain control trims what sits behind them \u{2014} raise it for a tighter, drier low end.")
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .eqtCard()
    }

    private func editing(_ active: Bool) {
        if active { model.beginGesture() } else { model.endGesture("Change Bass Style") }
    }
}

// MARK: - Compact row (compact width; same component as the popover)

struct CompactBassRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Space.s3) {
            Text("Bass").font(Typo.bodySemibold)
            StyleChips(compact: true)
            if model.bass.style.hasDynamics {
                ActivityMeterView(size: .mini)
            }
            Spacer(minLength: Space.s2)
            Button("Details\u{2026}") { model.bassPanelCompact = true }
        }
        .frame(height: 32)
        .eqtCard(padding: Space.s3)
    }
}
