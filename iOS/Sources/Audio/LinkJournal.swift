//
//  LinkJournal.swift
//  EQtargets (iOS)
//
//  The last few hundred route and engine events, in a file the Mac can read
//  over the cable or Wi-Fi without root (reading the phone's system log needs
//  root on the Mac):
//
//    xcrun devicectl device copy from --device <phone> --domain-type appDataContainer \
//      --domain-identifier com.eqtargets.ios --source Library/Caches/link-journal.txt \
//      --destination link-journal.txt
//
//  It tells the two ways EQtargets can drop out of Control Center apart. If iOS
//  moved the output itself, "peer left" follows a route change while the app
//  kept ticking. If the app was suspended, a "no tick" gap comes first. Only
//  events are written, never one line per tick, and a failure that repeats
//  cannot push the history out:
//  - the same event in a row is written again only after 1, 2, 4, 8... repeats,
//    and the final count when a different event comes;
//  - at most `burstLines` lines at once, then one per `refillSeconds`, except
//    the important events (route changes, peers, gaps, keep-awake, power),
//    which always get through so a flood cannot hide a real switch;
//  - lines are appended, and the file is rewritten only when it reaches twice
//    `maxLines`.
//  The file stays on the phone. It names the outputs (e.g. the headphones).
//

import Foundation

@MainActor
final class LinkJournal {

    static let maxLines = 400

    private(set) var lines: [String]
    private let url: URL?
    private let clock: () -> Date
    private let burstLines: Double
    private let refillSeconds: TimeInterval
    private var linesInFile: Int
    private var lastEvent: String?
    private var repeats = 0
    private var writtenRepeats = 0
    private var budget: Double
    private var budgetAt: Date?
    private var skipped = 0
    private let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    nonisolated static var defaultURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("link-journal.txt")
    }

    /// `url` nil keeps the lines in memory only. A missing or unreadable file
    /// starts an empty journal. A headphone switch writes about a dozen lines,
    /// well inside the default burst.
    init(url: URL? = LinkJournal.defaultURL, clock: @escaping () -> Date = Date.init,
         burstLines: Int = 60, refillSeconds: TimeInterval = 10) {
        self.url = url
        self.clock = clock
        self.burstLines = Double(max(1, burstLines))
        self.refillSeconds = max(0.001, refillSeconds)
        budget = Double(max(1, burstLines))
        var loaded: [String] = []
        // Leniently: a torn character must not hide the rest of the file.
        if let url, let data = try? Data(contentsOf: url) {
            loaded = String(decoding: data, as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        }
        linesInFile = loaded.count
        lines = Array(loaded.suffix(Self.maxLines))
    }

    /// `important` lines skip the burst limit.
    func add(_ event: String, important: Bool = false) {
        // One event per line, whatever the text holds.
        let flat = event.replacingOccurrences(of: "\n", with: " ")
        let now = clock()
        if flat == lastEvent {
            repeats += 1
            // Powers of two: an hour of a once-a-second failure costs 12 lines, not 3,600.
            guard repeats & (repeats - 1) == 0 else { return }
            writtenRepeats = repeats
            write("\(stamp.string(from: now)) \(flat) (again, \(repeats + 1) in a row)", now: now, important: important)
            return
        }
        if let last = lastEvent, repeats > writtenRepeats {
            write("\(stamp.string(from: now)) \(last) (\(repeats + 1) in a row in all)", now: now, important: false)
        }
        lastEvent = flat
        repeats = 0
        writtenRepeats = 0
        write("\(stamp.string(from: now)) \(flat)", now: now, important: important)
    }

    /// A tick gap, in this journal's own time format.
    func addGap(_ gap: TickGapWatch.Gap) {
        add(String(format: "no tick since %@ (%.1f s awake, %.1f s on the clock): suspended, or the main thread was blocked",
                   stamp.string(from: gap.since), gap.awakeSeconds, gap.clockSeconds),
            important: true)
    }

    private func write(_ line: String, now: Date, important: Bool) {
        if let at = budgetAt {
            budget = min(burstLines, budget + max(0, now.timeIntervalSince(at)) / refillSeconds)
        }
        budgetAt = now
        if !important {
            guard budget >= 1 else {
                skipped += 1
                return
            }
            budget -= 1
        }
        if skipped > 0 {
            emit("\(stamp.string(from: now)) (\(skipped) events skipped: too many at once)")
            skipped = 0
        }
        emit(line)
    }

    private func emit(_ line: String) {
        lines.append(line)
        if lines.count > Self.maxLines { lines.removeFirst(lines.count - Self.maxLines) }
        guard let url else { return }
        // A failed write only loses diagnostics, never audio.
        if linesInFile >= Self.maxLines * 2 || !append(line + "\n", to: url) {
            rewrite(url)
        } else {
            linesInFile += 1
        }
    }

    /// False when there is no file yet, or it could not be written.
    private func append(_ text: String, to url: URL) -> Bool {
        guard let handle = try? FileHandle(forWritingTo: url) else { return false }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
            return true
        } catch {
            return false
        }
    }

    private func rewrite(_ url: URL) {
        let text = lines.joined(separator: "\n") + "\n"
        let ok = (try? Data(text.utf8).write(to: url, options: .atomic)) != nil
        linesInFile = ok ? lines.count : 0
    }
}
