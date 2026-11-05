//
//  ActivityMeter.swift
//  EQtargets (macOS)
//
//  Live Punch / Rumble activity meter (DESIGN §8.2), fed by
//  `ChainMeters.punchBoostDB` / `punchTrimDB` through `MeterHub`.
//
//  Centre-anchored: boost / sustain grows RIGHT, trim / soften grows LEFT,
//  because the two halves of the stage pull the low band in opposite directions
//  and the contrast between them is the point of the style. Both halves share
//  one 9 dB scale (Punch's attack ceiling, the largest of the four), so equal
//  lengths are equal dB on both sides and across styles. Ceiling marks show
//  where each half stops for the current style — the bar can never pass them.
//
//  Polling: the meter holds a `.activity` lease on the hub ONLY while the style
//  has dynamics, the engine is running, and its window is on screen. Any of
//  those going false cancels the `.task(id:)`, which releases the lease; with
//  no leases the hub's loop is gone (zero wakeups).
//

import SwiftUI

/// Whether the hosting window is on screen (set by the window roots).
private struct WindowVisibleKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var windowIsVisible: Bool {
        get { self[WindowVisibleKey.self] }
        set { self[WindowVisibleKey.self] = newValue }
    }
}

struct ActivityMeterView: View {
    enum Size { case full, mini }
    var size: Size = .full

    @Environment(AppModel.self) private var model
    @Environment(\.windowIsVisible) private var windowVisible
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let style = model.bass.style
        let display = model.display
        let live = display.isRunning && style.hasDynamics
        let shouldPoll = live && windowVisible
        let meter = model.meters.activity
        let rumble = style == .sustainRumble
        let title = rumble ? "Rumble activity" : "Punch activity"

        Group {
            if size == .full {
                VStack(alignment: .leading, spacing: Space.s1) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(title).font(Typo.bodySemibold).foregroundStyle(Palette.textSecondary)
                        Spacer(minLength: Space.s2)
                        if live { readout(live: true, meter: meter, status: display.status, font: Typo.valueBold) }
                    }
                    // The idle caption is a sentence; it gets its own line so
                    // it never truncates against the title at inspector width.
                    if !live { readout(live: false, meter: meter, status: display.status, font: Typo.valueBold) }
                    bar(meter: live ? meter : nil, style: style, height: 8, marks: true)
                        .frame(height: 12)
                    HStack {
                        Text(rumble ? "soften" : "trim")
                        Spacer()
                        Text(rumble ? "sustain" : "boost")
                    }
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                }
            } else {
                HStack(spacing: Space.s2) {
                    bar(meter: live ? meter : nil, style: style, height: 4, marks: false)
                        .frame(width: 120, height: 8)
                    readout(live: live, meter: meter, status: display.status, font: Typo.captionRounded)
                        .frame(minWidth: 52, alignment: .leading)
                }
            }
        }
        .task(id: shouldPoll) {
            guard shouldPoll else { return }
            await model.meters.hold(.activity)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(live ? meter.accessibilityValue : "Idle")
        .accessibilityAddTraits(.updatesFrequently)
    }

    @ViewBuilder
    private func readout(live: Bool, meter: MeterBallistics, status: EngineStatus, font: Font) -> some View {
        if live {
            Text(meter.readout)
                .font(font)
                .foregroundStyle(meter.isIdle ? Palette.textSecondary : Palette.textPrimary)
        } else {
            Text(idleCaption(status))
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(idleCaption(status))
        }
    }

    private func idleCaption(_ status: EngineStatus) -> String {
        switch status {
        case .driverMissing: return "Driver not installed"
        case .idle, .starting: return "Play something to see it move"
        case .off, .error, .running: return "EQtargets is off"
        }
    }

    private func bar(meter: MeterBallistics?, style: BassStyle, height: CGFloat, marks: Bool) -> some View {
        let boost = meter?.boostFraction ?? 0
        let trim = meter?.trimFraction ?? 0
        let track = scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)
        let boostFill: AnyShapeStyle = scheme == .dark
            ? AnyShapeStyle(LinearGradient(colors: [Palette.bassMeter.opacity(0.75), Palette.bassMeter],
                                           startPoint: .leading, endPoint: .trailing))
            : AnyShapeStyle(Palette.bassMeter)
        return GeometryReader { g in
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
                Capsule().fill(boostFill)
                    .frame(width: max(0, half * boost), height: height)
                    .offset(x: half, y: midY - height / 2)
                // Centre tick — the 0 dB reference both halves move away from.
                Rectangle().fill(Palette.textPrimary.opacity(0.25))
                    .frame(width: 1, height: min(g.size.height, height + 4))
                    .offset(x: half - 0.5, y: midY - min(g.size.height, height + 4) / 2)
                if marks, let c = MeterCeilings.ceilings(for: style) {
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
        // Secondary, not tertiary: a graphic mark needs 3:1 against the track
        // (tertiary was 2.6–2.9; secondary is 5.1–5.6).
        Rectangle().fill(Palette.textSecondary)
            .frame(width: 1, height: 4)
            .offset(x: x - 0.5, y: top - 2)
    }
}
