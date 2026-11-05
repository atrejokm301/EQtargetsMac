//
//  BandEditor.swift
//  EQtargets (macOS)
//
//  Band strip (10 pills) + inspector fields for the selected band of the
//  edited layer, and that layer's preamp (DESIGN §6.3). The expert's view:
//  exact numbers, forgiving input, one undo step per committed field.
//

import SwiftUI

struct BandEditorView: View {
    let compact: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        let layer = model.dual.editingLayer
        let i = model.selectedBandIndex
        let band = model.band(i)
        VStack(alignment: .leading, spacing: Space.s3) {
            BandStrip()
            HStack(spacing: Space.s4) {
                Text("Band \(i + 1)")
                    .font(Typo.bodySemibold)
                    .foregroundStyle(Palette.ink(layer))
                    .frame(width: 56, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                labeled("Type") {
                    Picker("Type", selection: Binding(get: { band.filterType }, set: { model.setBandType(i, $0) })) {
                        ForEach(EQFilterType.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                labeled("Frequency") {
                    ValueField(label: "Frequency", value: band.frequency, format: EQFormat.frequency,
                               parse: EQFormat.parseFrequency, range: EQBand.frequencyRange,
                               step: { v, d, fine, coarse in v * pow(2, d / (fine ? 48 : coarse ? 3 : 12)) },
                               width: 84) { v in model.commitBandField(i, layer: layer, name: "Move Band \(i + 1)") { $0.frequency = v } }
                        .id(fieldID(layer, i, "freq"))
                }
                labeled("Gain") {
                    ValueField(label: "Gain", value: band.gain, format: EQFormat.gain, parse: EQFormat.parseGain,
                               range: EQBand.gainRange,
                               step: { v, d, fine, coarse in ((v + d * (fine ? 0.1 : coarse ? 3 : 0.5)) * 10).rounded() / 10 },
                               width: 76) { v in model.commitBandField(i, layer: layer, name: "Move Band \(i + 1)") { $0.gain = v } }
                        .id(fieldID(layer, i, "gain"))
                }
                labeled("Q") {
                    ValueField(label: "Q", value: band.q, format: EQFormat.q, parse: EQFormat.parseQ,
                               range: EQBand.qRange,
                               step: { v, d, fine, _ in v * pow(2, d / (fine ? 24 : 6)) },
                               width: 56) { v in model.commitBandField(i, layer: layer, name: "Change Q") { $0.q = v } }
                        .id(fieldID(layer, i, "q"))
                        .help("Higher Q = narrower. For shelves, Q sets how steep the shelf is (0.71 is standard).")
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: Space.s4) {
                Toggle("On", isOn: Binding(get: { band.isEnabled }, set: { model.setBandEnabled(i, $0) }))
                    .toggleStyle(.checkbox)
                    .accessibilityLabel("Band \(i + 1) on")
                Button {
                    model.resetBandGain(i)
                } label: {
                    Label("Reset band", systemImage: "arrow.counterclockwise")
                }
                .help("Reset gain to 0 dB (\u{2318}\u{232B})")
                Spacer(minLength: Space.s2)
                Text(layer == .target ? "Correction preamp" : "Tuning preamp")
                    .font(Typo.body)
                    .foregroundStyle(Palette.textSecondary)
                ValueField(label: layer == .target ? "Correction preamp" : "Tuning preamp",
                           value: model.layerState(layer).preamp, format: EQFormat.gain, parse: EQFormat.parseGain,
                           range: EQLayerState.preampRange,
                           step: { v, d, fine, coarse in ((v + d * (fine ? 0.1 : coarse ? 3 : 0.5)) * 10).rounded() / 10 },
                           width: 76) { v in model.commitPreamp(v, layer: layer) }
                    .id(fieldID(layer, nil, "preamp"))
                    .help("Lowers this whole layer so boosts don\u{2019}t clip. Imported corrections set it for you. Double-click the handle on the graph to set it automatically.")
            }
        }
        .eqtCard(padding: compact ? Space.s3 : Space.s4)
    }

    /// One identity per (layer, band, field): switching band or layer gives the
    /// field fresh text, and a late commit still targets the band / layer it was
    /// typed for (the closures above capture `i` and `layer`, never "current").
    private func fieldID(_ layer: EQLayer, _ band: Int?, _ field: String) -> String {
        "\(layer == .target ? "target" : "fineTune")-\(band.map(String.init) ?? "layer")-\(field)"
    }

    private func labeled<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: Space.s2) {
            Text(title).font(Typo.body).foregroundStyle(Palette.textSecondary)
            content()
        }
    }
}

// MARK: - Band strip

private struct BandStrip: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let layer = model.dual.editingLayer
        let bands = model.layerState(layer).bands
        HStack(spacing: Space.s1) {
            ForEach(Array(bands.enumerated()), id: \.offset) { i, b in
                let selected = model.selectedBandIndex == i
                Button {
                    withAnimation(Motion.select) { model.selectBand(i) }
                } label: {
                    HStack(spacing: 3) {
                        Text("\(i + 1)").fontWeight(.semibold)
                        if b.filterType != .peak {
                            Image(systemName: b.filterType == .lowShelf ? "arrow.down.to.line" : "arrow.up.to.line")
                                .font(.system(size: 9, weight: .semibold))
                                .accessibilityHidden(true)
                        }
                        Text("\u{00B7}").foregroundStyle(Palette.textSecondary)
                        Text(EQFormat.frequencyCompact(b.frequency))
                    }
                    .font(Typo.captionRounded)
                    // An OFF band is still a selectable control, so its text needs
                    // AA contrast: secondary, not tertiary (the dashed border says "off").
                    .foregroundStyle(b.isEnabled ? (selected ? Palette.ink(layer) : Palette.textPrimary) : Palette.textSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                    .background(pill(selected: selected, enabled: b.isEnabled, layer: layer))
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Band \(i + 1), \(EQFormat.frequency(b.frequency))")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private func pill(selected: Bool, enabled: Bool, layer: EQLayer) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return shape
            .fill(selected ? Palette.stroke(layer).opacity(scheme == .dark ? 0.20 : 0.16) : Palette.textPrimary.opacity(0.04))
            .overlay(
                shape.strokeBorder(selected ? Palette.stroke(layer) : Palette.separator,
                                   style: StrokeStyle(lineWidth: selected ? 1 : 0.5, dash: enabled ? [] : [3, 2]))
            )
    }
}
