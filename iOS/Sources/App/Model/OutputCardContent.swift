//
//  OutputCardContent.swift
//  EQtargets (iOS)
//
//  What the Output card and the header pill say for each `EngineStatus`. A plain
//  value with no SwiftUI, so every state's wording and controls can be tested.
//
//  The switch has no `default` on purpose: a new engine state must not compile
//  until someone decides what the user is told about it.
//
//  The output is always chosen in Control Center. An in-app picker would pull
//  this app's own audio onto the EQtargets route (see LinkEngine.swift).
//

import Foundation

/// Why audio is passing through unprocessed while the engine reports it running.
enum OutputBypass: Equatable { case none, comparing, allStagesOff }

struct OutputCardContent: Equatable {
    enum Tone: Equatable { case positive, neutral, warning, danger }
    enum Action: Equatable { case turnOn, tryAgain }

    var title: String
    var message: String
    var tone: Tone
    /// SF Symbol for the state. nil = the current output's transport symbol.
    var symbol: String?
    var action: Action?
    /// The short form for the header pill.
    var pill: String

    static let waitingInstruction = "Open Control Center, tap the audio output, and choose EQtargets."

    static func make(status: EngineStatus, output: OutputDevice?,
                     bypass: OutputBypass = .none) -> OutputCardContent {
        let equalizing = output.map { "Equalizing through \($0.name)" } ?? "Equalizing your audio"
        // The card must never claim the sound is being shaped when it isn't.
        if status == .running || status == .idle {
            switch bypass {
            case .comparing:
                return OutputCardContent(
                    title: "Comparing the original sound",
                    message: "The EQ is bypassed while Compare is on.",
                    tone: .warning, symbol: "circle.lefthalf.filled", action: nil, pill: "Comparing")
            case .allStagesOff:
                return OutputCardContent(
                    title: "No EQ applied",
                    message: "Nothing is shaping the sound. Turn on a layer, shape a band or import a correction.",
                    tone: .warning, symbol: "slider.horizontal.3", action: nil, pill: "No EQ")
            case .none:
                break
            }
        }
        switch status {
        case .off:
            return OutputCardContent(
                title: "EQtargets is off",
                message: "Turn it on first, then choose EQtargets in Control Center.",
                tone: .neutral, symbol: "power", action: .turnOn, pill: "Not running")
        case .starting:
            return OutputCardContent(
                title: "Starting\u{2026}",
                message: "Getting the audio ready.",
                tone: .neutral, symbol: "hourglass", action: nil, pill: "Starting")
        case .waiting:
            return OutputCardContent(
                title: "Choose EQtargets as your output",
                message: waitingInstruction,
                tone: .warning, symbol: "speaker.wave.2.fill", action: nil, pill: "Not selected")
        case .idle:
            return OutputCardContent(
                title: equalizing,
                message: "Connected. Play something to hear it.",
                tone: .neutral, symbol: nil, action: nil, pill: "Ready")
        case .running:
            return OutputCardContent(
                title: equalizing,
                message: "Sound from your apps is being shaped.",
                tone: .positive, symbol: nil, action: nil, pill: "Equalizing")
        case .interrupted:
            return OutputCardContent(
                title: "Paused by a call or another app",
                message: "EQtargets picks up again when it ends.",
                tone: .warning, symbol: "phone.fill", action: nil, pill: "Paused")
        case .feedbackGuard:
            return OutputCardContent(
                title: "EQtargets can\u{2019}t play through itself",
                message: "Its sound is muted to prevent feedback. Choose your headphones or speaker in Control Center.",
                tone: .warning, symbol: "speaker.slash.fill", action: nil, pill: "Muted")
        case .passThrough:
            return OutputCardContent(
                title: "EQ is off",
                message: "Audio is still passing through EQtargets. To disconnect, choose another output in Control Center.",
                tone: .warning, symbol: "arrow.right.circle", action: .turnOn,
                pill: "Pass-through")
        case .error(let message):
            return OutputCardContent(
                title: "Something went wrong",
                message: message,
                tone: .danger, symbol: "xmark.octagon.fill", action: .tryAgain, pill: "Error")
        }
    }
}
