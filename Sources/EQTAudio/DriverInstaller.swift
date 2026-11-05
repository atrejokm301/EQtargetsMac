//
//  DriverInstaller.swift
//  EQtargets (macOS)
//
//  Installs / removes EQtargetsAudio.driver in /Library/Audio/Plug-Ins/HAL
//  with ONE administrator prompt, then restarts coreaudiod so it loads.
//
//  How: /usr/bin/osascript runs `do shell script … with administrator
//  privileges` in a background Process (never on the main thread — the prompt
//  and coreaudiod's restart take seconds).
//
//  Quoting: the only variable in the privileged command is the source path,
//  and it never passes through our own string escaping. It travels to
//  AppleScript as an argv item and is shell-quoted there by `quoted form of`,
//  which is correct for any path (spaces, quotes, `$`, backslashes, newlines).
//  The destination is a fixed literal. `eqt-engine --offline-selftest` runs
//  the same argv → `quoted form of` → `do shell script` pipeline unprivileged
//  with hostile paths and checks they arrive byte-identical, and compiles the
//  privileged scripts with osacompile.
//

import Foundation

enum DriverInstallError: LocalizedError, Equatable {
    case bundleMissing(String)
    case invalidBundle(String)
    case failed(String)
    case timedOut(installing: Bool)

    var errorDescription: String? {
        switch self {
        case .bundleMissing(let path):
            return "The EQtargets Audio driver isn't inside this app (looked for \(path)). Reinstall EQtargets."
        case .invalidBundle(let why):
            return "The EQtargets Audio driver bundle is damaged: \(why)."
        case .failed(let message):
            return "Installing the driver failed: \(message)"
        case .timedOut(let installing):
            return installing
                ? "The driver was copied, but EQtargets Audio didn't appear within 15 seconds. Restart your Mac to finish."
                : "The driver was removed, but EQtargets Audio is still listed. Restart your Mac to finish."
        }
    }
}

enum DriverInstaller {

    static let halDirectory = "/Library/Audio/Plug-Ins/HAL"
    static var installedPath: String { halDirectory + "/" + EQT_DRIVER_BUNDLE_NAME }

    /// coreaudiod restart: `launchctl kickstart -k` is the documented way, but
    /// it is refused under SIP on some releases — `killall` (launchd restarts
    /// it) is the fallback.
    static let restartCoreAudio =
        "(/bin/launchctl kickstart -k system/com.apple.audio.coreaudiod || /usr/bin/killall coreaudiod)"

    /// The driver shipped inside the app (Contents/Resources).
    static func embeddedDriver(in bundle: Bundle = .main) -> URL {
        (bundle.resourceURL ?? bundle.bundleURL).appendingPathComponent(EQT_DRIVER_BUNDLE_NAME)
    }

    /// Cheap sanity check before asking for a password.
    static func validate(_ url: URL) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw DriverInstallError.bundleMissing(url.path)
        }
        guard let bundle = Bundle(url: url) else { throw DriverInstallError.invalidBundle("not a bundle") }
        guard bundle.bundleIdentifier == EQT_DRIVER_BUNDLE_ID else {
            throw DriverInstallError.invalidBundle("identifier is \(bundle.bundleIdentifier ?? "missing"), expected \(EQT_DRIVER_BUNDLE_ID)")
        }
        guard let exe = bundle.executableURL, FileManager.default.isExecutableFile(atPath: exe.path) else {
            throw DriverInstallError.invalidBundle("no executable")
        }
    }

    // MARK: Scripts

    /// AppleScript lines: argv item 1 is the source path; `prefix` and
    /// `suffix` are fixed shell text around its quoted form. Literal text must
    /// not contain `"` or `\` (it is embedded in an AppleScript string literal);
    /// enforced by precondition.
    static func scriptLines(shellPrefix: String, shellSuffix: String, privileged: Bool) -> [String] {
        precondition(!(shellPrefix + shellSuffix).contains(where: { $0 == "\"" || $0 == "\\" }),
                     "fixed shell text must not need AppleScript escaping")
        let admin = privileged ? " with administrator privileges" : ""
        return [
            "on run argv",
            "set src to item 1 of argv",
            "do shell script \"\(shellPrefix)\" & quoted form of src & \"\(shellSuffix)\"\(admin)",
            "end run",
        ]
    }

    /// Copy (replacing any older copy), make it root-owned and hardened
    /// (`hardenCommand`: coreaudiod refuses or warns on group/world-writable
    /// plug-ins), restart coreaudiod.
    static var installScript: [String] {
        let dst = "'\(installedPath)'"
        return scriptLines(
            shellPrefix: "/bin/mkdir -p '\(halDirectory)' && /bin/rm -rf \(dst) && /usr/bin/ditto ",
            shellSuffix: " \(dst) && /usr/sbin/chown -R root:wheel \(dst) && \(hardenCommand(dst)) && \(restartCoreAudio)",
            privileged: true)
    }

    /// Run as root on the freshly copied, root-owned bundle (`quotedPath` is
    /// already shell-quoted). The source is user-writable, and `ditto` keeps
    /// ACLs and (as root) set-id bits, so: drop every ACL — a planted
    /// "everyone allow write" entry would leave the root-owned driver
    /// writable by every local user — then every setuid / setgid / sticky bit
    /// and all group / world write. `-R` never follows symlinks (`-P`).
    static func hardenCommand(_ quotedPath: String) -> String {
        "/bin/chmod -R -N \(quotedPath) && /bin/chmod -R a-st,go-w \(quotedPath)"
    }

    static var uninstallScript: [String] {
        [
            "do shell script \"/bin/rm -rf '\(installedPath)' && \(restartCoreAudio)\" with administrator privileges",
        ]
    }

    // MARK: Running

    struct ScriptResult: Equatable {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    /// Runs osascript in a background thread; resumes on completion.
    static func runOSAScript(_ lines: [String], arguments: [String]) async throws -> ScriptResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                p.arguments = lines.flatMap { ["-e", $0] } + arguments
                let out = Pipe()
                let err = Pipe()
                p.standardOutput = out
                p.standardError = err
                p.standardInput = FileHandle.nullDevice
                do {
                    try p.run()
                } catch {
                    continuation.resume(throwing: DriverInstallError.failed("couldn't run osascript (\(error.localizedDescription))"))
                    return
                }
                // Outputs are a few lines at most, far below the pipe buffer.
                let o = out.fileHandleForReading.readDataToEndOfFile()
                let e = err.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                continuation.resume(returning: ScriptResult(
                    status: p.terminationStatus,
                    stdout: String(decoding: o, as: UTF8.self),
                    stderr: String(decoding: e, as: UTF8.self)))
            }
        }
    }

    /// osascript failure → the error the UI shows. Cancelling the password
    /// prompt is AppleScript error −128 and maps to `CocoaError(.userCancelled)`
    /// (NSUserCancelledError), which the app shows as "cancelled", not "failed".
    static func error(from result: ScriptResult) -> Error? {
        guard result.status != 0 else { return nil }
        let text = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("(-128)") || text.localizedCaseInsensitiveContains("User canceled") {
            return CocoaError(.userCancelled)
        }
        // "0:123: execution error: <message> (<code>)" → "<message> (<code>)"
        var message = text
        if let r = message.range(of: "execution error: ") { message = String(message[r.upperBound...]) }
        if message.isEmpty { message = "osascript exited with status \(result.status)" }
        return DriverInstallError.failed(message)
    }

    static func install(from url: URL) async throws {
        try validate(url)
        let result = try await runOSAScript(installScript, arguments: [url.standardizedFileURL.path])
        if let e = error(from: result) { throw e }
    }

    static func uninstall() async throws {
        let result = try await runOSAScript(uninstallScript, arguments: [])
        if let e = error(from: result) { throw e }
    }

    /// Polls (4 Hz) until EQtargets Audio is published (`present`) or gone.
    @MainActor
    static func waitForDevice(present: Bool, timeoutSeconds: Double = 15) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if (DeviceCatalog.virtualDevice() != nil) == present { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return (DeviceCatalog.virtualDevice() != nil) == present
    }
}
