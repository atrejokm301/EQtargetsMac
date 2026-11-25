//
//  LinkJournalTests.swift
//  EQtargets (iOS)
//

import XCTest

@MainActor
final class LinkJournalTests: XCTestCase {

    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LinkJournalTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private var file: URL { folder.appendingPathComponent("journal.txt") }

    /// A journal whose burst limit is out of the way, for tests about other things.
    private func journal(_ url: URL? = nil, clock: @escaping () -> Date = Date.init) -> LinkJournal {
        LinkJournal(url: url, clock: clock, burstLines: 100_000)
    }

    private func fileLines() throws -> [String] {
        try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    func test_add_writesATimestampedLine_andALaterLaunchReadsItBack() throws {
        let fixed = Date(timeIntervalSince1970: 1_800_000_000)
        let j = journal(file, clock: { fixed })
        j.add("route changed reason=newDevice")
        let lines = try fileLines()
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].hasSuffix(" route changed reason=newDevice"), lines[0])
        XCTAssertTrue(lines[0].range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} "#,
                                     options: .regularExpression) != nil, lines[0])

        let relaunched = LinkJournal(url: file)
        XCTAssertEqual(relaunched.lines, lines, "the drop-out is often seen only after a relaunch")
        relaunched.add("app started")
        XCTAssertEqual(try fileLines().count, 2)
    }

    func test_add_keepsOnlyTheNewestLines() throws {
        let j = journal(file)
        for i in 0 ..< LinkJournal.maxLines + 5 { j.add("event \(i)") }
        XCTAssertEqual(j.lines.count, LinkJournal.maxLines)
        XCTAssertTrue(j.lines.first!.hasSuffix(" event 5"), "the oldest go first")
        let reloaded = LinkJournal(url: file).lines
        XCTAssertEqual(reloaded, j.lines, "a relaunch sees the same newest lines")
    }

    func test_add_appendsWithoutRewritingWhatIsThere() throws {
        // More lines than the journal keeps in memory: a rewrite would drop the oldest.
        let existing = (0 ..< LinkJournal.maxLines + 50).map { "kept \($0)" }
        try Data((existing.joined(separator: "\n") + "\n").utf8).write(to: file)
        let j = journal(file)
        j.add("new")
        let lines = try fileLines()
        XCTAssertEqual(Array(lines.dropLast()), existing, "one write per event, not a full rewrite")
        XCTAssertTrue(lines.last!.hasSuffix(" new"))
    }

    func test_add_compactsTheFileBeforeItPassesTwiceTheLimit() throws {
        let j = journal(file)
        for i in 0 ..< LinkJournal.maxLines * 2 + 10 { j.add("event \(i)") }
        let lines = try fileLines()
        XCTAssertLessThanOrEqual(lines.count, LinkJournal.maxLines * 2, "the file cannot grow without end")
        XCTAssertTrue(lines.last!.hasSuffix(" event \(LinkJournal.maxLines * 2 + 9)"))
        XCTAssertEqual(Array(lines.suffix(LinkJournal.maxLines)), j.lines)
    }

    func test_add_theSameFailureEverySecond_costsAFewLinesNotOnePerSecond() {
        var t = Date(timeIntervalSince1970: 1_800_000_000)
        let j = journal(clock: { t })
        for _ in 0 ..< 3_600 {                  // an hour of one retry per second
            j.add("engine failed NSOSStatusErrorDomain 561017449")
            t += 1
        }
        XCTAssertLessThanOrEqual(j.lines.count, 13)
        XCTAssertTrue(j.lines.last!.hasSuffix("(again, 2049 in a row)"), j.lines.last!)
        j.add("route changed")
        XCTAssertTrue(j.lines.last!.hasSuffix(" route changed"), "a new event is written at once")
    }

    func test_add_aBurstPastTheLimit_isCountedThenTheHistoryResumes() {
        var t = Date(timeIntervalSince1970: 1_800_000_000)
        let j = LinkJournal(url: nil, clock: { t }, burstLines: 3, refillSeconds: 10)
        for i in 0 ..< 5 { j.add("e\(i)") }
        XCTAssertEqual(j.lines.count, 3, "only the burst is written")
        t += 10
        j.add("later")
        XCTAssertEqual(j.lines.count, 5)
        XCTAssertTrue(j.lines[3].hasSuffix("(2 events skipped: too many at once)"), j.lines[3])
        XCTAssertTrue(j.lines[4].hasSuffix(" later"))
    }

    func test_add_importantEvents_getThroughAFlood() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let j = LinkJournal(url: nil, clock: { t }, burstLines: 3, refillSeconds: 10)
        for i in 0 ..< 10 { j.add(i.isMultiple(of: 2) ? "engine started" : "engine stopped") }
        j.add("peer left", important: true)
        XCTAssertTrue(j.lines.last!.hasSuffix(" peer left"), "the line the journal exists for")
        XCTAssertTrue(j.lines.contains { $0.contains("events skipped") }, "the flood is still counted")
    }

    func test_add_aRepeatRunEndingBetweenPowersOfTwo_writesItsTotal() {
        let j = journal()
        for _ in 0 ..< 6 { j.add("engine failed") }     // written at 1, 2, 3 and 5 in a row
        j.add("route changed")
        XCTAssertTrue(j.lines[j.lines.count - 2].hasSuffix("engine failed (6 in a row in all)"),
                      j.lines[j.lines.count - 2])
        XCTAssertTrue(j.lines.last!.hasSuffix(" route changed"))
    }

    func test_add_aRepeatRunEndingOnAPowerOfTwo_addsNoTotal() {
        let j = journal()
        for _ in 0 ..< 5 { j.add("x") }                  // last written: 5 in a row
        j.add("y")
        XCTAssertFalse(j.lines.contains { $0.contains("in all") })
    }

    func test_addGap_usesTheJournalsOwnTimeFormat() {
        let j = journal()
        let since = Date(timeIntervalSince1970: 1_800_000_000)
        j.addGap(TickGapWatch.Gap(awakeSeconds: 1, clockSeconds: 3_600, since: since))
        let line = j.lines.last!
        XCTAssertTrue(line.contains(" (1.0 s awake, 3600.0 s on the clock)"), line)
        XCTAssertTrue(line.range(of: #"no tick since \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} "#,
                                 options: .regularExpression) != nil, line)
    }

    func test_add_aHeadphoneSwitchBurst_fitsTheDefaultLimit() {
        let j = LinkJournal(url: nil)
        for i in 0 ..< 20 { j.add("switch event \(i)") }
        XCTAssertEqual(j.lines.count, 20)
    }

    func test_load_anOversizedFile_keepsItsNewestLines() throws {
        let text = (0 ..< LinkJournal.maxLines * 2).map { "old \($0)" }.joined(separator: "\n")
        try Data(text.utf8).write(to: file)
        let j = LinkJournal(url: file)
        XCTAssertEqual(j.lines.count, LinkJournal.maxLines)
        XCTAssertEqual(j.lines.last, "old \(LinkJournal.maxLines * 2 - 1)")
    }

    func test_load_missingFile_startsEmpty() {
        XCTAssertEqual(LinkJournal(url: file).lines, [], "no file yet")
    }

    func test_load_aTornCharacter_doesNotHideTheRestOfTheFile() throws {
        var bytes = Data("first line\nKevin\u{2019}s Air".utf8)
        bytes.append(contentsOf: [0xE2, 0x80])          // a curly apostrophe cut in half
        bytes.append(contentsOf: Array("\nlast line\n".utf8))
        try bytes.write(to: file)
        let j = journal(file)
        XCTAssertEqual(j.lines.first, "first line")
        XCTAssertEqual(j.lines.last, "last line")

        j.add("new")
        let reloaded = LinkJournal(url: file).lines
        XCTAssertEqual(reloaded.count, 4, "the file stays readable after more lines")
        XCTAssertTrue(reloaded.last!.hasSuffix(" new"))
    }

    func test_add_aMultiLineEvent_staysOneLine() throws {
        let j = LinkJournal(url: file)
        j.add("first\nsecond")
        XCTAssertEqual(try fileLines().count, 1)
        XCTAssertTrue(j.lines[0].hasSuffix(" first second"))
    }

    func test_add_withNoFile_keepsLinesInMemory() {
        let j = LinkJournal(url: nil)
        j.add("x")
        XCTAssertEqual(j.lines.count, 1)
    }

    func test_add_whenTheFolderIsGone_doesNotCrashOrLoseTheLine() throws {
        let j = LinkJournal(url: folder.appendingPathComponent("missing/journal.txt"))
        j.add("x")
        XCTAssertEqual(j.lines.count, 1, "a failed write only loses diagnostics")
    }
}
