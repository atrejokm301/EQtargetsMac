//
//  HeadphoneRemovalTests.swift
//  EQtargets (iOS)
//
//  Taking the headphones off must not blast the music from the speaker, must
//  never drop the sound between two pairs of headphones, and must never leave
//  the phone silent once the music is paused or the power is changed.
//

import AVFoundation
import XCTest

final class HeadphoneRemovalTests: XCTestCase {

    private let airPods = HeadphoneRemoval.Port(name: "Kevin\u{2019}s AirPods Pro", type: "BluetoothA2DPOutput")
    private let airPodsMax = HeadphoneRemoval.Port(name: "AirPods Max", type: "BluetoothA2DPOutput")
    private let wired = HeadphoneRemoval.Port(name: "Headphones", type: "Headphones")
    private let speaker = HeadphoneRemoval.Port(name: "Speaker", type: "Speaker")
    private let receiver = HeadphoneRemoval.Port(name: "Receiver", type: "Receiver")
    private let ownRoute = HeadphoneRemoval.Port(name: EQT_ROUTE_NAME, type: "AirPlay")

    private func mute(gone: Bool = true, from previous: [HeadphoneRemoval.Port]? = nil,
                      to new: [HeadphoneRemoval.Port]? = nil, live: Bool = true, peer: Bool = true,
                      active: Bool = true, muted: Bool = false) -> Bool {
        HeadphoneRemoval.shouldMute(deviceGone: gone, previousOutputs: previous ?? [airPods],
                                    newOutputs: new ?? [speaker], live: live, hasPeer: peer,
                                    streamActive: active, alreadyMuted: muted)
    }

    func test_builtInTypes_matchTheSDK() {
        XCTAssertEqual(HeadphoneRemoval.builtInOutputTypes,
                       [AVAudioSession.Port.builtInSpeaker.rawValue, AVAudioSession.Port.builtInReceiver.rawValue])
    }

    func test_headphonesOffWhileMusicPlaysThroughEQtargets_mutes() {
        XCTAssertTrue(mute())
        XCTAssertTrue(mute(from: [wired]), "wired too: any external output")
        XCTAssertTrue(mute(to: [receiver]), "the earpiece is the phone too")
    }

    func test_fromOnePairOfHeadphonesToAnother_neverMutes() {
        XCTAssertFalse(mute(to: [airPodsMax]), "the case Kevin first asked about must not drop the sound")
        XCTAssertFalse(mute(to: [speaker, airPodsMax]), "not only the phone")
        XCTAssertFalse(mute(to: []), "no output known yet")
    }

    func test_nothingPlaying_orNotOurs_doesNotMute() {
        XCTAssertFalse(mute(gone: false), "a new device, a category change or an override")
        XCTAssertFalse(mute(from: [speaker]), "the speaker going away is not headphones coming off")
        XCTAssertFalse(mute(from: [ownRoute]), "our own route is not a pair of headphones")
        XCTAssertFalse(mute(from: []))
        XCTAssertFalse(mute(live: false), "Off: EQtargets is not playing anything")
        XCTAssertFalse(mute(peer: false), "EQtargets is not picked: iOS pauses the music itself")
        XCTAssertFalse(mute(active: false), "already paused")
        XCTAssertFalse(mute(muted: true), "already muted")
    }

    func test_isExternal_onlyForOutputsThatAreNotThePhone() {
        XCTAssertTrue(HeadphoneRemoval.isExternal(airPods))
        XCTAssertTrue(HeadphoneRemoval.isExternal(.init(name: "Car", type: AVAudioSession.Port.carAudio.rawValue)))
        XCTAssertTrue(HeadphoneRemoval.isExternal(.init(name: "DAC", type: AVAudioSession.Port.usbAudio.rawValue)))
        XCTAssertFalse(HeadphoneRemoval.isExternal(speaker))
        XCTAssertFalse(HeadphoneRemoval.isExternal(receiver))
        XCTAssertFalse(HeadphoneRemoval.isExternal(ownRoute))
    }

    // MARK: The mute

    private func observe(_ m: inout RemovalMute, silence: Double = 0, external: Bool = false,
                         sincePeer: TimeInterval = 0) -> RemovalMute.Release? {
        m.observe(secondsOfSilence: silence, onExternalOutput: external, secondsSincePeer: sincePeer)
    }

    func test_mute_staysOnWhileTheSongKeepsPlaying_withNoTimerOfItsOwn() {
        var m = RemovalMute()
        m.begin()
        for _ in 1 ... 600 { XCTAssertNil(observe(&m, silence: 0)) }
        XCTAssertTrue(m.isMuted, "the speaker must never start playing on its own")
    }

    func test_mute_liftsTwoSecondsIntoAPause_soPlayOnTheSpeakerIsHeard() {
        var m = RemovalMute()
        m.begin()
        XCTAssertNil(observe(&m, silence: RemovalMute.pausedAfterSeconds - 0.01), "a gap between songs")
        XCTAssertEqual(observe(&m, silence: RemovalMute.pausedAfterSeconds), .musicPaused)
        XCTAssertFalse(m.isMuted)
    }

    func test_mute_rightAfterAnEngineRestart_withNoAudioYet_holds() {
        // Headphone removal is exactly when the engine restarts. The silence
        // count starts at 0 then, so the restart never reads as a pause.
        var run = SilenceRun(sampleRate: 48_000)
        var m = RemovalMute()
        m.begin()
        XCTAssertNil(observe(&m, silence: Double(run.frames) / 48_000))
        run.advance(4_800, silent: true)                // 0.1 s of underrun while it refills
        XCTAssertNil(observe(&m, silence: Double(run.frames) / 48_000))
        XCTAssertTrue(m.isMuted)
    }

    func test_mute_liftsWhenHeadphonesComeBack() {
        var m = RemovalMute()
        m.begin()
        XCTAssertEqual(observe(&m, external: true), .headphonesBack)
        XCTAssertFalse(m.isMuted)
    }

    func test_mute_aBriefLinkDrop_keepsIt_aRealUnpick_liftsIt() {
        var m = RemovalMute()
        m.begin()
        XCTAssertNil(observe(&m, sincePeer: LinkPowerState.peerGraceSeconds - 0.1), "the link reconnects")
        XCTAssertTrue(m.isMuted)
        XCTAssertEqual(observe(&m, sincePeer: LinkPowerState.peerGraceSeconds), .notPicked)
        XCTAssertFalse(m.isMuted)
    }

    func test_mute_notStarted_orCancelled_neverReleasesAnything() {
        var m = RemovalMute()
        XCTAssertNil(observe(&m, silence: 60, external: true))
        m.begin()
        m.cancel()                              // the power was changed
        XCTAssertFalse(m.isMuted)
        XCTAssertNil(observe(&m, silence: 60))
    }

    // MARK: The silence count (render thread)

    func test_silenceRun_startsAtZero_countsUnbrokenSilence_andAnySoundResetsIt() {
        var run = SilenceRun(sampleRate: 48_000)
        XCTAssertEqual(run.frames, 0, "a fresh start is not a long silence")
        run.advance(480, silent: true)
        run.advance(480, silent: true)
        XCTAssertEqual(run.frames, 960)
        run.advance(480, silent: false)             // one audible block between two looks
        XCTAssertEqual(run.frames, 0, "a short sound is never missed")
    }

    func test_silenceRun_isCapped_soItCannotOverflow() {
        var run = SilenceRun(sampleRate: 48_000)
        for _ in 0 ..< 10_000 { run.advance(4_096, silent: true) }
        XCTAssertEqual(run.frames, Int(SilenceRun.capSeconds * 48_000))
        XCTAssertGreaterThan(SilenceRun.capSeconds, RemovalMute.pausedAfterSeconds, "the cap must not hide a pause")
        run.advance(-5, silent: true)
        XCTAssertEqual(run.frames, run.cap, "a bad count never lowers it")
    }

    // MARK: The engine wiring (LinkEngine is not in this target, so its source is read)

    private func engineSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/Audio/LinkEngine.swift"), encoding: .utf8)
    }

    private func body(of signature: String, in code: String) throws -> Substring {
        let start = try XCTUnwrap(code.range(of: signature), "missing \(signature)")
        let end = try XCTUnwrap(code.range(of: "\n    }\n", range: start.upperBound ..< code.endIndex))
        return code[start.upperBound ..< end.lowerBound]
    }

    func test_engine_everyPowerChangeLiftsTheMute() throws {
        // With EQtargets selected, Off only bypasses, and the mute applies in
        // bypass: without this the whole phone would stay silent.
        let perform = try body(of: "private func perform(_ effect: LinkPowerState.Effect) {", in: try engineSource())
        XCTAssertTrue(perform.contains("liftRemovalMute("))
    }

    func test_engine_theMuteIsTheChainsRampedMute_notTheHardZero() throws {
        let code = try engineSource()
        let push = try body(of: "private func pushParameters() {", in: code)
        XCTAssertTrue(push.contains("if removalMute.isMuted { p.outputMuted = true }"))
        XCTAssertFalse(code.contains("setMuted(removalMute"), "setMuted zeroes the output with no ramp")
    }

    func test_engine_turningOffClearsTheMute() throws {
        let stop = try body(of: "private func stopEngine() {", in: try engineSource())
        XCTAssertTrue(stop.contains("liftRemovalMute("))
    }
}
