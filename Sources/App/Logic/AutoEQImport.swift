//
//  AutoEQImport.swift
//  EQtargets (macOS)
//
//  Everything between "the user dropped / pasted / opened something" and the
//  import preview sheet (DESIGN §5.4, §6.5, copy §11.4). Pure — no UI.
//
//  The preview needs more than `AutoEQParser.parse` returns: how many filters the
//  file had, which ones were dropped (it keeps the 10 that shape the curve most)
//  and the file's own `Preamp:` line. Rather than copying Core's filter regex
//  (two regexes drift apart — DESIGN §16.2), the filters are counted with
//  `AutoEQParser.filters(in:)` — the exact list `AutoEQParser.parse` realizes —
//  so the preview always describes what Apply applies (several filters on one
//  line or a pasted single-line list included).
//

import Foundation

struct ImportedCorrection: Equatable {
    /// Exactly what Apply will load (from the whole-file `AutoEQParser.parse`).
    var layer: EQLayerState
    var filtersInFile: Int
    var dropped: [EQBand]
    /// The file's own `Preamp:` line, if any — shown next to the measured one.
    var filePreampDB: Double?
    var suggestedName: String
    var sourceName: String

    /// Preamp we derive from the realized filters (never positive).
    var measuredPreampDB: Double { layer.preamp }

    var preampDiffers: Bool {
        guard let f = filePreampDB else { return false }
        return abs(f - measuredPreampDB) >= 0.05
    }

    var droppedSummary: String {
        dropped.map { EQFormat.gain($0.gain) + " at " + EQFormat.frequency($0.frequency) }
            .joined(separator: ", ")
    }
}

enum ImportFailure: Error, Equatable {
    case empty
    case noFilters
    case tooLarge
    case unreadable(file: String, reason: String)

    var title: String {
        switch self {
        case .empty: return "This file is empty."
        case .noFilters: return "No EQ filters found"
        case .tooLarge: return "This file is too large to be an EQ preset."
        case .unreadable(let file, _): return "Couldn\u{2019}t open \u{201C}\(file)\u{201D}."
        }
    }

    var message: String {
        switch self {
        case .empty:
            return "Export a ParametricEQ.txt from AutoEQ and try again."
        case .noFilters:
            return "EQtargets reads AutoEQ \u{201C}ParametricEQ.txt\u{201D} files \u{2014} lines like \u{201C}Filter 1: ON PK Fc 105 Hz Gain 6.5 dB Q 0.70\u{201D}. GraphicEQ and convolution files aren\u{2019}t supported."
        case .tooLarge:
            return "AutoEQ presets are small text files. Pick the ParametricEQ.txt export."
        case .unreadable(_, let reason):
            return reason
        }
    }
}

enum AutoEQImport {
    /// Real presets are a few hundred bytes; anything over 1 MB is not one.
    static let maxBytes = 1_048_576
    static let maxNameLength = 60

    static func read(url: URL) -> Result<ImportedCorrection, ImportFailure> {
        let fileName = url.lastPathComponent
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            if values.isDirectory == true {
                return .failure(.unreadable(file: fileName, reason: "That\u{2019}s a folder. Drop the ParametricEQ.txt file inside it."))
            }
            if let size = values.fileSize, size > maxBytes { return .failure(.tooLarge) }
            let data = try Data(contentsOf: url)
            return parse(data: data, sourceName: fileName, fileName: fileName)
        } catch {
            return .failure(.unreadable(file: fileName, reason: error.localizedDescription))
        }
    }

    static func parse(data: Data, sourceName: String, fileName: String?) -> Result<ImportedCorrection, ImportFailure> {
        if data.count > maxBytes { return .failure(.tooLarge) }
        // UTF-16 with a byte-order mark (Notepad's "Unicode", some Equalizer
        // APO / Peace exports) is full of NUL bytes but is text: decode it
        // BEFORE the binary check. Undecodable → falls through to that check.
        if data.count % 2 == 0, data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let text = String(data: data, encoding: .utf16) {
            return parse(text: text, sourceName: sourceName, fileName: fileName)
        }
        // A NUL byte means binary (an image, a zip…): say so instead of "no filters".
        if data.contains(0) {
            return .failure(.unreadable(file: sourceName, reason: "This isn\u{2019}t a text file. EQtargets reads AutoEQ ParametricEQ.txt files."))
        }
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        return parse(text: text, sourceName: sourceName, fileName: fileName)
    }

    static func parse(text: String, sourceName: String, fileName: String?) -> Result<ImportedCorrection, ImportFailure> {
        guard text.utf8.count <= maxBytes else { return .failure(.tooLarge) }
        let layer: EQLayerState
        do {
            layer = try AutoEQParser.parse(text: text)
        } catch AutoEQParser.ParseError.empty {
            return .failure(.empty)
        } catch {
            return .failure(.noFilters)
        }
        let all = fileFilters(in: text)   // non-empty: parse() succeeded on the same list
        let kept = Array(layer.bands.prefix(min(all.count, EQLayerState.bandCount)))
        let count = all.count
        return .success(ImportedCorrection(
            layer: layer,
            filtersInFile: count,
            dropped: dropped(all: all, kept: kept),
            filePreampDB: filePreamp(in: text),
            suggestedName: suggestedName(fileName: fileName),
            sourceName: sourceName
        ))
    }

    /// Cheap check for ⌘V: does the clipboard text contain at least one filter?
    static func containsFilters(_ text: String) -> Bool {
        guard text.utf8.count <= maxBytes else { return false }
        return (try? AutoEQParser.parse(text: text)) != nil
    }

    // MARK: Helpers

    /// Every filter in the text, found exactly the way Core's parser finds
    /// them (whole text at once), so the preview counts what Apply applies —
    /// including several filters on one line or a pasted single-line list.
    static func fileFilters(in text: String) -> [EQBand] {
        AutoEQParser.filters(in: text)
    }

    /// Filters in `all` that the whole-file parse did not keep (multiset difference).
    static func dropped(all: [EQBand], kept: [EQBand]) -> [EQBand] {
        var remaining = kept
        var out: [EQBand] = []
        for f in all {
            if let i = remaining.firstIndex(where: { sameFilter($0, f) }) {
                remaining.remove(at: i)
            } else {
                out.append(f)
            }
        }
        return out
    }

    private static func sameFilter(_ a: EQBand, _ b: EQBand) -> Bool {
        a.filterType == b.filterType && a.isEnabled == b.isEnabled
            && abs(a.frequency - b.frequency) < 1e-6 && abs(a.gain - b.gain) < 1e-6 && abs(a.q - b.q) < 1e-6
    }

    /// `Preamp: -6.2 dB` → −6.2.
    static func filePreamp(in text: String) -> Double? {
        let pattern = #/(?i)Preamp:\s*([+-]?\d+(?:\.\d+)?)\s*dB/#
        guard let m = text.firstMatch(of: pattern) else { return nil }
        return Double(m.1)
    }

    /// "Sennheiser HD 600 ParametricEQ.txt" → "Sennheiser HD 600".
    static func suggestedName(fileName: String?) -> String {
        guard var s = fileName, !s.isEmpty else { return "Pasted Correction" }
        if s.lowercased().hasSuffix(".txt") { s.removeLast(4) }
        s = s.replacingOccurrences(of: "ParametricEQ", with: "", options: .caseInsensitive)
        s = s.replacingOccurrences(of: "_", with: " ")
        s = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " -–—·"))
        if s.isEmpty { return "Imported Correction" }
        return String(s.prefix(maxNameLength))
    }
}
