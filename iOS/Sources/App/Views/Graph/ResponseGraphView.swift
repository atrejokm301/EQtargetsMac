//
//  ResponseGraphView.swift
//  EQtargets (iOS)
//
//  The response graph (DESIGN §6.2, §7). Layering:
//    chassis -> GraphCanvas (grid, labels, curves; redraws only on data change)
//            -> GraphOverlay (nodes, preamp handle, readout chip, touch)
//            -> header (legend, options, peak readout) and captions.
//
//  Curves come from `ResponseMath` at the running sample rate, so the graph stays
//  the truth about the DSP. They are cached and recomputed only when the layers,
//  the rate or the point count change. The rate comes from the model's mirror,
//  so this view does not re-render on the engine's 4 Hz stats.
//

import SwiftUI
import Accessibility

/// Last computed curves. A class held in @State so filling it is not a state
/// change (it is a memo, not data that drives rendering on its own).
@MainActor
final class CurveCache {
    private struct Key: Equatable {
        var target: EQLayerState, fine: EQLayerState, bypassed: Bool, sampleRate: Double, count: Int
    }
    private var key: Key?
    private var value = ResponseCurves()

    func curves(dual: DualEQState, sampleRate: Double, count: Int) -> ResponseCurves {
        let k = Key(target: dual.target, fine: dual.fineTune, bypassed: dual.isBypassed, sampleRate: sampleRate, count: count)
        if k != key {
            value = ResponseMath.curves(dual: dual, sampleRate: sampleRate, count: count)
            key = k
        }
        return value
    }
}

struct ResponseGraphView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cache = CurveCache()
    @State private var summaryCache = CurveCache()

    private static let radius: CGFloat = 16

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        GeometryReader { proxy in
            let size = proxy.size
            let curves = cache.curves(dual: model.dual, sampleRate: model.graphSampleRate,
                                      count: ResponseMath.pointCount(plotWidth: Double(size.width - 48)))
            let visible = curveVisibility
            let wanted = wantedYMax(curves, visible: visible)
            let yMax = model.graphFrozenYMax ?? wanted
            let geo = GraphGeometry(size: size, yMax: yMax)
            ZStack(alignment: .topLeading) {
                GraphCanvas(yMax: yMax, curves: curves, editing: model.dual.editingLayer, visible: visible,
                            comparing: model.isComparing, increasedContrast: contrast == .increased,
                            dark: scheme == .dark)
                    .animation(reduceMotion ? nil : Motion.curve, value: yMax)
                GraphOverlay(geo: geo)
                    .animation(reduceMotion ? nil : Motion.curve, value: yMax)
                // The legend lives in a fixed inset above the plot, so its text is
                // capped. Every value it shows is also in the scaled band editor,
                // and VoiceOver gets the audio graph.
                Group {
                    header(curves: curves, width: size.width)
                    captions(geo: geo)
                }
                .dynamicTypeSize(...DynamicTypeSize.xLarge)
            }
        }
        .background(shape.fill(Palette.chassis))
        .overlay(shape.strokeBorder(Palette.separator, lineWidth: contrast == .increased ? 1 : 0.5))
        .clipShape(shape)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Frequency response")
        .accessibilityValue(accessibilitySummary)
        .accessibilityIdentifier("graph")
        .accessibilityChartDescriptor(GraphChartDescriptor(dual: model.dual, sampleRate: model.graphSampleRate))
    }

    private var curveVisibility: CurveVisibility {
        let d = model.dual
        func show(_ layer: EQLayer, _ state: EQLayerState, _ userShown: Bool) -> Bool {
            // A bypassed layer is never drawn; a flat one only when it's being edited.
            userShown && !state.isBypassed && (!state.isFlat || d.editingLayer == layer)
        }
        return CurveVisibility(target: show(.target, d.target, model.showCorrectionCurve),
                               fine: show(.fineTune, d.fineTune, model.showTuningCurve))
    }

    /// Auto: +-12 dB, expanding to +-24 when any drawn curve or node passes +-11.
    private func wantedYMax(_ c: ResponseCurves, visible: CurveVisibility) -> Double {
        switch model.graphScale {
        case .twelve: return 12
        case .twentyFour: return 24
        case .auto:
            var m = ResponseMath.maxAbs(c.total)
            if visible.target { m = max(m, ResponseMath.maxAbs(c.target)) }
            if visible.fine { m = max(m, ResponseMath.maxAbs(c.fine)) }
            let l = model.layerState(model.dual.editingLayer)
            for b in l.bands { m = max(m, abs(b.gain + l.preamp)) }
            return m > 11 ? 24 : 12
        }
    }

    // MARK: Header (outside the plot, so it never collides with a node)

    private func header(curves: ResponseCurves, width: CGFloat) -> some View {
        let d = model.dual
        let peak = ResponseMath.highest(frequencies: curves.frequencies, values: curves.total)
        return VStack(spacing: 0) {
            HStack(spacing: Space.s3) {
                legendItem(.target, title: d.target.isBypassed ? "Correction (off)" : "Correction")
                legendItem(.fineTune, title: d.fineTune.isBypassed ? "Your tuning (off)" : "Your tuning")
                HStack(spacing: Space.s1) {
                    Capsule().fill(Palette.textPrimary).frame(width: 14, height: 3)
                    Text("Total")
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Total EQ")
                Spacer(minLength: 0)
                GraphOptionsMenu()
            }
            .frame(height: Space.touch)
            HStack(spacing: Space.s2) {
                Spacer(minLength: GraphGeometry.insetLeading)   // the "dB" caption lives here
                if let text = notAppliedText(model.displayStatus) {
                    Text(text)
                        .font(Typo.captionMedium)
                        .foregroundStyle(Palette.warning)
                        .accessibilityIdentifier("graph.notApplied")
                }
                Text(peak.map { "Peak \(EQFormat.gain($0.db)) \u{00B7} \(EQFormat.frequency($0.frequency))" } ?? "Flat")
                    .font(Typo.captionRounded)
                    .foregroundStyle(Palette.textSecondary)
                    .accessibilityLabel(peak.map { "Peak \(EQFormat.gain($0.db)) at \(EQFormat.frequency($0.frequency))" } ?? "Flat")
            }
            .frame(height: 16)
            .padding(.trailing, Space.s2)
        }
        .font(Typo.caption)
        .foregroundStyle(Palette.textSecondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.leading, Space.s3)
        .padding(.trailing, Space.s1)
        .frame(width: width, alignment: .leading)
    }

    private func legendItem(_ layer: EQLayer, title: String) -> some View {
        let editing = model.dual.editingLayer == layer
        return Button {
            model.selectLayer(layer)
        } label: {
            HStack(spacing: Space.s1) {
                Canvas { ctx, size in
                    var p = Path()
                    p.move(to: CGPoint(x: 0, y: size.height / 2)); p.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                    ctx.stroke(p, with: .color(Palette.stroke(layer)),
                               style: StrokeStyle(lineWidth: editing ? 2 : 1.5, lineCap: .round, dash: editing ? [] : [4, 3]))
                }
                .frame(width: 14, height: 4)
                .accessibilityHidden(true)
                Text(title)
                    .foregroundStyle(editing ? Palette.ink(layer) : Palette.textSecondary)
                    .fontWeight(editing ? .semibold : .regular)
            }
            .frame(minHeight: Space.touch)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Edits this layer")
        .accessibilityAddTraits(editing ? .isSelected : [])
    }

    // MARK: Captions

    @ViewBuilder
    private func captions(geo: GraphGeometry) -> some View {
        let plot = geo.plot
        if model.isComparing {
            CompareBanner()
                .frame(width: plot.width)
                .position(x: plot.midX, y: plot.minY + 24)
        }
        if model.dual.target.isFlat && model.dual.fineTune.isFlat && !model.isDraggingGraph && !model.isComparing {
            Text("Flat \u{2014} drag a dot to shape your sound, or import an AutoEQ file.")
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .frame(width: min(plot.width - Space.s8, 280))
                .position(x: plot.midX, y: geo.y(0) + 44)
                .allowsHitTesting(false)
        }
    }

    /// The graph stays editable in every state; this says when it isn't heard.
    private func notAppliedText(_ status: EngineStatus) -> String? {
        switch status {
        case .off, .passThrough: return "EQ off \u{2014} not applied"
        case .error: return "Not applied"
        case .waiting: return "Not selected yet"
        case .interrupted: return "Paused"
        case .feedbackGuard: return "Muted"
        case .running, .idle, .starting: return nil
        }
    }

    private var accessibilitySummary: String {
        // Its own memo (fixed 256 points) so the summary costs nothing between data changes.
        let c = summaryCache.curves(dual: model.dual, sampleRate: model.graphSampleRate, count: ResponseMath.minPoints)
        let peak = ResponseMath.highest(frequencies: c.frequencies, values: c.total)
        let p = peak.map { "Total EQ peak \(EQFormat.gain($0.db)) at \(EQFormat.frequency($0.frequency))" } ?? "Total EQ flat"
        return "Correction \(model.displayName(.correction)), Your tuning \(model.displayName(.tuning)), \(p)"
    }
}

// MARK: - Options menu

/// Scale and curve visibility: on the Mac these live in the right-click menu.
private struct GraphOptionsMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Menu {
            Picker("Scale", selection: $model.graphScale) {
                ForEach(GraphScale.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            Toggle("Show Correction Curve", isOn: $model.showCorrectionCurve)
            Toggle("Show Your Tuning Curve", isOn: $model.showTuningCurve)
        } label: {
            Image(systemName: "ellipsis")
                .font(Typo.bodySemibold)
                .foregroundStyle(Palette.textPrimary)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Palette.textPrimary.opacity(0.08)))
                .frame(width: Space.touch, height: Space.touch)
                .contentShape(Rectangle())
        }
        .menuOrder(.fixed)
        .accessibilityLabel("Graph options")
        .accessibilityIdentifier("graph.options")
    }
}

// MARK: - Compare banner

struct CompareBanner: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: Space.s2) {
            Image(systemName: "circle.lefthalf.filled")
                .foregroundStyle(Palette.textPrimary)
                .accessibilityHidden(true)
            Text("Original sound")
                .font(Typo.bodySemibold)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
            Spacer(minLength: Space.s1)
            if model.compareLatched {
                Button("Stop") { model.toggleCompareLatch() }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    .accessibilityLabel("Stop comparing")
            }
        }
        .padding(.horizontal, Space.s3)
        .frame(minHeight: 40)
        .floatingGlass(Capsule(), reduceTransparency: reduceTransparency)
        .padding(.horizontal, Space.s2)
        .accessibilityLabel("Original sound. EQ and Bass Style are off.")
    }
}

// MARK: - Audio graph for VoiceOver (§12)

struct GraphChartDescriptor: AXChartDescriptorRepresentable {
    let dual: DualEQState
    let sampleRate: Double

    func makeChartDescriptor() -> AXChartDescriptor {
        // 31 third-octave points, 20 Hz to 20 kHz.
        let freqs = (0 ..< 31).map { 20 * pow(2, Double($0) / 3) }.filter { $0 <= 20_000 }
        let rate = ResponseMath.displaySampleRate(sampleRate)
        let trig = ResponseMath.Trig(frequencies: freqs, sampleRate: rate)
        let t = ResponseMath.layerDB(dual.target, trig: trig, sampleRate: rate)
        let f = ResponseMath.layerDB(dual.fineTune, trig: trig, sampleRate: rate)
        func series(_ name: String, _ v: [Double]) -> AXDataSeriesDescriptor {
            AXDataSeriesDescriptor(name: name, isContinuous: true,
                                   dataPoints: zip(freqs, v).map { AXDataPoint(x: log10($0), y: $1) })
        }
        let x = AXNumericDataAxisDescriptor(title: "Frequency", range: log10(20) ... log10(20_000), gridlinePositions: []) {
            EQFormat.frequency(pow(10, $0))
        }
        let total = zip(t, f).map(+)
        let all = t + f + total
        let lo = min(-12, all.min() ?? 0), hi = max(12, all.max() ?? 0)
        let y = AXNumericDataAxisDescriptor(title: "Gain", range: lo ... hi, gridlinePositions: []) { EQFormat.gain($0) }
        return AXChartDescriptor(title: "Frequency response", summary: nil, xAxis: x, yAxis: y, additionalAxes: [],
                                 series: [series("Correction", t), series("Your tuning", f), series("Total EQ", total)])
    }
}
