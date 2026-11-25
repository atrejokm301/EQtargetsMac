//
//  EngineDriving.swift
//  EQtargets (iOS)
//
//  The UI's view of the engine. The real `LinkEngine` conforms, and previews and
//  tests use `StandInEngine`, so they never touch an audio session.
//

import Foundation

@MainActor
protocol EngineDriving: AnyObject {
    var status: EngineStatus { get }
    var isPowered: Bool { get }
    var currentOutput: OutputDevice? { get }
    var stats: EngineStats { get }
    var onOutputChanged: ((OutputDevice?) -> Void)? { get set }

    func setPowered(_ on: Bool)
    /// "Try Again" after a failure: rebuilds the audio without changing On/Off.
    func retry()
    func apply(_ parameters: ChainParameters)
    func meters() -> ChainMeters
    /// The app came to the foreground or left it (status refresh rate).
    func setForeground(_ foreground: Bool)
    /// A Control Center tile woke the app. Keeps checking for a connection for a
    /// moment, because nothing else notices one while the app has no window.
    func watchForPeer()
}
