//
//  EQModels.swift
//  EQtargets (macOS) — ported from EQtargets Music (iOS) Models/EQModels.swift
//
//  Dual-layer parametric EQ (Target + Fine-Tune).
//  Signal chain: system mix → Target PEQ → Fine-Tune PEQ → Bass Style → output
//
//  Bass Style lives in BassProcessor.swift and NEVER mutates Target / Fine-Tune.
//  Port notes: the iOS audio-route types and the iOS preset store were dropped
//  (the Mac binds Targets to Core Audio device UIDs instead), and
//  `EQFilterType.avFilterType` was removed — the Mac renders these exact RBJ
//  biquads itself, so the graph and the DSP share one formula.
//

import Foundation

// MARK: - Band filter type (peaking + shelves)

/// Parametric filter shape for Target / Fine-Tune bands.
/// Defaults to `.peak` for backward compatibility with older presets / AutoEQ.
enum EQFilterType: String, Codable, CaseIterable, Identifiable, Hashable {
    case peak
    case lowShelf
    case highShelf

    var id: String { rawValue }

    var title: String {
        switch self {
        case .peak: return "Peak"
        case .lowShelf: return "Low Shelf"
        case .highShelf: return "High Shelf"
        }
    }

    /// Compact label for band chrome.
    var shortTitle: String {
        switch self {
        case .peak: return "Peak"
        case .lowShelf: return "L-Shelf"
        case .highShelf: return "H-Shelf"
        }
    }

    var systemImage: String {
        switch self {
        case .peak: return "waveform.path.ecg"
        case .lowShelf: return "arrow.down.to.line"
        case .highShelf: return "arrow.up.to.line"
        }
    }

}

struct EQBand: Identifiable, Equatable, Hashable {
    var id: UUID
    var frequency: Double
    var gain: Double
    var q: Double
    var isEnabled: Bool
    /// Peaking by default — never breaks old JSON without this key.
    var filterType: EQFilterType

    static let frequencyRange: ClosedRange<Double> = 20 ... 20_000
    static let gainRange: ClosedRange<Double> = -20 ... 20
    static let qRange: ClosedRange<Double> = 0.1 ... 10

    init(
        id: UUID = UUID(),
        frequency: Double,
        gain: Double = 0,
        q: Double = 1.41,
        isEnabled: Bool = true,
        filterType: EQFilterType = .peak
    ) {
        self.id = id
        self.frequency = Self.clamp(frequency, to: Self.frequencyRange)
        self.gain = Self.clamp(gain, to: Self.gainRange)
        self.q = Self.clamp(q, to: Self.qRange)
        self.isEnabled = isEnabled
        self.filterType = filterType
    }

    static func defaultTenBands() -> [EQBand] {
        [31.5, 63, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]
            .map { EQBand(frequency: $0, filterType: .peak) }
    }

    mutating func reset() {
        gain = 0
        q = 1.41
        isEnabled = true
        // Keep filterType — user may have set L-Shelf on band 1 intentionally.
    }

    /// Clamp all fields into legal ranges (use after UI mutation / import).
    mutating func sanitize() {
        frequency = Self.clamp(frequency, to: Self.frequencyRange)
        gain = Self.clamp(gain, to: Self.gainRange)
        q = Self.clamp(q, to: Self.qRange)
        if EQFilterType(rawValue: filterType.rawValue) == nil {
            filterType = .peak
        }
    }

    /// Convert Q-factor → bandwidth in **octaves** for `AVAudioUnitEQ.bandwidth`.
    /// RBJ peaking identity: BW_oct = 2 · asinh(1 / (2Q)) / ln(2).
    static func bandwidthOctaves(fromQ q: Double) -> Float {
        let safe = max(q, 0.05)
        guard safe.isFinite else { return 1.0 }
        return Float(2.0 * asinh(1.0 / (2.0 * safe)) / log(2.0))
    }

    private static func clamp(_ v: Double, to r: ClosedRange<Double>) -> Double {
        min(max(v, r.lowerBound), r.upperBound)
    }
}

// Codable with default `.peak` when key missing (old presets / AutoEQ imports).
extension EQBand: Codable {
    enum CodingKeys: String, CodingKey {
        case id, frequency, gain, q, isEnabled, filterType
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        frequency = Self.clamp(try c.decode(Double.self, forKey: .frequency), to: Self.frequencyRange)
        gain = Self.clamp(try c.decodeIfPresent(Double.self, forKey: .gain) ?? 0, to: Self.gainRange)
        q = Self.clamp(try c.decodeIfPresent(Double.self, forKey: .q) ?? 1.41, to: Self.qRange)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        filterType = try c.decodeIfPresent(EQFilterType.self, forKey: .filterType) ?? .peak
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(frequency, forKey: .frequency)
        try c.encode(gain, forKey: .gain)
        try c.encode(q, forKey: .q)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encode(filterType, forKey: .filterType)
    }
}

struct EQLayerState: Codable, Equatable, Hashable {
    var preamp: Double
    var bands: [EQBand]
    var isBypassed: Bool

    /// User request: preamp protection range −20…+20 dB
    static let preampRange: ClosedRange<Double> = -20 ... 20
    static let bandCount = 10

    static var flat: EQLayerState {
        EQLayerState(preamp: 0, bands: EQBand.defaultTenBands(), isBypassed: false)
    }

    init(preamp: Double = 0, bands: [EQBand], isBypassed: Bool = false) {
        self.preamp = min(max(preamp, Self.preampRange.lowerBound), Self.preampRange.upperBound)
        var n = bands
        if n.count < Self.bandCount {
            let d = EQBand.defaultTenBands()
            for i in n.count ..< Self.bandCount { n.append(d[i]) }
        } else if n.count > Self.bandCount {
            n = Array(n.prefix(Self.bandCount))
        }
        for i in n.indices { n[i].sanitize() }
        self.bands = n
        self.isBypassed = isBypassed
    }

    /// Ensure 10 bands + clamped F/G/Q/preamp before pushing to audio hardware.
    mutating func sanitizeForDSP() {
        preamp = min(max(preamp, Self.preampRange.lowerBound), Self.preampRange.upperBound)
        if bands.count < Self.bandCount {
            let d = EQBand.defaultTenBands()
            for i in bands.count ..< Self.bandCount { bands.append(d[i]) }
        } else if bands.count > Self.bandCount {
            bands = Array(bands.prefix(Self.bandCount))
        }
        for i in bands.indices { bands[i].sanitize() }
    }

    mutating func resetAll() {
        preamp = 0
        bands = EQBand.defaultTenBands()
        isBypassed = false
    }

    var isFlat: Bool {
        abs(preamp) < 0.001 && bands.allSatisfy { abs($0.gain) < 0.001 }
    }
}

enum EQLayer: String, CaseIterable, Identifiable, Codable {
    case target
    case fineTune

    var id: String { rawValue }

    var title: String {
        switch self {
        case .target: return "Target"
        case .fineTune: return "Fine-Tune"
        }
    }

    var subtitle: String {
        switch self {
        case .target: return "AutoEQ / Squiglink curve"
        case .fineTune: return "Personal adjustment on top"
        }
    }
}

struct DualEQState: Codable, Equatable, Hashable {
    var target: EQLayerState
    var fineTune: EQLayerState
    var isBypassed: Bool
    var editingLayer: EQLayer

    static var flat: DualEQState {
        DualEQState(target: .flat, fineTune: .flat, isBypassed: false, editingLayer: .fineTune)
    }

    var activeLayer: EQLayerState {
        get { editingLayer == .target ? target : fineTune }
        set {
            if editingLayer == .target { target = newValue }
            else { fineTune = newValue }
        }
    }

    mutating func loadTarget(_ layer: EQLayerState, keepFineTune: Bool = true) {
        var t = layer
        t.isBypassed = false
        target = t
        if !keepFineTune { fineTune.resetAll() }
        editingLayer = .fineTune
    }

    mutating func resetFineTune() {
        fineTune.resetAll()
        editingLayer = .fineTune
    }
}

// MARK: - AutoEQ parser

enum AutoEQParser {
    enum ParseError: LocalizedError {
        case empty, noFilters
        var errorDescription: String? {
            switch self {
            case .empty: return "File is empty."
            case .noFilters: return "No parametric (PK) filters found."
            }
        }
    }

    /// Map an exporter's filter-type token to an `EQFilterType`.
    ///
    /// AutoEQ emits `PK` throughout, but oratory1990 / Squiglink presets — the
    /// usual source for headphone targets — lead with a low shelf and often end
    /// with a high shelf. Those were previously unmatched and silently dropped,
    /// while the file's `Preamp:` (computed *with* them) was still imported —
    /// so the curve lost its bass compensation and kept the attenuation.
    private static func filterType(for token: String) -> EQFilterType {
        switch token.uppercased() {
        case "LS", "LSC", "LSQ": return .lowShelf
        case "HS", "HSC", "HSQ": return .highShelf
        default: return .peak
        }
    }

    static func parse(text: String) throws -> EQLayerState {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ParseError.empty }

        // Collect every filter first — selecting which to keep needs the whole set.
        let bands = filters(in: trimmed)

        guard !bands.isEmpty else { throw ParseError.noFilters }
        return realize(bands)
    }

    /// Every filter the text defines, in file order, BEFORE the 10-band
    /// selection — so an import preview can count exactly what `parse` saw
    /// (the whole text at once; a filter split across lines or several on one
    /// line count the same way `parse` counts them).
    ///
    /// Strict lines first: `Filter N: ON PK Fc … Hz Gain … dB Q …`, where the
    /// number is optional (Equalizer APO writes `Filter: ON LSC …`), so the
    /// filter type and ON/OFF are kept. Only if no strict line matched, the
    /// loose fallback picks up `Fc … Hz … Gain … dB … Q …` (type Peak, ON).
    static func filters(in text: String) -> [EQBand] {
        // Longest-first alternation: `LS` would otherwise match the prefix of
        // `LSC` and strand the trailing character, failing the whole line.
        let filterPattern = #/(?i)Filter\s*\d*\s*:\s*(ON|OFF)\s+(LSC|LSQ|LS|HSC|HSQ|HS|PEAK|PEQ|PK|Bell)\s+Fc\s+([+-]?\d+(?:\.\d+)?)\s*Hz\s+Gain\s+([+-]?\d+(?:\.\d+)?)\s*dB\s+Q\s+([+-]?\d+(?:\.\d+)?)/#

        var bands: [EQBand] = []
        for match in text.matches(of: filterPattern) {
            bands.append(
                EQBand(
                    frequency: Double(match.3) ?? 1000,
                    gain: Double(match.4) ?? 0,
                    q: Double(match.5) ?? 1.0,
                    isEnabled: String(match.1).uppercased() == "ON",
                    filterType: filterType(for: String(match.2))
                )
            )
        }

        if bands.isEmpty {
            // The gaps are BOUNDED (64 characters, never across a line break):
            // two unbounded lazy `.*?` gaps backtrack cubically on one long
            // line with no `Q` (8 KB took 15 s, on the main thread). Real
            // loose formats put a few characters there (", ", "  ").
            let loose = #/(?i)Fc\s+([+-]?\d+(?:\.\d+)?)\s*Hz.{0,64}?Gain\s+([+-]?\d+(?:\.\d+)?)\s*dB.{0,64}?Q\s+([+-]?\d+(?:\.\d+)?)/#
            for match in text.matches(of: loose) {
                bands.append(
                    EQBand(
                        frequency: Double(match.1) ?? 1000,
                        gain: Double(match.2) ?? 0,
                        q: Double(match.3) ?? 1.0
                    )
                )
            }
        }
        return bands
    }

    /// The 10 bands + derived preamp `parse` returns for a non-empty filter set.
    private static func realize(_ filters: [EQBand]) -> EQLayerState {
        var bands = filters
        // More filters than hardware bands: keep the ones that shape the curve
        // most, not merely the first ten. Truncating in file order discards the
        // largest correction whenever a preset lists it late.
        if bands.count > EQLayerState.bandCount {
            let kept = bands.enumerated()
                .sorted { lhs, rhs in
                    let l = abs(lhs.element.gain), r = abs(rhs.element.gain)
                    return l == r ? lhs.offset < rhs.offset : l > r
                }
                .prefix(EQLayerState.bandCount)
                .sorted { $0.offset < $1.offset }   // restore file (frequency) order
                .map(\.element)
            bands = Array(kept)
        }

        if bands.count < EQLayerState.bandCount {
            let d = EQBand.defaultTenBands()
            for i in bands.count ..< EQLayerState.bandCount {
                var f = d[i]
                f.gain = 0
                f.isEnabled = false
                bands.append(f)
            }
        }

        // Derive preamp from the curve we actually realized rather than trusting
        // the file's value. They agree when nothing was dropped (measured within
        // 0.03 dB on a real AutoEQ export); they diverge exactly when filters were
        // discarded or gains clamped — which is when the file's value is wrong.
        // Never positive: a cuts-only curve gets 0, matching AutoEQ's convention.
        let realizedPeak = FrequencyResponse.peakMagnitudeDB(bands: bands)
        let preamp = min(max(-max(realizedPeak, 0),
                             EQLayerState.preampRange.lowerBound),
                         EQLayerState.preampRange.upperBound)

        return EQLayerState(preamp: preamp, bands: bands)
    }
}

// MARK: - Frequency response (graph)

enum FrequencyResponse {
    /// Keep ≤128 for battery — 96 is enough for a ~160–180pt-tall plot.
    static let pointCount = 96
    static let sampleRate: Double = 48_000
    /// Shared log axis so all curves share one frequency grid.
    private static let axisFrequencies: [Double] = logSpace(20, 20_000, pointCount)

    struct Point: Identifiable, Equatable {
        var id: Double { frequency }
        let frequency: Double
        let magnitudeDB: Double
    }

    /// Peak of a curve (max |mag| prefers boost; ties → higher magnitude).
    struct Peak: Equatable {
        let frequency: Double
        let magnitudeDB: Double
    }

    static func curve(layer: EQLayerState) -> [Point] {
        samples(for: layer, frequencies: axisFrequencies)
    }

    static func combined(dual: DualEQState) -> [Point] {
        let pack = curves(dual: dual)
        return pack.combined
    }

    /// One-pass Target + Fine + Combined (shared frequency grid, no triple logSpace).
    static func curves(dual: DualEQState) -> (combined: [Point], target: [Point], fine: [Point]) {
        let freqs = axisFrequencies
        if dual.isBypassed {
            let z = freqs.map { Point(frequency: $0, magnitudeDB: 0) }
            return (z, z, z)
        }
        let t = samples(for: dual.target, frequencies: freqs)
        let f = samples(for: dual.fineTune, frequencies: freqs)
        let c = zip(t, f).map { a, b in
            Point(frequency: a.frequency, magnitudeDB: a.magnitudeDB + b.magnitudeDB)
        }
        return (c, t, f)
    }

    static func peak(of points: [Point]) -> Peak? {
        guard !points.isEmpty else { return nil }
        // Prefer the highest boost; if all cuts, show the least negative (closest to 0 peak for display of max magnitude boost)
        var best = points[0]
        for p in points.dropFirst() {
            if p.magnitudeDB > best.magnitudeDB { best = p }
        }
        // Flat line — no marker
        if abs(best.magnitudeDB) < 0.05 { return nil }
        return Peak(frequency: best.frequency, magnitudeDB: best.magnitudeDB)
    }

    /// Peak magnitude of a band set in dB, ignoring preamp.
    ///
    /// Uses a fine sweep rather than the 96-point display grid: that grid lands
    /// within ~0.34 dB of the true peak on a real AutoEQ preset, which is fine
    /// for drawing a line but not for deriving preamp, where the error becomes
    /// permanent headroom loss (or clipping).
    static func peakMagnitudeDB(bands: [EQBand], sampleRate: Double = sampleRate) -> Double {
        let filters = bands.filter(\.isEnabled).map {
            EQBiquad(
                type: $0.filterType,
                frequency: $0.frequency,
                gainDB: $0.gain,
                q: $0.q,
                sampleRate: sampleRate
            )
        }
        guard !filters.isEmpty else { return 0 }
        var peak = -Double.infinity
        var f = 20.0
        while f <= 20_000 {
            var m = 0.0
            for filter in filters { m += filter.magnitudeDB(at: f, sampleRate: sampleRate) }
            if m > peak { peak = m }
            f *= 1.005
        }
        return peak.isFinite ? peak : 0
    }

    static func xPosition(_ frequency: Double) -> Double {
        let f = min(max(frequency, 20), 20_000)
        return (log10(f) - log10(20)) / (log10(20_000) - log10(20))
    }

    static func formatFrequencyHz(_ f: Double) -> String {
        if f >= 1000 {
            let k = f / 1000
            if abs(k - k.rounded()) < 0.05 { return "\(Int(k.rounded()))k" }
            return String(format: "%.1fk", k)
        }
        if f >= 100 { return "\(Int(f.rounded()))" }
        return String(format: "%.0f", f)
    }

    static func formatGainDB(_ g: Double) -> String {
        String(format: "%+.1f dB", g)
    }

    // MARK: - Private

    private static func samples(for layer: EQLayerState, frequencies: [Double]) -> [Point] {
        if layer.isBypassed {
            return frequencies.map { Point(frequency: $0, magnitudeDB: 0) }
        }
        let filters = layer.bands.filter(\.isEnabled).map {
            EQBiquad(
                type: $0.filterType,
                frequency: $0.frequency,
                gainDB: $0.gain,
                q: $0.q
            )
        }
        return frequencies.map { f in
            var m = layer.preamp
            for filter in filters { m += filter.magnitudeDB(at: f) }
            return Point(frequency: f, magnitudeDB: m)
        }
    }

    private static func logSpace(_ minF: Double, _ maxF: Double, _ count: Int) -> [Double] {
        let a = log10(minF), b = log10(maxF)
        let step = (b - a) / Double(max(count - 1, 1))
        return (0 ..< count).map { pow(10, a + Double($0) * step) }
    }
}

/// RBJ cookbook biquad for graph magnitude (peak + low/high shelf).
/// Kept separate from AVAudioUnitEQ so the UI curve matches DSP types.
struct EQBiquad {
    let b0, b1, b2, a0, a1, a2: Double

    /// Backward-compatible peaking constructor.
    init(frequency: Double, gainDB: Double, q: Double, sampleRate: Double = FrequencyResponse.sampleRate) {
        self.init(type: .peak, frequency: frequency, gainDB: gainDB, q: q, sampleRate: sampleRate)
    }

    init(
        type: EQFilterType,
        frequency: Double,
        gainDB: Double,
        q: Double,
        sampleRate: Double = FrequencyResponse.sampleRate
    ) {
        let A = pow(10, gainDB / 40)
        let w0 = 2 * .pi * frequency / sampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)
        let safeQ = max(q, 0.05)
        let alpha = sinW0 / (2 * safeQ)

        switch type {
        case .peak:
            b0 = 1 + alpha * A
            b1 = -2 * cosW0
            b2 = 1 - alpha * A
            a0 = 1 + alpha / A
            a1 = -2 * cosW0
            a2 = 1 - alpha / A

        case .lowShelf:
            let twoSqrtAAlpha = 2 * sqrt(A) * alpha
            b0 = A * ((A + 1) - (A - 1) * cosW0 + twoSqrtAAlpha)
            b1 = 2 * A * ((A - 1) - (A + 1) * cosW0)
            b2 = A * ((A + 1) - (A - 1) * cosW0 - twoSqrtAAlpha)
            a0 = (A + 1) + (A - 1) * cosW0 + twoSqrtAAlpha
            a1 = -2 * ((A - 1) + (A + 1) * cosW0)
            a2 = (A + 1) + (A - 1) * cosW0 - twoSqrtAAlpha

        case .highShelf:
            let twoSqrtAAlpha = 2 * sqrt(A) * alpha
            b0 = A * ((A + 1) + (A - 1) * cosW0 + twoSqrtAAlpha)
            b1 = -2 * A * ((A - 1) + (A + 1) * cosW0)
            b2 = A * ((A + 1) + (A - 1) * cosW0 - twoSqrtAAlpha)
            a0 = (A + 1) - (A - 1) * cosW0 + twoSqrtAAlpha
            a1 = 2 * ((A - 1) - (A + 1) * cosW0)
            a2 = (A + 1) - (A - 1) * cosW0 - twoSqrtAAlpha
        }
    }

    func magnitudeDB(at f: Double, sampleRate: Double = FrequencyResponse.sampleRate) -> Double {
        let w = 2 * .pi * f / sampleRate
        let cosW = cos(w), cos2W = cos(2 * w)
        let sinW = sin(w), sin2W = sin(2 * w)
        let numRe = b0 + b1 * cosW + b2 * cos2W
        let numIm = -(b1 * sinW + b2 * sin2W)
        let denRe = a0 + a1 * cosW + a2 * cos2W
        let denIm = -(a1 * sinW + a2 * sin2W)
        let n2 = numRe * numRe + numIm * numIm
        let d2 = denRe * denRe + denIm * denIm
        guard d2 > 1e-30, n2 > 0 else { return 0 }
        return 10 * log10(n2 / d2)
    }
}

/// Legacy name kept for any external references.
typealias PeakBiquad = EQBiquad

// MARK: - EQ Presets & Storage

struct EQPreset: Identifiable, Codable, Equatable, Hashable {
    var id: UUID = UUID()
    var name: String
    var layer: EQLayerState
    var isSystemDefault: Bool = false
}

enum BuiltinPresets {
    static let targets: [EQPreset] = [
        EQPreset(name: "Flat (No Target)", layer: .flat, isSystemDefault: true)
    ]

    static let fineTunes: [EQPreset] = [
        EQPreset(name: "Flat / Neutral", layer: .flat, isSystemDefault: true),
        EQPreset(
            name: "Bass Punch (+3.5 dB)",
            layer: EQLayerState(
                preamp: -1.5,
                bands: [
                    EQBand(frequency: 31.5, gain: 3.5, q: 0.8),
                    EQBand(frequency: 63, gain: 3.0, q: 1.0),
                    EQBand(frequency: 125, gain: 1.5, q: 1.2),
                    EQBand(frequency: 250, gain: 0.0, q: 1.4),
                    EQBand(frequency: 500, gain: 0.0, q: 1.4),
                    EQBand(frequency: 1000, gain: 0.0, q: 1.4),
                    EQBand(frequency: 2000, gain: 0.0, q: 1.4),
                    EQBand(frequency: 4000, gain: 0.0, q: 1.4),
                    EQBand(frequency: 8000, gain: 0.0, q: 1.4),
                    EQBand(frequency: 16000, gain: 0.0, q: 1.4)
                ]
            ),
            isSystemDefault: true
        ),
        EQPreset(
            name: "Treble Smooth (-2.5 dB Highs)",
            layer: EQLayerState(
                preamp: 0.0,
                bands: [
                    EQBand(frequency: 31.5, gain: 0.0, q: 1.4),
                    EQBand(frequency: 63, gain: 0.0, q: 1.4),
                    EQBand(frequency: 125, gain: 0.0, q: 1.4),
                    EQBand(frequency: 250, gain: 0.0, q: 1.4),
                    EQBand(frequency: 500, gain: 0.0, q: 1.4),
                    EQBand(frequency: 1000, gain: 0.0, q: 1.4),
                    EQBand(frequency: 2000, gain: 0.0, q: 1.4),
                    EQBand(frequency: 4000, gain: -1.0, q: 1.5),
                    EQBand(frequency: 8000, gain: -2.5, q: 1.8),
                    EQBand(frequency: 16000, gain: -3.0, q: 1.8)
                ]
            ),
            isSystemDefault: true
        ),
        EQPreset(
            name: "Vocal Focus",
            layer: EQLayerState(
                preamp: -1.0,
                bands: [
                    EQBand(frequency: 31.5, gain: -1.0, q: 1.0),
                    EQBand(frequency: 63, gain: -0.5, q: 1.0),
                    EQBand(frequency: 125, gain: 0.0, q: 1.0),
                    EQBand(frequency: 250, gain: 0.5, q: 1.4),
                    EQBand(frequency: 500, gain: 1.5, q: 1.4),
                    EQBand(frequency: 1000, gain: 2.0, q: 1.4),
                    EQBand(frequency: 2000, gain: 2.5, q: 1.4),
                    EQBand(frequency: 4000, gain: 1.0, q: 1.4),
                    EQBand(frequency: 8000, gain: 0.0, q: 1.4),
                    EQBand(frequency: 16000, gain: 0.0, q: 1.4)
                ]
            ),
            isSystemDefault: true
        )
    ]
}
