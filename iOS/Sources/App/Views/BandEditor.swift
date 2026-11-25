//
//  BandEditor.swift
//  EQtargets (iOS)
//
//  Band pills plus the editor for the selected band of the edited layer, and
//  that layer's preamp (DESIGN §6.3). Exact numbers, forgiving input, one undo
//  step per committed field or slider drag.
//
//  Frequency and Q sliders are log-scaled, because both are heard in ratios.
//

import SwiftUI
import UIKit

struct BandEditorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let layer = model.dual.editingLayer
        let i = model.selectedBandIndex
        let band = model.band(i)
        let tint = Palette.stroke(layer)
        VStack(alignment: .leading, spacing: Space.s3) {
            BandStrip()

            HStack(spacing: Space.s1) {
                Text("Band \(i + 1)")
                    .font(Typo.title)
                    .foregroundStyle(Palette.ink(layer))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: Space.s2)
                Toggle(isOn: Binding(get: { band.isEnabled }, set: { model.setBandEnabled(i, $0) })) {
                    Text("Band \(i + 1) on")
                }
                .toggleStyle(PillSwitchStyle(tint: tint))
                .accessibilityIdentifier("band.on")
                bandMenu(i)
            }

            TypeChips(selection: band.filterType, tint: tint, onTint: Palette.onFill(layer)) {
                model.setBandType(i, $0)
            }

            frequencyRow(i, layer, band, tint)
            gainRow(i, layer, band, tint)
            qRow(i, layer, band, tint)

            Divider()

            preampRow(layer)
        }
        .eqtCard()
    }

    /// One identity per (layer, band, field): switching band or layer gives the
    /// field fresh text, and a late commit still targets the band it was typed for.
    private func fieldID(_ layer: EQLayer, _ band: Int?, _ field: String) -> String {
        "\(layer == .target ? "target" : "fineTune")-\(band.map(String.init) ?? "layer")-\(field)"
    }

    private func editing(_ active: Bool, name: String, owner: String) {
        if active {
            model.beginGesture(owner: owner, name: name)
        } else {
            model.endGesture(name, owner: owner)
        }
    }

    // MARK: Rows

    private func frequencyRow(_ i: Int, _ layer: EQLayer, _ band: EQBand, _ tint: Color) -> some View {
        let name = "Move Band \(i + 1)"
        let range = EQBand.frequencyRange
        return ParameterRow(title: "Frequency", valueText: EQFormat.frequency(band.frequency), tint: tint,
                            sliderValue: Binding(
                                get: { LogScale.unit(model.band(i, layer: layer).frequency, in: range) },
                                set: { t in
                                    let f = Self.threeSignificant(LogScale.value(t, in: range))
                                    model.updateBand(i, layer: layer) { $0.frequency = f }
                                }),
                            sliderRange: 0 ... 1,
                            onEditing: { editing($0, name: name, owner: fieldID(layer, i, "freq-slider")) },
                            onMoved: { model.resumeGesture(owner: fieldID(layer, i, "freq-slider"), name: name) }) {
            ValueField(label: "Frequency", value: band.frequency, format: EQFormat.frequency,
                       parse: NumberEntry.parseFrequency, range: range,
                       step: { v, d in v * pow(2, d / 12) }) { v in
                model.commitBandField(i, layer: layer, name: name) { $0.frequency = v }
            }
            .id(fieldID(layer, i, "freq"))
        }
        // A slider held while the band or layer changes must end, not retarget.
        .id(fieldID(layer, i, "freq-row"))
    }

    private func gainRow(_ i: Int, _ layer: EQLayer, _ band: EQBand, _ tint: Color) -> some View {
        let name = "Move Band \(i + 1)"
        return ParameterRow(title: "Gain", valueText: EQFormat.gain(band.gain), tint: tint,
                            sliderValue: Binding(
                                get: { model.band(i, layer: layer).gain },
                                set: { g in
                                    let v = (g * 10).rounded() / 10
                                    model.updateBand(i, layer: layer) { $0.gain = v }
                                }),
                            sliderRange: EQBand.gainRange,
                            onEditing: { editing($0, name: name, owner: fieldID(layer, i, "gain-slider")) },
                            onMoved: { model.resumeGesture(owner: fieldID(layer, i, "gain-slider"), name: name) }) {
            ValueField(label: "Gain", value: band.gain, format: EQFormat.gain, parse: NumberEntry.parseGain,
                       range: EQBand.gainRange,
                       step: { v, d in ((v + d * 0.5) * 10).rounded() / 10 }) { v in
                model.commitBandField(i, layer: layer, name: name) { $0.gain = v }
            }
            .id(fieldID(layer, i, "gain"))
        }
        // A slider held while the band or layer changes must end, not retarget.
        .id(fieldID(layer, i, "gain-row"))
    }

    private func qRow(_ i: Int, _ layer: EQLayer, _ band: EQBand, _ tint: Color) -> some View {
        let range = EQBand.qRange
        return ParameterRow(title: "Q", valueText: EQFormat.q(band.q), tint: tint,
                            sliderValue: Binding(
                                get: { LogScale.unit(model.band(i, layer: layer).q, in: range) },
                                set: { t in
                                    let q = (LogScale.value(t, in: range) * 100).rounded() / 100
                                    model.updateBand(i, layer: layer) { $0.q = q }
                                }),
                            sliderRange: 0 ... 1,
                            onEditing: { editing($0, name: "Change Q", owner: fieldID(layer, i, "q-slider")) },
                            onMoved: { model.resumeGesture(owner: fieldID(layer, i, "q-slider"), name: "Change Q") }) {
            ValueField(label: "Q", value: band.q, format: EQFormat.q, parse: NumberEntry.parseQ,
                       range: range,
                       step: { v, d in v * pow(2, d / 6) }) { v in
                model.commitBandField(i, layer: layer, name: "Change Q") { $0.q = v }
            }
            .id(fieldID(layer, i, "q"))
        }
        // A slider held while the band or layer changes must end, not retarget.
        .id(fieldID(layer, i, "q-row"))
    }

    private func preampRow(_ layer: EQLayer) -> some View {
        let title = layer == .target ? "Correction preamp" : "Tuning preamp"
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: Space.s2) {
                Text(title).font(Typo.body).foregroundStyle(Palette.textSecondary).lineLimit(1)
                Spacer(minLength: 0)
                preampField(layer, title)
                autoButton(layer)
            }
            VStack(alignment: .leading, spacing: Space.s1) {
                Text(title).font(Typo.body).foregroundStyle(Palette.textSecondary)
                HStack(spacing: Space.s2) {
                    preampField(layer, title)
                    Spacer(minLength: 0)
                    autoButton(layer)
                }
            }
        }
    }

    private func preampField(_ layer: EQLayer, _ title: String) -> some View {
        ValueField(label: title, value: model.layerState(layer).preamp, format: EQFormat.gain,
                   parse: NumberEntry.parseGain, range: EQLayerState.preampRange,
                   step: { v, d in ((v + d * 0.5) * 10).rounded() / 10 }) { v in
            model.commitPreamp(v, layer: layer)
        }
        .id(fieldID(layer, nil, "preamp"))
    }

    private func autoButton(_ layer: EQLayer) -> some View {
        Button("Auto") { model.autoPreamp(layer: layer) }
            .buttonStyle(PillButtonStyle())
            .accessibilityLabel("Set preamp automatically")
            .accessibilityIdentifier("band.autoPreamp")
    }

    private func bandMenu(_ i: Int) -> some View {
        Menu {
            Button { model.resetBandGain(i) } label: {
                Label("Reset Gain", systemImage: "arrow.counterclockwise")
            }
            Button { model.resetBand(i) } label: {
                Label("Reset Band", systemImage: "arrow.uturn.backward")
            }
            Button { UIPasteboard.general.string = model.bandValuesText(i) } label: {
                Label("Copy Band Values", systemImage: "doc.on.doc")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(Typo.bodySemibold)
                .foregroundStyle(Palette.textPrimary)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Palette.textPrimary.opacity(0.08)))
                .frame(width: Space.touch, height: Space.touch)
                .contentShape(Rectangle())
        }
        .menuOrder(.fixed)
        .accessibilityLabel("Band \(i + 1) actions")
        .accessibilityIdentifier("band.menu")
    }

    /// `1234.5` becomes `1230`: slider travel shouldn't produce noise digits.
    private static func threeSignificant(_ f: Double) -> Double {
        guard f > 0 else { return f }
        let magnitude = pow(10, floor(log10(f)) - 2)
        return (f / magnitude).rounded() * magnitude
    }
}

// MARK: - Parameter row

private struct ParameterRow<Field: View>: View {
    let title: String
    let valueText: String
    let tint: Color
    @Binding var sliderValue: Double
    let sliderRange: ClosedRange<Double>
    let onEditing: (Bool) -> Void
    let onMoved: () -> Void
    @ViewBuilder let field: () -> Field

    init(title: String, valueText: String, tint: Color, sliderValue: Binding<Double>,
         sliderRange: ClosedRange<Double>, onEditing: @escaping (Bool) -> Void,
         onMoved: @escaping () -> Void, @ViewBuilder field: @escaping () -> Field) {
        self.title = title
        self.valueText = valueText
        self.tint = tint
        _sliderValue = sliderValue
        self.sliderRange = sliderRange
        self.onEditing = onEditing
        self.onMoved = onMoved
        self.field = field
    }

    @State private var isDragging = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Space.s2) {
                    Text(title).font(Typo.body).foregroundStyle(Palette.textSecondary).lineLimit(1)
                    Spacer(minLength: Space.s2)
                    field()
                }
                VStack(alignment: .leading, spacing: Space.s1) {
                    Text(title).font(Typo.body).foregroundStyle(Palette.textSecondary)
                    field()
                }
            }
            Slider(value: Binding(get: { sliderValue }, set: { v in
                if isDragging { onMoved() }     // reopens a step another finger closed
                sliderValue = v
            }), in: sliderRange, onEditingChanged: { editing in
                isDragging = editing
                onEditing(editing)
            })
                .tint(tint)
                .labelsHidden()
                .frame(minHeight: Space.touch)
                .accessibilityLabel("\(title) slider")
                .accessibilityValue(valueText)
                // Removed mid-drag, it never reports the end.
                .onDisappear {
                    guard isDragging else { return }
                    isDragging = false
                    onEditing(false)
                }
        }
    }
}

// MARK: - Type chips

private struct TypeChips: View {
    let selection: EQFilterType
    let tint: Color
    let onTint: Color
    let onSelect: (EQFilterType) -> Void

    var body: some View {
        // One row while the labels fit, stacked at the largest text sizes.
        ViewThatFits(in: .horizontal) {
            EqualWidthHStack(spacing: Space.s1) { chips }
            VStack(spacing: Space.s1) { chips }
        }
    }

    private var chips: some View {
        ForEach(EQFilterType.allCases) { type in
            let selected = type == selection
            Button {
                onSelect(type)
            } label: {
                Text(type.title)
                    .font(Typo.captionSemibold)
                    .foregroundStyle(selected ? onTint : Palette.textPrimary)
                    .lineLimit(1)
                    .padding(.horizontal, Space.s2)
                    .padding(.vertical, Space.s1)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 32)
                    .background(Capsule().fill(selected ? tint : Palette.textPrimary.opacity(0.08)))
                    .frame(minHeight: Space.touch)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel(type.title)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("band.type.\(type.rawValue)")
        }
    }
}

// MARK: - Band strip

private struct BandStrip: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let layer = model.dual.editingLayer
        let bands = model.layerState(layer).bands
        let selectedIndex = model.selectedBandIndex
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.s1) {
                    ForEach(bands.indices, id: \.self) { i in
                        pill(i, bands[i], layer: layer, selected: selectedIndex == i).id(i)
                    }
                }
            }
            // Pills run to the card's edges instead of being cut inside its padding.
            .contentMargins(.horizontal, Space.s4, for: .scrollContent)
            .padding(.horizontal, -Space.s4)
            .onChange(of: selectedIndex) { _, index in
                if reduceMotion { proxy.scrollTo(index, anchor: .center) }
                else { withAnimation(Motion.select) { proxy.scrollTo(index, anchor: .center) } }
            }
            .onAppear { proxy.scrollTo(selectedIndex, anchor: .center) }
        }
        .sensoryFeedback(.selection, trigger: selectedIndex)
    }

    private func pill(_ i: Int, _ b: EQBand, layer: EQLayer, selected: Bool) -> some View {
        Button {
            model.selectBand(i)
        } label: {
            HStack(spacing: 3) {
                Text("\(i + 1)").fontWeight(.semibold)
                if b.filterType != .peak {
                    Image(systemName: b.filterType == .lowShelf ? "arrow.down.to.line" : "arrow.up.to.line")
                        .font(.caption2.weight(.semibold))
                        .accessibilityHidden(true)
                }
                Text("\u{00B7}").foregroundStyle(Palette.textSecondary)
                Text(EQFormat.frequencyCompact(b.frequency))
            }
            .font(Typo.captionRounded)
            // An OFF band is still a selectable control, so its text keeps AA
            // contrast: secondary, not tertiary (the dashed border says "off").
            .foregroundStyle(b.isEnabled ? (selected ? Palette.ink(layer) : Palette.textPrimary) : Palette.textSecondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, Space.s3)
            .padding(.vertical, Space.s1)
            .frame(minHeight: 34)
            .background(pillBackground(selected: selected, enabled: b.isEnabled, layer: layer))
            .frame(minHeight: Space.touch)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("Band \(i + 1), \(EQFormat.spokenFrequency(b.frequency))\(b.isEnabled ? "" : ", off")")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("band.pill.\(i + 1)")
    }

    private func pillBackground(selected: Bool, enabled: Bool, layer: EQLayer) -> some View {
        Capsule()
            .fill(selected ? Palette.stroke(layer).opacity(scheme == .dark ? 0.20 : 0.14)
                           : Palette.textPrimary.opacity(0.05))
            .overlay(
                Capsule().strokeBorder(selected ? Palette.stroke(layer) : Palette.separator,
                                       style: StrokeStyle(lineWidth: selected ? 1 : 0.5, dash: enabled ? [] : [3, 2]))
            )
    }
}
