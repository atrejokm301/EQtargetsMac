//
//  OutputDevice.swift
//  EQtargets (iOS)
//
//  The real output the equalized audio plays on. Same role and field names as
//  the Mac type, so the shared PresetStore compiles unchanged.
//

import Foundation

enum OutputTransport: String, Equatable, Hashable {
    case builtIn, wired, bluetooth, usb, hdmi, airPlay, carPlay, other
}

struct OutputDevice: Identifiable, Hashable {
    var id: String { uid }
    let uid: String
    let name: String
    let transport: OutputTransport
}
