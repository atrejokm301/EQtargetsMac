//
//  GraphCanvas.swift
//  EQtargets (macOS)
//
//  The static part of the response graph: grid, axis labels and curves, drawn
//  in one Canvas (DESIGN §7.2–7.3). It is a separate view from the interactive
//  overlay so hovering a node (state that lives in the overlay) never re-runs
//  this drawing — only data changes do.
//
//  Animatable on `yMax` so the Auto scale's ±12 ↔ ±24 dB switch animates
//  (250 ms ease-in-out) instead of jumping. It only ever changes on gesture end.
//

import SwiftUI

struct CurveVisibility: Equatable {
    var target: Bool
    var fine: Bool
}

struct GraphCanvas: View, Animatable {
    var yMax: Double
    let curves: ResponseCurves
    let editing: EQLayer
    let visible: CurveVisibility
    let comparing: Bool
    let increasedContrast: Bool
    let dark: Bool

    var animatableData: Double {
        get { yMax }
        set { yMax = newValue }
    }

    var body: some View {
        Canvas { ctx, size in
            let geo = GraphGeometry(size: size, yMax: yMax)
            drawGrid(&ctx, geo)
            drawLabels(&ctx, geo)
            drawCurves(&ctx, geo)
        }
        .accessibilityHidden(true)
    }

    // MARK: Grid

    private func drawGrid(_ ctx: inout GraphicsContext, _ geo: GraphGeometry) {
        let plot = geo.plot
        let boost: Double = increasedContrast ? 1.5 : 1
        let major = Palette.textPrimary.opacity(0.10 * boost)
        let minor = Palette.textPrimary.opacity(0.05 * boost)

        var minorPath = Path()
        var majorPath = Path()
        for f in GraphGeometry.minorFrequencies {
            let x = geo.x(f).rounded() + 0.25
            minorPath.move(to: CGPoint(x: x, y: plot.minY)); minorPath.addLine(to: CGPoint(x: x, y: plot.maxY))
        }
        for f in GraphGeometry.majorFrequencies {
            let x = geo.x(f).rounded() + 0.25
            majorPath.move(to: CGPoint(x: x, y: plot.minY)); majorPath.addLine(to: CGPoint(x: x, y: plot.maxY))
        }
        // Horizontal lines from −yMax to +yMax in minor steps. yMax animates
        // through fractional values, so start at the first whole step inside.
        let steps = geo.gridSteps
        var db = -(yMax / steps.minor).rounded(.down) * steps.minor
        while db <= yMax + 0.001 {
            if abs(db) > 0.001 {
                let y = geo.y(db).rounded() + 0.25
                let isMajor = abs(db.remainder(dividingBy: steps.major)) < 0.001
                if isMajor {
                    majorPath.move(to: CGPoint(x: plot.minX, y: y)); majorPath.addLine(to: CGPoint(x: plot.maxX, y: y))
                } else {
                    minorPath.move(to: CGPoint(x: plot.minX, y: y)); minorPath.addLine(to: CGPoint(x: plot.maxX, y: y))
                }
            }
            db += steps.minor
        }
        ctx.stroke(minorPath, with: .color(minor), lineWidth: 0.5)
        ctx.stroke(majorPath, with: .color(major), lineWidth: 0.5)

        // 0 dB: the one essential line.
        var zero = Path()
        let y0 = geo.y(0).rounded() + 0.5
        zero.move(to: CGPoint(x: plot.minX, y: y0)); zero.addLine(to: CGPoint(x: plot.maxX, y: y0))
        ctx.stroke(zero, with: .color(Palette.textPrimary.opacity(0.30 * boost)), lineWidth: 1)
    }

    // MARK: Labels

    private func drawLabels(_ ctx: inout GraphicsContext, _ geo: GraphGeometry) {
        let plot = geo.plot
        let font = Font.system(size: 11, weight: .medium, design: .rounded).monospacedDigit()
        let color = Palette.textSecondary

        // dB labels right-aligned at x = 36.
        let major = geo.gridSteps.major
        var db = -(yMax / major).rounded(.down) * major
        while db <= yMax + 0.001 {
            let t = ctx.resolve(Text(EQFormat.axisGain(db)).font(font).foregroundStyle(color))
            ctx.draw(t, at: CGPoint(x: GraphGeometry.insetLeading - 8, y: geo.y(db)), anchor: .trailing)
            db += major
        }
        let unit = ctx.resolve(Text("dB").font(font).foregroundStyle(color))
        ctx.draw(unit, at: CGPoint(x: GraphGeometry.insetLeading - 8, y: plot.minY - 12), anchor: .trailing)

        // Frequency labels: drop 50/500/5k, then 200/2k, until none collide.
        var hidden = Set<Double>()
        for tier in [[]] + GraphGeometry.dropOrder {
            hidden.formUnion(tier)
            var lastMaxX = -CGFloat.infinity
            var collides = false
            for f in GraphGeometry.majorFrequencies where !hidden.contains(f) {
                let t = ctx.resolve(Text(EQFormat.axisFrequency(f)).font(font))
                let w = t.measure(in: CGSize(width: 100, height: 20)).width
                let minX = labelX(f, geo) - w / 2
                if minX < lastMaxX + 8 { collides = true; break }
                lastMaxX = minX + w
            }
            if !collides { break }
        }
        for f in GraphGeometry.majorFrequencies where !hidden.contains(f) {
            let t = ctx.resolve(Text(EQFormat.axisFrequency(f)).font(font).foregroundStyle(color))
            ctx.draw(t, at: CGPoint(x: labelX(f, geo), y: plot.maxY + 14), anchor: .center)
        }
    }

    /// End labels are pulled inward so "20" and "20k" never clip the chassis.
    private func labelX(_ f: Double, _ geo: GraphGeometry) -> CGFloat {
        let x = geo.x(f)
        if f <= 20 { return x + 6 }
        if f >= 20_000 { return x - 8 }
        return x
    }

    // MARK: Curves (z-order §7.3)

    private func drawCurves(_ ctx: inout GraphicsContext, _ geo: GraphGeometry) {
        guard !curves.isEmpty else { return }
        let plot = geo.plot
        var outer = ctx
        outer.clip(to: Path(plot))
        // Compare fades the curves as ONE transparency layer: per-stroke alpha
        // double-blends where tessellated round joins overlap (visible dots).
        if comparing { outer.opacity = 0.3 }
        outer.drawLayer { c in drawCurveLayers(&c, geo) }
        if comparing {
            var zero = Path()
            let y0 = geo.y(0)
            zero.move(to: CGPoint(x: plot.minX, y: y0)); zero.addLine(to: CGPoint(x: plot.maxX, y: y0))
            ctx.stroke(zero, with: .color(Palette.textPrimary), lineWidth: 1.5)
        }
    }

    private func drawCurveLayers(_ c: inout GraphicsContext, _ geo: GraphGeometry) {
        let widthBoost: CGFloat = increasedContrast ? 0.5 : 0
        let total = path(curves.total, geo)
        let y0 = geo.y(0)

        // 1. Total EQ fill between the curve and 0 dB (the shaded area IS the change).
        var fill = total
        if let lastF = curves.frequencies.last, let firstF = curves.frequencies.first {
            fill.addLine(to: CGPoint(x: geo.x(lastF), y: y0))
            fill.addLine(to: CGPoint(x: geo.x(firstF), y: y0))
            fill.closeSubpath()
        }
        c.fill(fill, with: .color(Palette.accentStroke.opacity(dark ? 0.18 : 0.12)))

        // 2. Total EQ line: neutral label colour (accent blue would clash with Target blue).
        c.stroke(total, with: .color(Palette.textPrimary),
                 style: StrokeStyle(lineWidth: 3 + widthBoost, lineCap: .round, lineJoin: .round))

        // 3. Non-edited layer, dashed. 4. Edited layer, solid, on top.
        let other: EQLayer = editing == .target ? .fineTune : .target
        for layer in [other, editing] {
            guard layer == .target ? visible.target : visible.fine else { continue }
            let values = layer == .target ? curves.target : curves.fine
            let p = path(values, geo)
            let stroke = layer == .fineTune && increasedContrast && !dark ? Palette.fineInk : Palette.stroke(layer)
            if layer == editing {
                c.stroke(p, with: .color(stroke), style: StrokeStyle(lineWidth: 2 + widthBoost, lineCap: .round, lineJoin: .round))
            } else {
                c.stroke(p, with: .color(stroke), style: StrokeStyle(lineWidth: 1.5 + widthBoost, lineCap: .round, lineJoin: .round, dash: [5, 4]))
            }
        }
    }

    private func path(_ values: [Double], _ geo: GraphGeometry) -> Path {
        var p = Path()
        // Points beyond the range are clamped a little outside the plot so the
        // clip, not the data, cuts them — the line leaves at the edge.
        let lo = geo.plot.minY - 4, hi = geo.plot.maxY + 4
        for (i, f) in curves.frequencies.enumerated() where i < values.count {
            let pt = CGPoint(x: geo.x(f), y: min(max(geo.y(values[i]), lo), hi))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }
}
