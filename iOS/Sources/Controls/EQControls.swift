//
//  EQControls.swift
//  EQtargets (iOS)
//
//  The two Control Center tiles. iOS gives third-party tiles a tap and nothing
//  else, so each does one thing: EQ on or off, and the next Bass Style.
//

import AppIntents
import SwiftUI
import WidgetKit

@main
struct EQtargetsControlsBundle: WidgetBundle {
    var body: some Widget {
        EQPowerControl()
        EQBassControl()
    }
}

private struct EQControlProvider: ControlValueProvider {
    var previewValue: EQControlState { .placeholder }

    func currentValue() async throws -> EQControlState {
        EQControlStore().load()
    }
}

private enum EQControlTint {
    static let power = Color(red: 0x00 / 255, green: 0x73 / 255, blue: 0xD9 / 255)  // the app's accent
    static let bass = Color(red: 0x8C / 255, green: 0xD9 / 255, blue: 0xFF / 255)   // its Bass Style accent
}

struct EQPowerControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: EQControlID.powerKind, provider: EQControlProvider()) { state in
            ControlWidgetToggle("EQtargets", isOn: state.isOn, action: SetEQPowerIntent()) { isOn in
                Label(isOn ? "On" : "Off", systemImage: "slider.vertical.3")
            }
            .tint(EQControlTint.power)
        }
        .displayName("EQtargets")
        .description("Turn the EQ on or off.")
    }
}

struct EQBassControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: EQControlID.bassKind, provider: EQControlProvider()) { state in
            ControlWidgetButton(action: NextBassStyleIntent()) {
                Label("Bass: \(state.bassName)", systemImage: state.bassSymbol)
            }
            .tint(EQControlTint.bass)
        }
        .displayName("Bass Style")
        .description("Tap for the next Bass Style.")
    }
}
