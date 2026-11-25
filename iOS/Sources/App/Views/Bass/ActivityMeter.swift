//
//  ActivityMeter.swift
//  EQtargets (iOS)
//
//  Live Punch / Rumble activity meter (DESIGN §8.2), fed by
//  `ChainMeters.punchBoostDB` / `punchTrimDB` through `MeterHub`.
//
//  Centre-anchored: boost / sustain grows RIGHT, trim / soften grows LEFT. Both
//  halves share one 9 dB scale, so equal lengths are equal dB. Ceiling marks show
//  where each half stops for the current style.
//
//  Battery: the meter holds a `.activity` lease ONLY while the style has
//  dynamics, the engine is running and the scene is frontmost. Any of those going
//  false cancels the `.task(id:)`, and with no leases the hub's loop is gone. The
//  30 Hz value is read only inside `MeterBar` and `MeterReadout`, so polling
//  re-renders those two leaves and nothing around them.
//

import SwiftUI

struct ActivityMeterView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.sceneIsActive) private var sceneIsActive

    var body: some View {
        let style = model.bass.style
        let status = model.displayStatus
        let live = status == .running && style.hasDynamics
        let shouldPoll = live && sceneIsActive
        let rumble = style == .sustainRumble
        let title = rumble ? "Rumble activity" : "Punch activity"

        VStack(alignment: .leading, spacing: Space.s1) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(Typo.bodySemibold).foregroundStyle(Palette.textSecondary)
                Spacer(minLength: Space.s2)
                if live { MeterReadout() }
            }
            // The idle caption is a sentence, so it gets its own line.
            if !live {
                Text(Self.idleCaption(status))
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            MeterBar(live: live, style: style)
                .frame(height: 12)
            HStack {
                Text(rumble ? "soften" : "trim")
                Spacer()
                Text(rumble ? "sustain" : "boost")
            }
            .font(Typo.caption)
            .foregroundStyle(Palette.textSecondary)
        }
        .task(id: shouldPoll) {
            guard shouldPoll else { return }
            await model.meters.hold(.activity)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .modifier(MeterAccessibilityValue(live: live))
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityIdentifier("bass.meter")
    }

    private static func idleCaption(_ status: EngineStatus) -> String {
        switch status {
        case .idle, .starting: return "Play something to see it move"
        case .waiting: return "Choose EQtargets as your output to see it move"
        case .off, .running: return "EQtargets is off"
        case .passThrough: return "EQ is off"
        case .interrupted: return "Paused"
        case .feedbackGuard: return "Muted"
        case .error: return "Not running"
        }
    }
}

// MARK: - 30 Hz leaves

private struct MeterReadout: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let meter = model.meters.activity
        Text(meter.readout)
            .font(Typo.valueBold)
            .foregroundStyle(meter.isIdle ? Palette.textSecondary : Palette.textPrimary)
            .accessibilityIdentifier("bass.meter.readout")
    }
}

private struct MeterAccessibilityValue: ViewModifier {
    let live: Bool
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.accessibilityValue(live ? model.meters.activity.accessibilityValue : "Idle")
    }
}

private struct MeterBar: View {
    let live: Bool
    let style: BassStyle

    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let barHeight: CGFloat = 8

    var body: some View {
        let meter = model.meters.activity
        let boost = live ? meter.boostFraction : 0
        let trim = live ? meter.trimFraction : 0
        let height = Self.barHeight
        let track = scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)
        GeometryReader { g in
            let half = g.size.width / 2
            let midY = g.size.height / 2
            ZStack(alignment: .topLeading) {
                Capsule().fill(track)
                    .frame(width: g.size.width, height: height)
                    .offset(y: midY - height / 2)
                // Trim: right-aligned inside the left half, grows leftward.
                Capsule().fill(Palette.textSecondary)
                    .frame(width: max(0, half * trim), height: height)
                    .offset(x: half - max(0, half * trim), y: midY - height / 2)
                // Boost: starts at centre, grows rightward.
                Capsule().fill(Palette.bassMeter)
                    .frame(width: max(0, half * boost), height: height)
                    .offset(x: half, y: midY - height / 2)
                // Centre tick: the 0 dB reference both halves move away from.
                Rectangle().fill(Palette.textPrimary.opacity(0.25))
                    .frame(width: 1, height: min(g.size.height, height + 4))
                    .offset(x: half - 0.5, y: midY - min(g.size.height, height + 4) / 2)
                if let c = MeterCeilings.ceilings(for: style) {
                    ceilingMark(x: half - half * MeterBallistics.fraction(c.left), top: midY - height / 2)
                    if c.right < MeterBallistics.fullScaleDB - 0.01 {
                        ceilingMark(x: half + half * MeterBallistics.fraction(c.right), top: midY - height / 2)
                    }
                }
            }
            .animation(reduceMotion ? nil : Motion.meter, value: boost)
            .animation(reduceMotion ? nil : Motion.meter, value: trim)
        }
    }

    private func ceilingMark(x: CGFloat, top: CGFloat) -> some View {
        Rectangle().fill(Palette.textSecondary)
            .frame(width: 1, height: 4)
            .offset(x: x - 0.5, y: top - 2)
    }
}
