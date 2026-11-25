//
//  DeviceRuleTests.swift
//  EQtargets (iOS)
//
//  Rules that were learned from real iPhones and that fail only on a real iPhone,
//  so no simulator test could ever catch someone breaking them. These tests read
//  the source (comments removed) and fail if a forbidden call comes back.
//

import XCTest

final class DeviceRuleTests: XCTestCase {

    private var iOSRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Every source compiled into the app or extension, comments removed. That
    /// includes the files shared with the Mac app.
    private func productCode() throws -> [(name: String, code: String)] {
        let repo = iOSRoot.deletingLastPathComponent()
        var files: [URL] = [repo.appendingPathComponent("Sources/App/Model/PresetStore.swift"),
                            repo.appendingPathComponent("Sources/App/Model/MeterHub.swift")]
        let folders = ["Sources/App", "Sources/Audio", "Sources/Extension", "Sources/Link"].map(iOSRoot.appendingPathComponent)
            + ["Sources/EQTCore", "Sources/App/Logic"].map(repo.appendingPathComponent)
        for base in folders {
            let walker = try XCTUnwrap(FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil))
            for case let url as URL in walker where ["swift", "m", "c", "h"].contains(url.pathExtension) {
                files.append(url)
            }
        }
        XCTAssertGreaterThan(files.count, 35, "the source tree was not found")
        return try files.map { ($0.lastPathComponent, Self.withoutComments(try String(contentsOf: $0, encoding: .utf8))) }
    }

    /// Removes block and line comments, leaving `//` inside string literals alone.
    static func withoutComments(_ source: String) -> String {
        var out = ""
        var i = source.startIndex
        var inString = false
        while i < source.endIndex {
            let c = source[i]
            let next = source.index(after: i)
            if inString {
                out.append(c)
                if c == "\\", next < source.endIndex {
                    out.append(source[next])
                    i = source.index(after: next)
                    continue
                }
                if c == "\"" || c.isNewline { inString = false }
                i = next
            } else if c == "\"" {
                inString = true
                out.append(c)
                i = next
            } else if source[i...].hasPrefix("//") {
                i = source[i...].firstIndex(where: \.isNewline) ?? source.endIndex
            } else if source[i...].hasPrefix("/*") {
                let rest = source[source.index(i, offsetBy: 2)...]
                i = rest.range(of: "*/")?.upperBound ?? source.endIndex
            } else {
                out.append(c)
                i = next
            }
        }
        return out
    }

    func test_commentStripper_seesCodeNotComments() {
        XCTAssertFalse(Self.withoutComments("let a = 1 // AVRoutePickerView").contains("AVRoutePickerView"))
        XCTAssertFalse(Self.withoutComments("/* AVRoutePickerView\n */ let a = 1").contains("AVRoutePickerView"))
        XCTAssertTrue(Self.withoutComments("let u = \"https://x\"; AVRoutePickerView()").contains("AVRoutePickerView"))
        XCTAssertTrue(Self.withoutComments("// header\r\nAVRoutePickerView()").contains("AVRoutePickerView"),
                      "a CRLF file must not hide its code")
    }

    private func assertNowhere(_ needle: String, because why: String,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        for (name, code) in try productCode() where code.contains(needle) {
            XCTFail("\(name) uses \(needle): \(why)", file: file, line: line)
        }
    }

    private func engineCode() throws -> String {
        try XCTUnwrap(productCode().first { $0.name == "LinkEngine.swift" }?.code)
    }

    func test_noRoutePickerOnScreen() throws {
        try assertNowhere("AVRoutePickerView", because: "it pulls this app's audio onto its own route (feedback loop)")
        try assertNowhere("MPVolumeView", because: "it shows the same route picker")
    }

    func test_neverClaimsNowPlaying() throws {
        try assertNowhere("MPNowPlayingInfoCenter", because: "it moves this session onto the system route (feedback loop)")
        try assertNowhere("MPRemoteCommandCenter", because: "it claims now playing")
    }

    func test_neverReadsTheMicrophone() throws {
        for api in ["inputNode", "installTap", "AVCaptureDevice", "AVCaptureSession", "AVAudioRecorder",
                    "requestRecordPermission", "AudioQueueNewInput", "kAudioOutputUnitProperty_EnableIO",
                    "isInputEnabled"] {
            try assertNowhere(api, because: "EQtargets has no reason to touch the microphone")
        }
    }

    func test_bluetoothStaysOnA2DP() throws {
        let hfp = try NSRegularExpression(pattern: #"\.allowBluetooth(?!A2DP)\w*"#)
        for (name, code) in try productCode() {
            let range = NSRange(code.startIndex..., in: code)
            XCTAssertNil(hfp.firstMatch(in: code, range: range), "\(name): HFP is 16 or 32 kHz mono")
        }
        XCTAssertTrue(try engineCode().contains(".allowBluetoothA2DP"))
    }

    func test_deviceSessionPinsItsInputToTheBuiltInMic() throws {
        let code = try engineCode()
        XCTAssertTrue(code.contains("setPreferredInput"), "without this, Bluetooth drops to HFP")
        XCTAssertTrue(code.contains(".builtInMic"))
    }

    func test_playAndRecord_isNeverUsedOnTheSimulator() throws {
        let code = try engineCode()
        let simulator = try XCTUnwrap(code.range(of: "#if targetEnvironment(simulator)"))
        let otherwise = try XCTUnwrap(code.range(of: "#else", range: simulator.upperBound ..< code.endIndex))
        let end = try XCTUnwrap(code.range(of: "#endif", range: otherwise.upperBound ..< code.endIndex))
        let simulatorBranch = code[simulator.upperBound ..< otherwise.lowerBound]
        let deviceBranch = code[otherwise.upperBound ..< end.lowerBound]
        XCTAssertFalse(simulatorBranch.contains(".playAndRecord"), "it opens the Mac's real microphone")
        XCTAssertTrue(deviceBranch.contains(".playAndRecord"), "the device needs it to stay off its own route")
        XCTAssertTrue(deviceBranch.contains(".mixWithOthers"), "without it, the playing app gets silenced")
    }
}
