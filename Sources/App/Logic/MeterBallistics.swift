//
//  MeterBallistics.swift
//  EQtargets (macOS)
//
//  Display ballistics of the Punch / Rumble activity meter (DESIGN §8.2),
//  identical in wall-clock terms to the iOS BassStyleEditorSheet: instant rise,
//  release at 0.82 per 50 ms. The decay constant is re-derived from the poll
//  interval (`pow(0.82, interval / 0.050)`), so polling at 30 Hz falls exactly
//  as fast as the iOS 20 Hz poll did (≈ −45% after 150 ms).
//

import Foundation

struct MeterBallistics: Equatable {
    /// Shared full scale for BOTH halves and BOTH styles: Punch's 9 dB attack
    /// ceiling, the largest of the four. Equal bar length = equal dB.
    static let fullScaleDB = TransientPunchTuning.maxAttackBoostDB
    static let idleThresholdDB = 0.05

    private(set) var boostDB: Double = 0
    private(set) var trimDB: Double = 0
    let decay: Double

    init(intervalSeconds: Double) {
        decay = pow(0.82, max(intervalSeconds, 0.001) / 0.050)
    }

    /// One poll. Rise is instant; fall is a one-pole release toward the new value.
    /// `elapsed` (seconds since the previous poll) keeps the fall time exact in
    /// wall-clock terms when the poll jitters; nil uses the nominal interval.
    mutating func feed(boostDB newBoost: Double, trimDB newTrim: Double, elapsed: Double? = nil) {
        let b = newBoost.isFinite ? max(0, newBoost) : 0
        let t = newTrim.isFinite ? max(0, newTrim) : 0
        let k = elapsed.map { pow(0.82, min(max($0, 0.001), 1) / 0.050) } ?? decay
        boostDB = b > boostDB ? b : boostDB * k + b * (1 - k)
        trimDB = t > trimDB ? t : trimDB * k + t * (1 - k)
        // Denormal / visual floor: settle to exactly 0 so the readout says idle.
        if boostDB < 1e-4 { boostDB = 0 }
        if trimDB < 1e-4 { trimDB = 0 }
    }

    /// Snapshot / preview seeding.
    mutating func set(boostDB b: Double, trimDB t: Double) {
        boostDB = max(0, b); trimDB = max(0, t)
    }

    mutating func reset() { boostDB = 0; trimDB = 0 }

    var isIdle: Bool { boostDB < Self.idleThresholdDB && trimDB < Self.idleThresholdDB }

    static func fraction(_ db: Double) -> Double { min(1, max(0, db / fullScaleDB)) }

    var boostFraction: Double { Self.fraction(boostDB) }
    var trimFraction: Double { Self.fraction(trimDB) }

    /// Whichever side is doing more work: `+3.2 dB` / `−1.4 dB` / `0.0 dB`.
    var readout: String {
        if isIdle { return "0.0" + EQFormat.nbsp + "dB" }
        if boostDB >= trimDB { return EQFormat.gain(boostDB) }
        return EQFormat.gain(-trimDB)
    }

    var accessibilityValue: String {
        if isIdle { return "Idle" }
        if boostDB >= trimDB { return String(format: "Boost %.1f decibels", boostDB) }
        return String(format: "Trim %.1f decibels", trimDB)
    }
}

/// Ceiling marks for the meter: where each half stops for the current style.
enum MeterCeilings {
    /// (left = trim/soften, right = boost/sustain) in dB.
    static func ceilings(for style: BassStyle) -> (left: Double, right: Double)? {
        switch style {
        case .transientPunch:
            return (TransientPunchTuning.maxSustainTrimDB, TransientPunchTuning.maxAttackBoostDB)
        case .sustainRumble:
            return (SustainRumbleTuning.maxSoftenDB, SustainRumbleTuning.maxSustainBoostDB)
        case .none, .naturalClean:
            return nil
        }
    }
}
