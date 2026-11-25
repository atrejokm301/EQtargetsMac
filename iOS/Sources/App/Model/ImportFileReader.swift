//
//  ImportFileReader.swift
//  EQtargets (iOS)
//
//  Reads a picked file as untrusted input. The shared `AutoEQImport.read` trusts
//  the reported file size and reads on the caller's thread. Here the read itself
//  is capped, so a provider that reports no size cannot make it unbounded, and
//  file coordination lets an iCloud file finish downloading first.
//
//  Two hostile inputs the shared parser doesn't defend against:
//  - A long run of spaces makes its filter pattern backtrack quadratically, which
//    hangs for minutes on 1 MB. Whitespace runs are collapsed before parsing.
//  - Each band is clamped to +20 dB and the preamp can take back only 20 dB, so
//    ten filters stacked on one frequency would add up to +180 dB. Refused.
//

import Foundation

enum ImportFileReader {
    /// Text up to this size is safe to parse on the main thread.
    static let inlineLimit = 16 * 1024

    static func read(_ url: URL) -> Result<ImportedCorrection, ImportFailure> {
        let name = url.lastPathComponent
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        var result: Result<ImportedCorrection, ImportFailure>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges,
                                       error: &coordinationError) { readable in
            result = readCoordinated(readable, name: name)
        }
        if let result { return result }
        let reason = coordinationError?.localizedDescription ?? "The file could not be opened."
        return .failure(.unreadable(file: name, reason: reason))
    }

    private static func readCoordinated(_ url: URL, name: String) -> Result<ImportedCorrection, ImportFailure> {
        do {
            if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                return .failure(.unreadable(file: name, reason: "That\u{2019}s a folder. Choose the ParametricEQ.txt file inside it."))
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: AutoEQImport.maxBytes + 1) ?? Data()
            return parse(data: data, name: name)
        } catch {
            return .failure(.unreadable(file: name, reason: error.localizedDescription))
        }
    }

    static func parse(data: Data, name: String) -> Result<ImportedCorrection, ImportFailure> {
        guard data.count <= AutoEQImport.maxBytes else { return .failure(.tooLarge) }
        let prepared: Data
        if data.count % 2 == 0, data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let text = String(data: data, encoding: .utf16) {
            prepared = Data(collapsingWhitespace(text).utf8)
        } else if data.contains(0) {
            prepared = data         // the shared parser explains binary files
        } else {
            let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
            prepared = Data(collapsingWhitespace(text).utf8)
        }
        return vetted(AutoEQImport.parse(data: prepared, sourceName: name, fileName: name), name: name)
    }

    static func parse(text: String, sourceName: String) -> Result<ImportedCorrection, ImportFailure> {
        guard text.utf8.count <= AutoEQImport.maxBytes else { return .failure(.tooLarge) }
        let clean = collapsingWhitespace(text)
        return vetted(AutoEQImport.parse(text: clean, sourceName: sourceName, fileName: nil), name: sourceName)
    }

    /// Every whitespace run becomes one tab, or one newline if it held a line break.
    /// Linear, and the filter syntax doesn't depend on how much space it has. Works
    /// by character because that's how the parser's `\s` matches: a space carrying a
    /// combining mark counts as whitespace. A tab or newline can't carry a mark, so
    /// the output can't rebuild a run.
    static func collapsingWhitespace(_ text: String) -> String {
        var out = ""
        var pending: Character?
        for ch in text {
            if ch.isWhitespace {
                pending = ch.isNewline || pending == "\n" ? "\n" : "\t"
            } else {
                if let p = pending {
                    out.append(p)
                    pending = nil
                }
                out.append(ch)
            }
        }
        if let pending { out.append(pending) }
        return out
    }

    private static func vetted(_ result: Result<ImportedCorrection, ImportFailure>,
                               name: String) -> Result<ImportedCorrection, ImportFailure> {
        guard case .success(let c) = result else { return result }
        let peak = FrequencyResponse.peakMagnitudeDB(bands: c.layer.bands)
        guard peak + c.layer.preamp <= 0.5 else {
            return .failure(.unreadable(file: name, reason: "It boosts the sound by more than the 20 dB its preamp can take back, which could damage your hearing or your headphones."))
        }
        return result
    }
}

extension ImportedCorrection {
    /// The dropped filters for the preview, capped: a file can list thousands.
    var droppedPreview: String {
        let limit = 5
        let shown = dropped.prefix(limit)
            .map { EQFormat.gain($0.gain) + " at " + EQFormat.frequency($0.frequency) }
            .joined(separator: ", ")
        return dropped.count > limit ? "\(shown), and \(dropped.count - limit) more" : shown
    }
}
