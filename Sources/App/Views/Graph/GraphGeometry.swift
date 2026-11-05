//
//  GraphGeometry.swift
//  EQtargets (macOS)
//
//  Plot mapping for the response graph (DESIGN §7.2). One coordinate system
//  for the whole chassis: the header row lives in the top inset, dB labels in
//  the leading inset, frequency labels in the bottom inset.
//

import Foundation
import CoreGraphics

struct GraphGeometry: Equatable {
    static let insetTop: CGFloat = 36
    static let insetLeading: CGFloat = 44
    static let insetBottom: CGFloat = 28
    static let insetTrailing: CGFloat = 16

    static let nodeSize: CGFloat = 20
    static let hitRadius: CGFloat = 14      // 28 × 28 hit area
    static let preampTab = CGSize(width: 14, height: 20)

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

    /// Visible node position: data never nudged, only clamped to the plot so
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
}
