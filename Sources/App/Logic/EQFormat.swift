//
//  EQFormat.swift
//  EQtargets (macOS)
//
//  Display formats and forgiving input parsing for the band inspector (DESIGN
//  §6.3, copy rules §11). Pure functions — covered by the DEBUG self-test.
//
//  Copy rules: U+2212 for negative numbers, a no-break space between number and
//  unit, `%` without a space. Numbers show the units they really have; nothing
//  is rounded into a lie (a 31.5 Hz band reads 31.5, not 32).
//

import Foundation

enum EQFormat {
    static let minus = "\u{2212}"
    static let nbsp = "\u{00A0}"

    // MARK: Frequency

    /// `31.5 Hz` · `63 Hz` · `125 Hz` · `1.25 kHz` · `10.0 kHz` (≥ 1 k: 3 significant digits).
    static func frequency(_ f: Double) -> String {
        guard f.isFinite else { return "—" }
        if f < 100 {
            let r = (f * 10).rounded() / 10
            if r < 100 { return trimmed(r, decimals: 1) + nbsp + "Hz" }
        }
        let hz = f.rounded()
        if hz < 1000 { return "\(Int(hz))" + nbsp + "Hz" }
        let k = f / 1000
        // Round first, then pick the precision, so 9 996 Hz reads "10.0 kHz"
        // (3 significant digits) instead of "10.00 kHz".
        let k2 = (k * 100).rounded() / 100
        if k2 < 10 { return String(format: "%.2f", k2) + nbsp + "kHz" }
        return String(format: "%.1f", (k * 10).rounded() / 10) + nbsp + "kHz"
    }

    /// VoiceOver form: `5.00 kilohertz` · `125 hertz` (replacing "Hz" alone
    /// turned "kHz" into "khertz").
    static func spokenFrequency(_ f: Double) -> String {
        frequency(f).replacingOccurrences(of: "kHz", with: "kilohertz")
            .replacingOccurrences(of: "Hz", with: "hertz")
    }

    /// Compact frequency for band pills / node chrome: `31.5` · `125` · `1k` · `1.2k` · `16k`.
    static func frequencyCompact(_ f: Double) -> String {
        guard f.isFinite else { return "—" }
        if f < 100 { return trimmed((f * 10).rounded() / 10, decimals: 1) }
        if f < 999.5 { return "\(Int(f.rounded()))" }
        return trimmed((f / 100).rounded() / 10, decimals: 1) + "k"
    }

    /// Axis labels: `20` `50` `100` `1k` `10k` `20k`.
    static func axisFrequency(_ f: Double) -> String {
        f >= 1000 ? "\(Int((f / 1000).rounded()))k" : "\(Int(f.rounded()))"
    }

    // MARK: Gain / Q / percent

    /// `+4.0 dB` · `−3.0 dB` · `0.0 dB`.
    static func gain(_ g: Double) -> String {
        signedNumber(g, decimals: 1) + nbsp + "dB"
    }

    /// Axis labels: `+12` `+6` `0` `−6`.
    static func axisGain(_ g: Double) -> String {
        let r = Int(g.rounded())
        if r == 0 { return "0" }
        return r > 0 ? "+\(r)" : minus + "\(-r)"
    }

    /// `+4.2` / `−1.0` / `0.0`.
    static func signedNumber(_ v: Double, decimals: Int) -> String {
        guard v.isFinite else { return "—" }
        let scale = pow(10, Double(decimals))
        let r = (v * scale).rounded() / scale
        if r == 0 { return String(format: "%.\(decimals)f", 0.0) }
        let body = String(format: "%.\(decimals)f", abs(r))
        return (r > 0 ? "+" : minus) + body
    }

    static func q(_ q: Double) -> String { String(format: "%.2f", q) }

    static func percent(_ unit: Double) -> String { String(format: "%.0f%%", unit * 100) }

    /// Dynamics sliders read `Off` below 0.5%.
    static func percentOrOff(_ unit: Double) -> String { unit < 0.005 ? "Off" : percent(unit) }

    static func cutoff(_ hz: Double) -> String { "\(Int(hz.rounded()))" + nbsp + "Hz" }

    // MARK: Engine readouts

    /// `48 kHz` · `44.1 kHz` · `96 kHz`.
    static func sampleRate(_ sr: Double) -> String {
        guard sr > 0, sr.isFinite else { return "—" }
        return trimmed((sr / 100).rounded() / 10, decimals: 1) + nbsp + "kHz"
    }

    static func latency(_ ms: Double) -> String {
        guard ms > 0, ms.isFinite else { return "—" }
        return "\(Int(ms.rounded()))" + nbsp + "ms"
    }

    // MARK: Parsing (§6.3)

    /// Accepts `1200`, `1.2k`, `1.2 kHz`, `1,200`, `120 Hz`. Not clamped.
    static func parseFrequency(_ text: String) -> Double? {
        var s = normalized(text)
        var multiplier = 1.0
        if s.hasSuffix("khz") { s.removeLast(3); multiplier = 1000 }
        else if s.hasSuffix("hz") { s.removeLast(2) }
        else if s.hasSuffix("k") { s.removeLast(1); multiplier = 1000 }
        guard let v = number(s) else { return nil }
        return v * multiplier
    }

    /// Accepts `-3`, `−3`, `3`, `+3 dB`. Not clamped.
    static func parseGain(_ text: String) -> Double? {
        var s = normalized(text)
        if s.hasSuffix("db") { s.removeLast(2) }
        return number(s)
    }

    static func parseQ(_ text: String) -> Double? {
        var s = normalized(text)
        if s.hasPrefix("q") { s.removeFirst() }
        return number(s)
    }

    // MARK: Private

    private static func normalized(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: minus, with: "-")
            .replacingOccurrences(of: "\u{2013}", with: "-")   // en dash typed as minus
            .filter { !$0.isWhitespace }
    }

    /// `1,200` is a thousands separator (exactly three digits after the comma,
    /// no dot); any other comma is a decimal comma (`1,5` = 1.5).
    private static func number(_ s: String) -> Double? {
        var t = s
        if t.hasPrefix("+") { t.removeFirst() }
        if t.contains(",") {
            let parts = t.split(separator: ",", omittingEmptySubsequences: false)
            let thousands = !t.contains(".") && parts.count >= 2
                && parts.dropFirst().allSatisfy { $0.count == 3 && $0.allSatisfy(\.isNumber) }
            t = thousands ? t.replacingOccurrences(of: ",", with: "")
                          : t.replacingOccurrences(of: ",", with: ".")
        }
        guard !t.isEmpty, let v = Double(t), v.isFinite else { return nil }
        return v
    }

    private static func trimmed(_ v: Double, decimals: Int) -> String {
        let s = String(format: "%.\(decimals)f", v)
        guard s.contains(".") else { return s }
        var out = s
        while out.hasSuffix("0") { out.removeLast() }
        if out.hasSuffix(".") { out.removeLast() }
        return out
    }
}

// MARK: - Inspector field commit rules

/// The commit decision of `ValueField`, as a pure value so the self-test can
/// drive it (view `@State` can't be tested).
///
/// WHY: the field shows a ROUNDED value (`−10.5 dB` for −10.531, `1.37 kHz`
/// for 1371 Hz). Committing whatever text is showing on every blur wrote that
/// rounded text back into the model, so merely tabbing through a field edited
/// the preset ("— Edited", an undo step, 1371 → 1370 Hz). And a focused field
/// never refreshed, so its stale text was later written over a value that a
/// stepper / drag / undo had changed. Rules:
/// • Only text the USER typed (`dirty`) is ever committed, and only if it
///   differs from what the model value would show.
/// • A clean field always follows the model, focused or not.
struct ValueFieldEditor: Equatable {
    enum Outcome: Equatable {
        case none
        case commit(Double)
        case invalid
    }

    private(set) var text = ""
    /// The user has typed since the text last matched the model.
    private(set) var dirty = false

    /// The TextField's binding setter: only real edits come through here.
    mutating func userEdited(_ new: String) {
        guard new != text else { return }
        text = new
        dirty = true
    }

    /// The model value changed (stepper, drag, scroll, undo, preset load…).
    /// A clean field shows it; typing in progress is kept.
    mutating func sync(to value: Double, format: (Double) -> String) {
        guard !dirty else { return }
        text = format(value)
    }

    /// Show `value` and drop any typing (after a stepper / arrow-key commit).
    mutating func reset(to value: Double, format: (Double) -> String) {
        dirty = false
        text = format(value)
    }

    /// Return, blur or disappear. Commits only typing that changes the shown value.
    mutating func finish(value: Double, format: (Double) -> String, parse: (String) -> Double?,
                         range: ClosedRange<Double>) -> Outcome {
        guard dirty else { text = format(value); return .none }
        dirty = false
        if text == format(value) { return .none }
        guard let parsed = parse(text), parsed.isFinite else {
            text = format(value)
            return .invalid
        }
        let v = min(max(parsed, range.lowerBound), range.upperBound)
        text = format(v)
        return .commit(v)
    }

    /// Arrow keys step from what the user typed, else from the EXACT model
    /// value (not the rounded text: 1371 Hz must not step from 1370).
    func stepBase(value: Double, parse: (String) -> Double?) -> Double {
        dirty ? (parse(text) ?? value) : value
    }
}
