//
//  OutputCard.swift
//  EQtargets (iOS)
//
//  The most important element on screen: where the sound is going and what to do
//  about it. Wording and controls per state come from `OutputCardContent`.
//
//  `.waiting` is the first thing a new user sees, so it carries the instruction.
//  There is deliberately no in-app output picker: AVRoutePickerView joins this
//  app to the shared output context, and picking EQtargets then pulls this app's
//  own audio onto the virtual device, where it feeds back into itself.
//

import SwiftUI
import UIKit

struct OutputCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showLimits = false
    /// Grows with the text size, so the glyph never spills out of its circle.
    @ScaledMetric(relativeTo: .body) private var infoDiameter: CGFloat = 32

    var body: some View {
        let status = model.displayStatus
        let output = model.currentOutput
        let bypass = model.outputBypass
        let content = OutputCardContent.make(status: status, output: output, bypass: bypass)
        VStack(alignment: .leading, spacing: Space.s3) {
            if typeSize.isAccessibilitySize {
                // The words get the full width; the glyph only repeats them.
                textBlock(showsStats: status == .running && bypass == .none, content: content)
                howItWorksButton
            } else {
                HStack(alignment: .top, spacing: Space.s3) {
                    OutputGlyph(status: status, content: content, output: output)
                    textBlock(showsStats: status == .running && bypass == .none, content: content)
                    howItWorksButton
                }
            }

            if let skipped = model.correctionOffer {
                offerRow(skipped, current: model.displayName(.correction), identifier: "output.useSkipped") {
                    model.useSkippedCorrection()
                }
            }
            if let skipped = model.tuningOffer {
                offerRow(skipped, current: model.displayName(.tuning), identifier: "output.useSkippedTuning") {
                    model.useSkippedTuning()
                }
            }

            if let chip = model.meters.chip {
                StatusChipView(chip: chip)
                    .transition(.opacity)
            }

            if content.action != nil {
                footer(content)
            }
        }
        .animation(.easeOut(duration: 0.3), value: model.meters.chip)
        .eqtCard()
    }

    /// A preset saved for this output that was not loaded, because the layer
    /// held unsaved edits.
    private func offerRow(_ skipped: SkippedCorrection, current: String, identifier: String,
                          use: @escaping () -> Void) -> some View {
        let offerLayout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.s2))
            : AnyLayout(HStackLayout(spacing: Space.s2))
        return offerLayout {
            Text("\u{201C}\(skipped.name)\u{201D} is saved for \(skipped.deviceName). Still using \u{201C}\(current)\u{201D}.")
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Use It", action: use)
                .buttonStyle(PillButtonStyle())
                .accessibilityLabel("Use \(skipped.name)")
                .accessibilityIdentifier(identifier)
        }
    }

    private func textBlock(showsStats: Bool, content: OutputCardContent) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(content.title)
                .font(Typo.title)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("output.title")
            if showsStats {
                OutputStatsLine(fallback: content.message)
            } else {
                Text(content.message)
                    .font(Typo.body)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func footer(_ content: OutputCardContent) -> some View {
        HStack(spacing: Space.s2) {
            switch content.action {
            case .turnOn:
                Button("Turn On") { model.setPowered(true) }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    .accessibilityIdentifier("output.turnOn")
            case .tryAgain:
                Button("Try Again") { model.retryEngine() }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                Button("Copy Details") { UIPasteboard.general.string = content.message }
                    .buttonStyle(PillButtonStyle())
            case nil:
                EmptyView()
            }
            Spacer(minLength: 0)
        }
    }

    private var howItWorksButton: some View {
        Button {
            showLimits = true
        } label: {
            Image(systemName: "info")
        }
        .buttonStyle(CircleButtonStyle(diameter: infoDiameter))
        .accessibilityLabel("How it works")
        .accessibilityIdentifier("output.howItWorks")
        .popover(isPresented: $showLimits) {
            HonestLimitsList()
                .padding(Space.s4)
                .frame(width: 320)
                .presentationCompactAdaptation(.popover)
        }
    }
}

// MARK: - Glyph

private struct OutputGlyph: View {
    let status: EngineStatus
    let content: OutputCardContent
    let output: OutputDevice?

    var body: some View {
        ZStack {
            Circle().fill(content.tone.color.opacity(0.15))
            if status == .starting {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: content.symbol ?? TransportSymbol.name(for: output))
                    .font(Typo.bodySemibold)
                    .foregroundStyle(content.tone.color)
            }
        }
        .frame(width: 40, height: 40)
        .accessibilityHidden(true)
    }
}

// MARK: - Live numbers

/// Its own view on purpose: the only thing on the main screen that reads the
/// stats, so their updates re-render this line and nothing else.
private struct OutputStatsLine: View {
    let fallback: String
    @Environment(AppModel.self) private var model

    var body: some View {
        let stats = model.display.stats
        let text = stats.sampleRate > 0
            ? "\(EQFormat.sampleRate(stats.sampleRate)) \u{00B7} \(EQFormat.latency(stats.latencyMs)) delay"
            : fallback
        Text(text)
            .font(Typo.value)
            .foregroundStyle(Palette.textSecondary)
            .accessibilityLabel(text
                .replacingOccurrences(of: "kHz", with: "kilohertz")
                .replacingOccurrences(of: "ms", with: "milliseconds"))
    }
}

// MARK: - Honest limits

/// What the app can't do, in plain words. Shown from the Output card and Settings.
struct HonestLimitsList: View {
    private static let items: [(symbol: String, title: String, detail: String)] = [
        ("square.stack", "Keep EQtargets open",
         "It can stay in the app switcher. If you force-quit it, the EQ stops."),
        ("power", "Turn it on before you choose it",
         "While it\u{2019}s off and in the background, EQtargets can\u{2019}t receive audio. If you choose it then, the sound cuts out for a few seconds until iOS drops the connection."),
        ("play.rectangle", "Video can drop the connection",
         "Apps such as YouTube, or Spotify with Canvas, may switch away from EQtargets. Choose it again if that happens."),
        ("waveform", "Audio runs at 48 kHz",
         "Everything passes through EQtargets at 48 kHz, whatever the source."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            ForEach(Self.items, id: \.title) { item in
                HStack(alignment: .top, spacing: Space.s3) {
                    Image(systemName: item.symbol)
                        .font(Typo.bodySemibold)
                        .foregroundStyle(Palette.accentInk)
                        .frame(width: 24)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(Typo.bodySemibold).foregroundStyle(Palette.textPrimary)
                        Text(item.detail).font(Typo.caption).foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

// MARK: - Status chip

/// Limiting / Clipping / Dropouts. Tapping explains it and, for an over, offers
/// the one-tap preamp fix.
struct StatusChipView: View {
    let chip: StatusChipTracker.Chip
    @Environment(AppModel.self) private var model
    @State private var showInfo = false

    var body: some View {
        let (title, help, danger) = copy
        Button {
            showInfo = true
        } label: {
            Label(title, systemImage: danger ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .font(Typo.captionSemibold)
                .foregroundStyle(danger ? Palette.onDanger : Palette.warning)
                .padding(.horizontal, Space.s3)
                .frame(minHeight: 28)
                .background(Capsule().fill(danger ? Palette.danger : Palette.warning.opacity(0.14)))
                .frame(minHeight: Space.touch)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("Warning: \(title.lowercased())")
        .popover(isPresented: $showInfo) {
            VStack(alignment: .leading, spacing: Space.s3) {
                Text(help)
                    .font(Typo.body)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if !isDropouts, let x = model.preampFixDB(overDB: model.meters.recentOverDB) {
                    Button("Lower Preamp to \(EQFormat.gain(x))") {
                        model.applyPreampFix(to: x)      // exactly what the button says
                        showInfo = false
                    }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                }
            }
            .padding(Space.s4)
            .frame(idealWidth: 300, maxWidth: 340)
            .presentationCompactAdaptation(.popover)
        }
    }

    private var isDropouts: Bool {
        if case .dropouts = chip { return true }
        return false
    }

    private var copy: (String, String, Bool) {
        switch chip {
        case .limiting:
            return ("Limiting", "The sound went past \u{2212}1\u{00A0}dB. The safety limiter caught it, so nothing clipped. Lowering the preamp keeps it cleaner.", false)
        case .clipping:
            return ("Clipping", "The sound is clipping. Lower the preamp, or turn on the safety limiter in Settings.", true)
        case .dropouts(let n):
            return ("Dropouts", "The audio briefly ran dry \(n) times in the last few seconds. If you hear crackles, close other audio apps. Details are in Settings under Diagnostics.", false)
        }
    }
}
