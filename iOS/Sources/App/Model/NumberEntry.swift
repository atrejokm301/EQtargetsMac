//
//  NumberEntry.swift
//  EQtargets (iOS)
//
//  The shared parser reads a comma followed by three digits as a thousands
//  separator. That is right for hertz ("1,000 Hz"), but Q and dB are never written
//  that way: on a comma-decimal keyboard "0,707" must be 0.707, not Q 707.
//

import Foundation

enum NumberEntry {
    static func parseQ(_ text: String) -> Double? {
        EQFormat.parseQ(decimalComma(text))
    }

    static func parseGain(_ text: String) -> Double? {
        EQFormat.parseGain(decimalComma(text))
    }

    /// "1,250 kHz" is 1.25 kHz. A bare "1,250" or "1,250 Hz" stays 1250 Hz.
    static func parseFrequency(_ text: String) -> Double? {
        let compact = text.lowercased().filter { !$0.isWhitespace }
        let usesKilo = compact.hasSuffix("k") || compact.hasSuffix("khz")
        return EQFormat.parseFrequency(usesKilo ? decimalComma(text) : text)
    }

    private static func decimalComma(_ text: String) -> String {
        text.replacingOccurrences(of: ",", with: ".")
    }
}
