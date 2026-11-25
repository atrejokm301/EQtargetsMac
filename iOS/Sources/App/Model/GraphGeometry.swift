//
//  GraphGeometry.swift
//  EQtargets (iOS)
//
//  Plot mapping and touch targeting for the response graph (DESIGN §7.2, §7.4).
//  Pure values, so the point-to-frequency/gain/Q rules and the hit test can be
//  tested without a touch.
//

import Foundation
import CoreGraphics

struct GraphGeometry: Equatable {
    /// Room for the legend row and the readout row, which live inside the chassis.
    static let insetTop: CGFloat = 64
    static let insetLeading: CGFloat = 36
    static let insetBottom: CGFloat = 24
    static let insetTrailing: CGFloat = 12

    static let nodeSize: CGFloat = 24
    /// 44 x 44 pt touch target around each node.
    static let hitRadius: CGFloat = 22
    /// Slim, because band 1 sits right next to it at the default 31.5 Hz.
    static let preampTab = CGSize(width: 8, height: 24)

    static let majorFrequencies: [Double] = [20, 50, 100, 200, 500, 1_000, 2_000, 5_000, 10_000, 20_000]
    static let minorFrequencies: [Double] =
        [30, 40, 60, 70, 80, 90, 300, 400, 600, 700, 800, 900, 3_000, 4_000, 6_000, 7_000, 8_000, 9_000]
    /// Labels that always stay; the rest drop in this order as width shrinks (§7.2).
    static let dropOrder: [[Double]] = [[50, 500, 5_000], [200, 2_000]]

    let size: CGSize
    /// Half-range of the Y axis in dB (12 or 24).
    let yMax: Double

    var plot: CGRect {
        CGRect(x: Self.insetLeading, y: Self.insetTop,
               width: max(1, size.width - Self.insetLeading - Self.insetTrailing),
               height: max(1, size.height - Self.insetTop - Self.insetBottom))
    }

    func x(_ f: Double) -> CGFloat {
        plot.minX + CGFloat(FrequencyResponse.xPosition(f)) * plot.width
    }

    func y(_ db: Double) -> CGFloat {
        plot.midY - CGFloat(db / yMax) * plot.height / 2
    }

    /// Unclamped inverse of `x` (callers clamp to the model range).
    func frequency(atX px: CGFloat) -> Double {
        let t = Double((px - plot.minX) / plot.width)
        return 20 * pow(1_000, t)
    }

    func db(atY py: CGFloat) -> Double {
        Double((plot.midY - py) / (plot.height / 2)) * yMax
    }

    /// Visible node position: data is never nudged, only clamped to the plot so
    /// an out-of-range node stays grabbable on the edge.
    func nodePoint(frequency f: Double, db: Double) -> CGPoint {
        CGPoint(x: x(f), y: min(max(y(db), plot.minY), plot.maxY))
    }

    func preampTabRect(preamp: Double) -> CGRect {
        let cy = min(max(y(preamp), plot.minY), plot.maxY)
        return CGRect(x: plot.minX, y: cy - Self.preampTab.height / 2,
                      width: Self.preampTab.width, height: Self.preampTab.height)
    }

    /// dB grid: (major step, minor step).
    var gridSteps: (major: Double, minor: Double) { yMax > 12.5 ? (12, 6) : (6, 3) }

    // MARK: Drag and pinch mapping

    /// A drag lands exactly on 0 dB within this distance.
    static let zeroSnapDB = 0.3

    /// What a dragged node's position means for its band. `preamp` is removed
    /// because a node rides its own curve (y = gain + preamp).
    func bandValues(at p: CGPoint, preamp: Double) -> (frequency: Double, gain: Double, snapped: Bool) {
        let f = min(max(frequency(atX: p.x), EQBand.frequencyRange.lowerBound), EQBand.frequencyRange.upperBound)
        var g = db(atY: p.y) - preamp
        let snapped = abs(g) <= Self.zeroSnapDB
        if snapped { g = 0 }
        g = min(max(g, EQBand.gainRange.lowerBound), EQBand.gainRange.upperBound)
        return (f, (g * 100).rounded() / 100, snapped)
    }

    /// What the dragged preamp handle's position means.
    func preampValue(atY py: CGFloat) -> Double {
        var p = db(atY: py)
        if abs(p) <= Self.zeroSnapDB { p = 0 }
        p = min(max(p, EQLayerState.preampRange.lowerBound), EQLayerState.preampRange.upperBound)
        return (p * 10).rounded() / 10
    }

    /// Spreading the fingers widens the bell: Q = start / scale.
    static func pinchedQ(start: Double, scale: CGFloat) -> Double {
        let q = start / max(0.05, Double(scale))
        let clamped = min(max(q, EQBand.qRange.lowerBound), EQBand.qRange.upperBound)
        return (clamped * 100).rounded() / 100
    }
}

enum GraphTarget: Equatable {
    case band(Int)
    case preamp
}

enum GraphHitTest {
    /// How much closer another node must be to beat the selected one. Without a
    /// bias, a stack of nodes could never keep its selection; with the Mac's
    /// strict "selected first", a 44 pt target would steal touches aimed at the
    /// neighbouring node, which sits about 30 pt away on a phone.
    static let selectedBias: CGFloat = 8

    /// What a touch means: the nearest centre within the touch radius, favouring
    /// the selected band. The preamp handle competes on distance like a node. If
    /// bands always won, band 1's target would cover the handle at the default
    /// 31.5 Hz and it could never be grabbed.
    static func target(at p: CGPoint, nodes: [CGPoint], selected: Int?, preampTab: CGRect,
                       radius: CGFloat = GraphGeometry.hitRadius) -> GraphTarget? {
        let reachable = candidates(at: p, nodes: nodes, radius: radius)
        let tabDistance = distance(p, CGPoint(x: preampTab.midX, y: preampTab.midY))
        guard let nearest = reachable.min(by: { distance(p, nodes[$0]) < distance(p, nodes[$1]) }) else {
            return tabDistance <= radius ? .preamp : nil
        }
        if tabDistance < distance(p, nodes[nearest]) { return .preamp }
        if let selected, reachable.contains(selected),
           distance(p, nodes[selected]) - selectedBias <= distance(p, nodes[nearest]) {
            return .band(selected)
        }
        return .band(nearest)
    }

    /// Every node whose touch target contains the point.
    static func candidates(at p: CGPoint, nodes: [CGPoint],
                           radius: CGFloat = GraphGeometry.hitRadius) -> [Int] {
        nodes.indices.filter { distance(p, nodes[$0]) <= radius }
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}

/// Log-scaled slider mapping. Frequency and Q are heard in ratios, so a linear
/// slider would spend most of its travel on the top octave.
enum LogScale {
    static func unit(_ value: Double, in range: ClosedRange<Double>) -> Double {
        let v = min(max(value, range.lowerBound), range.upperBound)
        return log(v / range.lowerBound) / log(range.upperBound / range.lowerBound)
    }

    static func value(_ unit: Double, in range: ClosedRange<Double>) -> Double {
        let t = min(max(unit, 0), 1)
        let v = range.lowerBound * pow(range.upperBound / range.lowerBound, t)
        return min(max(v, range.lowerBound), range.upperBound)
    }
}
