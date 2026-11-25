//
//  EQControlIntents.swift
//  EQtargets (iOS)
//
//  What a tap on a tile does. Compiled into the app and the tile extension, but
//  they only ever run in the app, because only the app can change the audio. iOS
//  launches it in the background if needed.
//
//  This iPhone must be unlocked first, not just a paired device. Before the first
//  unlock after a restart the app's settings can't be read.
//

import AppIntents
import Foundation

@MainActor
protocol EQControlHandling: AnyObject {
    /// Throws `.audioNeedsForeground` if iOS refused to start the audio from the
    /// background and `mayOpenApp` says the caller can open the app and try again.
    func setPoweredFromControl(_ on: Bool, mayOpenApp: Bool) throws
    func nextBassStyleFromControl()
}

/// The app registers itself at launch, before any intent can run.
@MainActor
enum EQControlBridge {
    static var handler: (any EQControlHandling)?

    static func requireHandler() throws -> any EQControlHandling {
        guard let handler else { throw EQControlError.appUnavailable }
        return handler
    }
}

enum EQControlError: LocalizedError {
    case appUnavailable
    case audioNeedsForeground

    var errorDescription: String? {
        switch self {
        case .appUnavailable: return "EQtargets could not be reached. Open the app and try again."
        case .audioNeedsForeground: return "EQtargets has to be open to start the audio."
        }
    }
}

enum EQControlFlow {
    /// Tries in the background first, so a tap normally leaves you where you are.
    @MainActor
    static func setPower(_ on: Bool, handler: any EQControlHandling,
                         openApp: () async throws -> Void) async throws {
        do {
            try handler.setPoweredFromControl(on, mayOpenApp: true)
        } catch EQControlError.audioNeedsForeground {
            try await openApp()
            try handler.setPoweredFromControl(on, mayOpenApp: false)
        }
    }
}

struct SetEQPowerIntent: SetValueIntent, AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Turn EQtargets On or Off"
    static let isDiscoverable = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @Parameter(title: "On")
    var value: Bool

    @MainActor
    func perform() async throws -> some IntentResult {
        let handler = try EQControlBridge.requireHandler()
        try await EQControlFlow.setPower(value, handler: handler) {
            try await continueInForeground(alwaysConfirm: false)
        }
        return .result()
    }
}

struct NextBassStyleIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Next Bass Style"
    static let isDiscoverable = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    static let supportedModes: IntentModes = .background
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @MainActor
    func perform() async throws -> some IntentResult {
        try EQControlBridge.requireHandler().nextBassStyleFromControl()
        return .result()
    }
}
