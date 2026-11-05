//
//  ResponseGraphView.swift
//  EQtargets (macOS)
//
//  The response graph (DESIGN §6.2, §7). Layering:
//    chassis → GraphCanvas (grid, labels, curves; redraws only on data change)
//            → GraphOverlay (nodes, preamp handle, readout chip, gestures; owns
//              hover/drag state so hovering never redraws the canvas)
//            → header (legend + peak readout) and caption chips.
//
//  Curves are cached: recomputed only when the layers, the running sample rate
//  or the point count change — never for hover, selection or meter updates.
//

import SwiftUI
import AppKit
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
    private(set) var computeCount = 0

    func curves(dual: DualEQState, sampleRate: Double, count: Int) -> ResponseCurves {
        let k = Key(target: dual.target, fine: dual.fineTune, bypassed: dual.isBypassed, sampleRate: sampleRate, count: count)
        if k != key {
            value = ResponseMath.curves(dual: dual, sampleRate: sampleRate, count: count)
            key = k
            computeCount += 1
        }
        return value
    }
}

struct ResponseGraphView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var cache = CurveCache()
    @State private var summaryCache = CurveCache()
    @FocusState private var focused: Bool

    var body: some View {
        let display = model.display
        GeometryReader { proxy in
            let size = proxy.size
            let curves = cache.curves(dual: model.dual, sampleRate: display.graphSampleRate,
                                      count: ResponseMath.pointCount(plotWidth: Double(size.width - 60)))
            let visible = curveVisibility
            let wanted = wantedYMax(curves, visible: visible)
            let yMax = model.graphFrozenYMax ?? wanted
            let geo = GraphGeometry(size: size, yMax: yMax)
            ZStack(alignment: .topLeading) {
                GraphCanvas(yMax: yMax, curves: curves, editing: model.dual.editingLayer, visible: visible,
                            comparing: model.isComparing, increasedContrast: contrast == .increased,
                            dark: scheme == .dark)
                    .animation(reduceMotion ? nil : Motion.curve, value: yMax)
                GraphOverlay(geo: geo, wantedYMax: wanted)
                    .animation(reduceMotion ? nil : Motion.curve, value: yMax)
                header(curves: curves, visible: visible, width: size.width)
                captions(geo: geo)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.chassis)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(focused ? Palette.accentStroke.opacity(0.6) : Palette.separator,
                              lineWidth: focused ? 2 : (contrast == .increased ? 1 : 0.5))
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in handleKey(press) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Frequency response")
        .accessibilityValue(accessibilitySummary)
        .accessibilityChartDescriptor(GraphChartDescriptor(dual: model.dual, sampleRate: display.graphSampleRate))
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

    /// Auto: ±12 dB, expanding to ±24 when any drawn curve or node passes ±11.
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

    // MARK: Header (legend left, readout right — outside the plot, never collides)

    private func header(curves: ResponseCurves, visible: CurveVisibility, width: CGFloat) -> some View {
        let d = model.dual
        let peak = ResponseMath.highest(frequencies: curves.frequencies, values: curves.total)
        return HStack(spacing: Space.s4) {
            legendItem(.target, title: d.target.isBypassed ? "Correction (off)" : "Correction")
            legendItem(.fineTune, title: d.fineTune.isBypassed ? "Your tuning (off)" : "Your tuning")
            HStack(spacing: 6) {
                Capsule().fill(Palette.textPrimary).frame(width: 16, height: 3)
                Text("Total EQ")
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: Space.s2)
            Text(peak.map { "Peak \(EQFormat.gain($0.db)) \u{00B7} \(EQFormat.frequency($0.frequency))" } ?? "Flat")
                .font(Typo.captionRounded)
                .foregroundStyle(Palette.textSecondary)
                .accessibilityLabel(peak.map { "Peak \(EQFormat.gain($0.db)) at \(EQFormat.frequency($0.frequency))" } ?? "Flat")
        }
        .font(Typo.caption)
        .foregroundStyle(Palette.textSecondary)
        .lineLimit(1)
        .padding(.leading, GraphGeometry.insetLeading)
        .padding(.trailing, GraphGeometry.insetTrailing)
        .frame(width: width, height: 24, alignment: .leading)
        .padding(.top, 6)
    }

    private func legendItem(_ layer: EQLayer, title: String) -> some View {
        let editing = model.dual.editingLayer == layer
        return Button {
            model.selectLayer(layer)
        } label: {
            HStack(spacing: 6) {
                Canvas { ctx, size in
                    var p = Path()
                    p.move(to: CGPoint(x: 0, y: size.height / 2)); p.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                    ctx.stroke(p, with: .color(Palette.stroke(layer)),
                               style: StrokeStyle(lineWidth: editing ? 2 : 1.5, lineCap: .round, dash: editing ? [] : [5, 4]))
                }
                .frame(width: 16, height: 4)
                Text(title)
                    .foregroundStyle(editing ? Palette.ink(layer) : Palette.textSecondary)
                    .fontWeight(editing ? .semibold : .regular)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(layer == .target ? "Edit headphone correction (\u{2318}1)" : "Edit your tuning (\u{2318}2)")
        .accessibilityAddTraits(editing ? .isSelected : [])
    }

    // MARK: Captions

    @ViewBuilder
    private func captions(geo: GraphGeometry) -> some View {
        let display = model.display
        let plot = geo.plot
        if model.isComparing {
            CompareBanner()
                .frame(width: plot.width)
                .position(x: plot.midX, y: plot.minY + 22)
        } else if let text = notAppliedText(display.status) {
            Text(text)
                .font(Typo.captionMedium)
                .foregroundStyle(Palette.textSecondary)
                .padding(.horizontal, Space.s2)
                .padding(.vertical, 3)
                .background(Capsule().fill(Palette.textPrimary.opacity(0.06)))
                .fixedSize()
                .frame(width: plot.width - 16, alignment: .trailing)
                .position(x: plot.midX, y: plot.minY + 16)
                .allowsHitTesting(false)
        }
        if model.dual.target.isFlat && model.dual.fineTune.isFlat && !model.isDraggingGraph {
            Text("Flat \u{2014} drag a dot to shape your sound, or drop an AutoEQ file here.")
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .frame(width: min(plot.width - 32, 420))
                .position(x: plot.midX, y: geo.y(0) + 40)
                .allowsHitTesting(false)
        }
    }

    private func notAppliedText(_ status: EngineStatus) -> String? {
        switch status {
        case .driverMissing: return "Not applied \u{2014} driver not installed"
        case .off, .error: return "Off \u{2014} not applied"
        case .running, .idle, .starting: return nil
        }
    }

    // MARK: Keyboard (§6.2) — graph focused, acts on the selected band

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let fine = press.modifiers.contains(.option)
        let coarse = press.modifiers.contains(.shift)
        let i = model.selectedBandIndex
        let name = "Move Band \(i + 1)"
        if press.modifiers.contains(.command) { return .ignored }
        switch press.key {
        case .leftArrow, .rightArrow:
            let k = pow(2, 1 / (fine ? 96.0 : coarse ? 3.0 : 24.0))
            let up = press.key == .rightArrow
            model.perform(name) { model.updateBand(i) { $0.frequency = up ? $0.frequency * k : $0.frequency / k } }
            model.selectBand(i)
            return .handled
        case .upArrow, .downArrow:
            let step = fine ? 0.1 : coarse ? 3 : 0.5
            let d = press.key == .upArrow ? step : -step
            model.perform(name) { model.updateBand(i) { $0.gain = (($0.gain + d) * 10).rounded() / 10 } }
            model.selectBand(i)
            return .handled
        case .escape:
            model.selectBand(nil)
            return .handled
        default:
            break
        }
        switch press.characters {
        case "[", "]":
            let k = pow(2, 1 / (fine ? 24.0 : 6.0))
            let narrower = press.characters == "]"
            model.perform("Change Q") { model.updateBand(i) { $0.q = narrower ? $0.q * k : $0.q / k } }
            return .handled
        case "1", "2", "3", "4", "5", "6", "7", "8", "9", "0":
            let n = Int(press.characters) ?? 1
            model.selectBand(n == 0 ? 9 : n - 1)
            return .handled
        default:
            return .ignored
        }
    }

    private var accessibilitySummary: String {
        // Its own memo (fixed 256 points) so the summary costs nothing between data changes.
        let c = summaryCache.curves(dual: model.dual, sampleRate: model.display.graphSampleRate, count: ResponseMath.minPoints)
        let peak = ResponseMath.highest(frequencies: c.frequencies, values: c.total)
        let p = peak.map { String(format: "Total EQ peak %@ at %@", EQFormat.gain($0.db), EQFormat.frequency($0.frequency)) } ?? "Total EQ flat"
        return "Correction \(model.displayName(.correction)), Your tuning \(model.displayName(.tuning)), \(p)"
    }
}

// MARK: - Compare banner

struct CompareBanner: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: Space.s2) {
            // The text colour is set on the label only, NOT on the HStack: a
            // forced foreground leaks into the system button and overrides the
            // label colour the system pairs with its bezel. On glass in dark
            // mode that rendered white text on a light bezel (integration QA,
            // snapshot 05-main-compare-dark).
            Group {
                Image(systemName: "circle.lefthalf.filled")
                Text("Original sound \u{2014} EQ and Bass Style are off")
                    .font(Typo.bodySemibold)
            }
            .foregroundStyle(Palette.textPrimary)
            Spacer(minLength: Space.s2)
            if model.compareLatched {
                Button("Stop Comparing") { model.toggleCompareLatch() }
                    .help("Stop comparing (\u{2318}B)")
            }
        }
        .padding(.horizontal, Space.s3)
        .padding(.vertical, 6)
        .floatingGlass(RoundedRectangle(cornerRadius: 10, style: .continuous), reduceTransparency: reduceTransparency)
        .padding(.horizontal, Space.s2)
    }
}

// MARK: - Audio graph for VoiceOver (§12)

struct GraphChartDescriptor: AXChartDescriptorRepresentable {
    let dual: DualEQState
    let sampleRate: Double

    func makeChartDescriptor() -> AXChartDescriptor {
        // 31 third-octave points, 20 Hz … 20 kHz.
        let freqs = (0 ..< 31).map { 20 * pow(2, Double($0) / 3) }.filter { $0 <= 20_000 }
        let trig = ResponseMath.Trig(frequencies: freqs, sampleRate: ResponseMath.displaySampleRate(sampleRate))
        let t = ResponseMath.layerDB(dual.target, trig: trig, sampleRate: sampleRate)
        let f = ResponseMath.layerDB(dual.fineTune, trig: trig, sampleRate: sampleRate)
        func series(_ name: String, _ v: [Double]) -> AXDataSeriesDescriptor {
            AXDataSeriesDescriptor(name: name, isContinuous: true,
                                   dataPoints: zip(freqs, v).map { AXDataPoint(x: log10($0), y: $1) })
        }
        let x = AXNumericDataAxisDescriptor(title: "Frequency", range: log10(20) ... log10(20_000), gridlinePositions: []) {
            EQFormat.frequency(pow(10, $0))
        }
        let all = t + f + zip(t, f).map(+)
        let lo = min(-12, all.min() ?? 0), hi = max(12, all.max() ?? 0)
        let y = AXNumericDataAxisDescriptor(title: "Gain", range: lo ... hi, gridlinePositions: []) { EQFormat.gain($0) }
        return AXChartDescriptor(title: "Frequency response", summary: nil, xAxis: x, yAxis: y, additionalAxes: [],
                                 series: [series("Correction", t), series("Your tuning", f), series("Total EQ", zip(t, f).map(+))])
    }
}
