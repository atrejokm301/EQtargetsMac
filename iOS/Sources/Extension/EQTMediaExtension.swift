//
//  EQTMediaExtension.swift
//  EQtargets (iOS)
//
//  Puts one "EQtargets" row in the system output picker. When it is picked, the
//  system hands this process the audio other apps are playing. The extension
//  cannot open an audio session, so it forwards the samples to the app, which
//  runs the EQ and plays the result on the output that was in use before.
//
//  Adapted from ios27-media-device-passthrough (MIT No Attribution). The
//  decisions below were measured on a device by that project:
//  - `requiredNetworkEndpoints` must name a real, reachable port. With port 0
//    the route falls back to the speaker about 1.5 s after being picked.
//  - The audio device must be published from `activateDevice`, before sample
//    delivery, or the system shows "Unable to Connect".
//  - The process must end after a deactivation, but not on the same turn. The
//    system still takes an assertion on it during cleanup, and a missing process
//    counts as an activation failure that evicts the row from its cache.
//

import ExtensionFoundation
import Foundation
import MediaDevice
import Network
import UniformTypeIdentifiers
import os

private let log = Logger(subsystem: EQT_LOG_SUBSYSTEM, category: "extension")

@main
@available(iOS 27.0, *)
final class EQTMediaExtension: MediaDeviceExtension, RealtimeSampleHandling {

    // MARK: Identity

    var protocolType: UTType { UTType(exportedAs: EQT_PROTOCOL_ID) }
    var supportsSimultaneousSessions: Bool { false }
    lazy var routingManager: MediaDeviceRoutingManager = .routingManager(for: self)

    private static let deviceUUID = UUID(uuidString: EQT_ROUTE_DEVICE_UUID)!
    private static let quitGrace: TimeInterval = 2
    /// How long audio may flow with the app unreachable before giving the route
    /// back. Until then every app on the phone is silent.
    private static let unreachableSeconds = 5.0

    private static let linkEndpoint: NWEndpoint = .hostPort(
        host: .ipv4(.loopback),
        port: NWEndpoint.Port(rawValue: UInt16(EQT_LINK_PORT))!
    )

    /// Allocated once and never freed: the audio thread may still be pushing
    /// when delivery stops, and the process exits soon after a deactivation.
    private let sender: OpaquePointer? = EQTLinkSenderCreate(UInt16(EQT_LINK_PORT))

    private lazy var localDevice: MediaOutputDevice? = MediaOutputDevice(
        id: Self.deviceUUID,
        displayName: EQT_ROUTE_NAME,
        capabilities: [.realtimeAudioStreaming],
        canGroupWithCurrentlyActivatedDevices: false,
        deviceType: .hifiSpeaker,
        // The phone's own volume stays in charge. Any control here would stack
        // a second attenuation on top of it.
        volumeControl: .none,
        canMute: false,
        requiredNetworkEndpoints: [Self.linkEndpoint],
        txtRecords: [],
        supportsSimultaneousSessions: false
    )

    private var activeSession: MediaOutputSession?
    private var quitting = false
    private lazy var keyWaiter = LinkKeyWaiter()

    required init() {
        log.notice("extension init")
        // Retained for good: late callbacks must never reach a freed object, and
        // the process exits after each session anyway.
        let me = Unmanaged.passRetained(self)
        if let sender {
            EQTLinkSenderSetUnreachableHandler(sender, Self.unreachableSeconds, { context in
                let me = Unmanaged<EQTMediaExtension>.fromOpaque(context!)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        me.takeUnretainedValue().failSession("the app is not reachable")
                    }
                }
            }, me.toOpaque())
        }
        EQTDeviceDriver.shared.onAudioServerLost = {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    me.takeUnretainedValue().failSession("the audio server connection was lost")
                }
            }
        }
    }

    // MARK: Discovery

    func startDeviceDiscovery() {
        guard let device = localDevice else {
            log.error("MediaOutputDevice init returned nil")
            routingManager.discoveryFailed(MediaDeviceError(.discoveryFailed))
            return
        }
        log.notice("found device \(device.description, privacy: .public)")
        routingManager.foundDevice(device)
    }

    /// `lostDevice` is deliberately not called. This output exists for as long
    /// as the app is installed, and reporting it lost would discard the cached
    /// row the system uses to open the picker quickly.
    func stopDeviceDiscovery() {
        log.notice("stop discovery")
    }

    // MARK: Activation

    func activateDevice(_ device: MediaOutputDevice,
                        session: MediaOutputSession,
                        for deviceFeatures: MediaOutputDevice.Capabilities) {
        log.notice("activate features=\(deviceFeatures.description, privacy: .public)")
        // This process is on its way out, and a second registration in one
        // process leaves a dead port. Fail now: the next pick gets a fresh process.
        guard !quitting else {
            routingManager.failedToActivateDevice(device, session: session,
                                                  error: MediaDeviceError(.connectionFailed))
            return
        }
        let status = EQTDeviceDriver.shared.publish(withDeviceUID: Self.deviceUUID.uuidString)
        guard status == noErr else {
            log.error("plug-in registration failed OSStatus=\(status, privacy: .public)")
            routingManager.failedToActivateDevice(device, session: session,
                                                  error: MediaDeviceError(.connectionFailed))
            quit("registration failed")
            return
        }
        routingManager.activatedDevice(device, session: session)
    }

    func connectUsingPairingCode(_ pairingCode: String?,
                                 to device: MediaOutputDevice,
                                 session: MediaOutputSession) {
        routingManager.activatedDevice(device, session: session)
    }

    func deactivateDevice(_ device: MediaOutputDevice, session: MediaOutputSession) {
        log.notice("deactivate")
        quit("deactivated")
    }

    /// There is no unregister call, so the next activation must be the first
    /// registration in a fresh process.
    private func quit(_ reason: String) {
        guard !quitting else { return }
        quitting = true
        activeSession = nil
        log.notice("ending process: \(reason, privacy: .public)")
        EQTDeviceDriver.shared.stopCapture()
        EQTDeviceDriver.shared.unpublish()
        if let sender { EQTLinkSenderStop(sender) }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.quitGrace) {
            exit(0)
        }
    }

    /// Tells the system this route is dead so it can end the session and tell
    /// the user, instead of leaving every app silent with EQtargets selected.
    private func failSession(_ reason: String) {
        guard !quitting else { return }
        log.error("session failed: \(reason, privacy: .public)")
        if let activeSession {
            routingManager.sessionFailed(activeSession, error: MediaDeviceError(.sessionFailed))
        }
        quit(reason)
    }

    // MARK: Sample delivery

    func startRealtimeSampleDelivery(session: MediaOutputSession) {
        log.notice("start sample delivery")
        activeSession = session
        loadLinkKey()
        guard let sender, EQTLinkSenderStart(sender) == 0 else {
            failSession("the link could not start")
            return
        }
        EQTLinkSenderSetDelivering(sender, 1)
        EQTDeviceDriver.shared.startCapture(with: sender)
    }

    /// Without the key the link can't open, and the unreachable check gives the
    /// route back. The app makes the key the first time it opens, which may be
    /// moments after EQtargets was picked.
    private func loadLinkKey() {
        keyWaiter.look(isWanted: { [self] in !quitting && activeSession != nil },
                       found: { [self] key in
            if let sender { EQTLinkSenderSetKey(sender, key) }
        })
    }

    func stopRealtimeSampleDelivery(session: MediaOutputSession) {
        log.notice("stop sample delivery")
        EQTDeviceDriver.shared.stopCapture()
        // The connection stays open: the system can stop and restart delivery
        // in quick succession, and the app reads a lost peer as "another output
        // was picked".
        if let sender { EQTLinkSenderSetDelivering(sender, 0) }
    }

    // MARK: Volume (owned by the phone)

    func setVolume(_ volume: Float, for device: MediaOutputDevice) {}
    func volume(for device: MediaOutputDevice) -> Float { 1 }
    func changeVolume(by increments: Int, for device: MediaOutputDevice) {}
    func muteDevice(_ device: MediaOutputDevice) {}
    func isDeviceMuted(_ device: MediaOutputDevice) -> Bool { false }

    // MARK: URL playback (not supported)

    func startSession(_ session: MediaOutputSession, identifier: String?, url: URL) {
        routingManager.sessionFailed(session, error: MediaDeviceError(.sessionFailed))
    }

    func stopSession(_ session: MediaOutputSession) {}

    func sendData(_ data: Data, toApplication applicationIdentifier: String,
                  session: MediaOutputSession) {}
}
