//
//  LogicChecks.swift
//  eqt-engine --offline-selftest
//
//  Rule-level checks of everything in Sources/EQTAudio that can be exercised
//  without changing the system: routing policy, volume law, latency math,
//  feedback guard, ring watchdog, listener add/remove pairing, the render
//  callback's handling of odd buffer lists, and the installer's quoting.
//

import AudioToolbox
import CoreAudio
import Foundation

enum LogicChecks {

    static func run(_ r: SelfTestReport) {
        routing(r)
        volume(r)
        latency(r)
        burstGuard(r)
        watchdog(r)
        listeners(r)
        transport(r)
        ringOpen(r)
        callback(r)
        installer(r)
    }

    // MARK: Routing

    private static func dev(_ uid: String, _ name: String, _ t: OutputTransport, _ id: AudioObjectID) -> OutputDevice {
        OutputDevice(objectID: id, uid: uid, name: name, transport: t, nominalSampleRate: 48_000, hasHardwareVolume: true)
    }

    private static func routing(_ r: SelfTestReport) {
        r.section("Routing rules (ARCHITECTURE.md §6)")
        let speakers = dev("BuiltInSpeakerDevice", "MacBook Pro Speakers", .builtIn, 10)
        let airpods = dev("AA-BB-CC", "AirPods Pro", .bluetooth, 11)
        let dac = dev("USB-DAC-1", "USB DAC", .usb, 12)
        let hdmi = dev("HDMI-1", "LG TV", .hdmi, 13)
        let ours = dev(EQT_DEVICE_UID, "EQtargets Audio", .virtual, 14)
        let all = [airpods, dac, speakers, ours]
        let P = RoutingPolicy.self

        r.check("power-on: pinned device wins when present",
                P.powerOnChoice(devices: all, pinnedUID: dac.uid, macDefaultUID: airpods.uid, recentUIDs: [speakers.uid])?.uid == dac.uid)
        r.check("power-on: pinned absent → macOS's current default",
                P.powerOnChoice(devices: all, pinnedUID: "gone", macDefaultUID: airpods.uid, recentUIDs: [speakers.uid])?.uid == airpods.uid)
        r.check("power-on: default is EQtargets Audio → last real device",
                P.powerOnChoice(devices: all, pinnedUID: nil, macDefaultUID: ours.uid, recentUIDs: [dac.uid])?.uid == dac.uid)
        r.check("power-on: last device absent → built-in",
                P.powerOnChoice(devices: all, pinnedUID: nil, macDefaultUID: nil, recentUIDs: ["gone"])?.uid == speakers.uid)
        r.check("power-on: no built-in → any real device, never ours",
                P.powerOnChoice(devices: [ours, hdmi], pinnedUID: nil, macDefaultUID: ours.uid, recentUIDs: [])?.uid == hdmi.uid)
        r.check("power-on: only EQtargets Audio present → refuse (nil)",
                P.powerOnChoice(devices: [ours], pinnedUID: ours.uid, macDefaultUID: ours.uid, recentUIDs: [ours.uid]) == nil)
        r.check("power-on: pinning EQtargets Audio itself is ignored",
                P.powerOnChoice(devices: all, pinnedUID: ours.uid, macDefaultUID: nil, recentUIDs: [])?.uid == speakers.uid)
        r.check("fallback: never the device that vanished; previous device next",
                P.fallbackChoice(devices: all, pinnedUID: nil, recentUIDs: [airpods.uid, dac.uid], excluding: airpods.uid)?.uid == dac.uid)
        r.check("fallback: pinned first",
                P.fallbackChoice(devices: all, pinnedUID: speakers.uid, recentUIDs: [dac.uid], excluding: airpods.uid)?.uid == speakers.uid)
        r.check("fallback: nothing recent → built-in",
                P.fallbackChoice(devices: all, pinnedUID: nil, recentUIDs: [], excluding: dac.uid)?.uid == speakers.uid)
        r.check("restore: the device we were playing on",
                P.restoreChoice(devices: all, currentUID: dac.uid, recentUIDs: [airpods.uid])?.uid == dac.uid)
        r.check("restore: never EQtargets Audio",
                P.restoreChoice(devices: [ours, airpods], currentUID: ours.uid, recentUIDs: [ours.uid])?.uid == airpods.uid)
        r.check("restore: nothing real → nil (leave macOS alone)",
                P.restoreChoice(devices: [ours], currentUID: nil, recentUIDs: []) == nil)
        r.check("restore after a refused route: never the device that refused (back to the one that played)",
                P.restoreChoice(devices: all, currentUID: speakers.uid, recentUIDs: [dac.uid], excluding: dac.uid)?.uid == speakers.uid
                    && P.restoreChoice(devices: all, currentUID: dac.uid, recentUIDs: [dac.uid, airpods.uid], excluding: dac.uid)?.uid == airpods.uid)
        // Final review: excluding the ONLY real output left nil → macOS stayed on
        // EQtargets Audio with nothing reading it (silence). Unprocessed sound wins.
        r.check("restore after a refused route: the refusing device is the ONLY real output → still restore to it (never strand the Mac on EQtargets Audio)",
                P.restoreChoice(devices: [speakers, ours], currentUID: speakers.uid, recentUIDs: [], excluding: speakers.uid)?.uid == speakers.uid)
        // Never move music onto a device anyone nearby can hear, unless the
        // user was just listening on it.
        r.check("restore after a refused route: AirPods refuse while on AirPods → back to the AirPods, NOT the laptop speakers",
                P.restoreChoice(devices: all, currentUID: airpods.uid, recentUIDs: [airpods.uid, speakers.uid], excluding: airpods.uid)?.uid == airpods.uid)
        r.check("restore after a refused route: a quiet recent device (USB DAC) beats the refusing AirPods; loud ones (speakers, TV) are skipped",
                P.restoreChoice(devices: all + [hdmi], currentUID: nil, recentUIDs: [airpods.uid, hdmi.uid, speakers.uid, dac.uid], excluding: airpods.uid)?.uid == dac.uid)
        r.check("restore after a refused route: power-on with nothing quiet in recents → the refusing device, never the speakers",
                P.restoreChoice(devices: all, currentUID: nil, recentUIDs: [speakers.uid], excluding: dac.uid)?.uid == dac.uid)
        let blackhole = dev("BlackHole2ch_UID", "BlackHole 2ch", .virtual, 17)
        let multi = dev("MultiOut-1", "Multi-Output (Speakers + AirPods)", .aggregate, 18)
        r.check("personal devices: Bluetooth, USB, Thunderbolt yes; built-in, HDMI, DisplayPort, AirPlay, virtual, aggregate no",
                P.isPersonal(airpods) && P.isPersonal(dac) && P.isPersonal(dev("TB", "TB DAC", .thunderbolt, 19))
                    && !P.isPersonal(speakers) && !P.isPersonal(hdmi) && !P.isPersonal(dev("DP", "Monitor", .displayPort, 15))
                    && !P.isPersonal(dev("AP", "HomePod", .airPlay, 16)) && !P.isPersonal(blackhole) && !P.isPersonal(multi))
        r.check("restore after a refused route: a recent virtual (silent) or aggregate (may include speakers) is never the target",
                P.restoreChoice(devices: all + [blackhole, multi], currentUID: nil, recentUIDs: [blackhole.uid, multi.uid], excluding: airpods.uid)?.uid == airpods.uid)
        r.check("restore: `excluding` names a device that is gone → old behaviour (current → recent → built-in)",
                P.restoreChoice(devices: all, currentUID: nil, recentUIDs: [dac.uid], excluding: "unplugged")?.uid == dac.uid
                    && P.restoreChoice(devices: all, currentUID: nil, recentUIDs: [], excluding: "unplugged")?.uid == speakers.uid)

        // Follow macOS vs. a pin (review fix: an ABSENT pin used to reject every macOS pick).
        r.check("follow macOS: no pin → follow", P.followsMacDefault(pinnedUID: nil, devices: all))
        r.check("follow macOS: pinned device present → keep the pin", !P.followsMacDefault(pinnedUID: dac.uid, devices: all))
        r.check("follow macOS: pinned device ABSENT → follow macOS's pick (AirPods connected at a café)",
                P.followsMacDefault(pinnedUID: "desk-DAC-at-home", devices: all))
        r.check("follow macOS: a pin on EQtargets Audio itself counts as absent", P.followsMacDefault(pinnedUID: ours.uid, devices: all))
        // Default-output change (a Control Center pick) → where to play.
        r.check("pick, no pin: play on the picked device",
                P.defaultChangeTarget(picked: dac, pinnedUID: nil, currentUID: speakers.uid, devices: all)?.uid == dac.uid)
        r.check("pick, no pin: the device already playing → stay (nil)",
                P.defaultChangeTarget(picked: speakers, pinnedUID: nil, currentUID: speakers.uid, devices: all) == nil)
        r.check("pick, pin present and playing on it: any pick stays on the pin (nil)",
                P.defaultChangeTarget(picked: speakers, pinnedUID: airpods.uid, currentUID: airpods.uid, devices: all) == nil)
        r.check("regression: pinned AirPods present, stuck on the speakers, user picks the AirPods → AirPods",
                P.defaultChangeTarget(picked: airpods, pinnedUID: airpods.uid, currentUID: speakers.uid, devices: all)?.uid == airpods.uid)
        r.check("regression: pinned AirPods present, stuck on the speakers, any other pick → back to the pin",
                P.defaultChangeTarget(picked: dac, pinnedUID: airpods.uid, currentUID: speakers.uid, devices: all)?.uid == airpods.uid)
        r.check("pick, pin absent: follow the pick (no bounce to a device that isn't there)",
                P.defaultChangeTarget(picked: dac, pinnedUID: "desk-DAC-at-home", currentUID: speakers.uid, devices: all)?.uid == dac.uid)
        r.check("pick of EQtargets Audio itself is never a target",
                P.defaultChangeTarget(picked: ours, pinnedUID: nil, currentUID: speakers.uid, devices: all) == nil)

        // Return to the device we fell back from (review fix: it was never re-adopted).
        r.check("return: the device we fell back from is back → return to it",
                P.returnChoice(devices: all, fellBackFrom: dac.uid, currentUID: speakers.uid, pinnedUID: nil)?.uid == dac.uid)
        r.check("return: it isn't back yet → stay",
                P.returnChoice(devices: [speakers, ours], fellBackFrom: dac.uid, currentUID: speakers.uid, pinnedUID: nil) == nil)
        r.check("return: nothing to return to / already on it → stay",
                P.returnChoice(devices: all, fellBackFrom: nil, currentUID: speakers.uid, pinnedUID: nil) == nil
                    && P.returnChoice(devices: all, fellBackFrom: dac.uid, currentUID: dac.uid, pinnedUID: nil) == nil)
        r.check("return: a present pin owns the return path (no automatic return elsewhere)",
                P.returnChoice(devices: all, fellBackFrom: dac.uid, currentUID: speakers.uid, pinnedUID: airpods.uid) == nil)
        r.check("return: an absent pin doesn't block it",
                P.returnChoice(devices: all, fellBackFrom: dac.uid, currentUID: speakers.uid, pinnedUID: "gone")?.uid == dac.uid)
        r.check("return: never to EQtargets Audio",
                P.returnChoice(devices: all, fellBackFrom: ours.uid, currentUID: speakers.uid, pinnedUID: nil) == nil)

        // Default output stranded on EQtargets Audio (review fix: Off + Sound-menu pick / coreaudiod fallback = silence).
        r.check("stranded default: ours, engine Off, nobody else reads → hand it back",
                P.mustReleaseDefault(defaultIsOurs: true, poweredAndRouted: false, otherReaders: 0))
        r.check("stranded default: older driver (reader count unknown) → hand it back",
                P.mustReleaseDefault(defaultIsOurs: true, poweredAndRouted: false, otherReaders: nil))
        r.check("stranded default: another process reads the ring (second instance routed) → leave it",
                !P.mustReleaseDefault(defaultIsOurs: true, poweredAndRouted: false, otherReaders: 1))
        r.check("stranded default: we are On and routed → it's ours to keep",
                !P.mustReleaseDefault(defaultIsOurs: true, poweredAndRouted: true, otherReaders: 0))
        r.check("stranded default: macOS isn't on EQtargets Audio → nothing to do",
                !P.mustReleaseDefault(defaultIsOurs: false, poweredAndRouted: false, otherReaders: 0))
        // Final-review follow-up: the driver's count includes THIS process while it is
        // still attached (teardown couldn't move the default) — that must not count as
        // "someone else is listening", or the Mac stays silent.
        r.check("other readers: our own attachment is not 'someone else' (1 reported, attached here → 0)",
                P.otherReaders(reported: 1, attachedHere: true) == 0
                    && P.mustReleaseDefault(defaultIsOurs: true, poweredAndRouted: false,
                                            otherReaders: P.otherReaders(reported: 1, attachedHere: true)))
        r.check("other readers: a second instance still counts (2 reported, attached here → 1; 1 reported, not attached → 1)",
                P.otherReaders(reported: 2, attachedHere: true) == 1 && P.otherReaders(reported: 1, attachedHere: false) == 1)
        r.check("other readers: unknown / garbage counts (nil, NaN, -5, inf) never go negative or trap",
                P.otherReaders(reported: nil, attachedHere: true) == nil && P.otherReaders(reported: .nan, attachedHere: true) == 0
                    && P.otherReaders(reported: -5, attachedHere: false) == 0 && P.otherReaders(reported: .infinity, attachedHere: true) == 0)

        let rates: [(Double, Double)] = [(48_000, 48_000), (44_100, 44_100), (96_000, 96_000), (192_000, 192_000),
                                         (32_000, 44_100), (22_050, 44_100), (384_000, 192_000), (.nan, 48_000)]
        let rateOK = rates.allSatisfy { P.virtualRate(matching: $0.0) == $0.1 }
        r.check("virtual rate matches the real device's (or the nearest driver rate above it)", rateOK,
                rates.map { "\($0.0)→\(P.virtualRate(matching: $0.0))" }.joined(separator: " "))

        let mru = P.remember(dac.uid, in: [airpods.uid, dac.uid, speakers.uid])
        r.check("recent list: moved to front, no duplicates", mru == [dac.uid, airpods.uid, speakers.uid])
        r.check("recent list: EQtargets Audio never remembered", P.remember(ours.uid, in: [dac.uid]) == [dac.uid])
        let sorted = P.sorted([speakers, dac, airpods], currentUID: dac.uid).map(\.uid)
        r.check("device list: current first, then by name", sorted == [dac.uid, airpods.uid, speakers.uid], sorted.joined(separator: ","))
    }

    // MARK: Volume

    private static func volume(_ r: SelfTestReport) {
        r.section("Volume law (driver taper, digital fallback)")
        let refs: [(Double, Double)] = [(0.25, -30.2), (0.5, -15.9), (0.75, -6.8), (1, 0), (0, -64)]
        let worst = refs.map { abs(VolumeLaw.decibels(forScalar: $0.0) - $0.1) }.max() ?? 99
        r.check("taper matches Driver/README.md reference points (±0.05 dB)", worst <= 0.05, "worst \(worst.f(3)) dB")

        var app = ChainParameters()
        app.outputGainDB = -3
        let hw = VolumeLaw.fold(app, volume: 0.5, muted: true, volumeDB: nil, hardwareVolume: true, hardwareMute: true)
        r.check("hardware volume + mute: chain untouched", hw == app)
        let dig = VolumeLaw.fold(app, volume: 0.5, muted: false, volumeDB: nil, hardwareVolume: false, hardwareMute: false)
        r.check("no hardware volume: taper dB added to the app's gain",
                abs(dig.outputGainDB - (-3 + VolumeLaw.decibels(forScalar: 0.5))) < 1e-9 && !dig.outputMuted,
                "\(dig.outputGainDB.f(2)) dB")
        let devDB = VolumeLaw.fold(ChainParameters(), volume: 0.5, muted: false, volumeDB: -20, hardwareVolume: false, hardwareMute: false)
        r.check("no hardware volume: the device's own dB wins over the formula", devDB.outputGainDB == -20)
        let zero = VolumeLaw.fold(ChainParameters(), volume: 0, muted: false, volumeDB: -64, hardwareVolume: false, hardwareMute: false)
        r.check("volume at 0 → silence", zero.outputMuted)
        let muteOnly = VolumeLaw.fold(app, volume: 0.8, muted: true, volumeDB: nil, hardwareVolume: true, hardwareMute: false)
        r.check("hardware volume but no hardware mute → mute digitally, gain untouched",
                muteOnly.outputMuted && muteOnly.outputGainDB == -3)
        let nanVol = VolumeLaw.fold(ChainParameters(), volume: .nan, muted: false, volumeDB: .nan, hardwareVolume: false, hardwareMute: false)
        r.check("NaN volume never reaches the chain", nanVol.outputGainDB.isFinite && !nanVol.outputMuted, "\(nanVol.outputGainDB)")

        // Per-channel-only devices (L/R elements): keep the balance (review fix: it was centred).
        let lr: [Float] = [0.6, 0.4]
        r.check("L/R device volume = its loudest channel (as macOS shows it)", VolumeLaw.combinedVolume(lr) == 0.6)
        let down = VolumeLaw.channelVolumes(current: lr, target: 0.3)
        r.check("volume key on an off-centre L/R device: balance kept (0.6/0.4 → 0.3/0.2)",
                abs(down[0] - 0.3) < 1e-6 && abs(down[1] - 0.2) < 1e-6, "\(down)")
        r.check("…and reads back as exactly the new volume (no echo, no creep)", VolumeLaw.combinedVolume(down) == 0.3)
        let up = VolumeLaw.channelVolumes(current: [0.5, 0.25], target: 1)
        r.check("volume up to 1: loudest at 1, ratio kept, nothing above 1", up == [1, 0.5], "\(up)")
        r.check("both channels silent (no balance to keep) → both get the volume",
                VolumeLaw.channelVolumes(current: [0, 0], target: 0.5) == [0.5, 0.5])
        r.check("hard-panned stays hard-panned", VolumeLaw.channelVolumes(current: [0.8, 0], target: 0.4) == [0.4, 0])
        r.check("NaN anywhere → no balance trusted, never NaN out",
                VolumeLaw.combinedVolume([.nan, 0.5]) == nil && VolumeLaw.channelVolumes(current: [.nan, 0.5], target: 0.7) == [0.7, 0.7]
                    && VolumeLaw.channelVolumes(current: [0.6, 0.4], target: .nan) == [0, 0])
    }

    // MARK: Latency

    private static func latency(_ r: SelfTestReport) {
        r.section("Latency math")
        let ms = LatencyMath.engineLatencyMs(ringSeconds: 0.027, chainFrames: 72, deviceFrames: 528, outputRate: 48_000)
        r.check("UI latency = ring + chain + device", abs(ms - 39.5) < 1e-9, "\(ms.f(3)) ms")
        let frames = LatencyMath.driverReportFrames(ringTargetFrames: 1298, chainFrames: 72, deviceFrames: 528,
                                                    outputRate: 48_000, sourceRate: 44_100)
        r.check("'eqtl' report in VIRTUAL-rate frames (44.1 k source, 48 k device)", frames == 1849, "\(frames)")
        r.check("'eqtl' report never negative / NaN",
                LatencyMath.driverReportFrames(ringTargetFrames: .nan, chainFrames: -5, deviceFrames: -5, outputRate: 0, sourceRate: 48_000) == 0)
        // Review fix: a hostile ring header rate (+inf, 1e300) reached Int() and trapped on the main thread.
        let hostile: [(Double, Double, Double)] = [(1298, 48_000, .infinity), (1298, 48_000, 1e300), (1298, .infinity, 48_000),
                                                   (1298, 48_000, .nan), (1e308, 48_000, 48_000), (1298, 1e-300, 48_000)]
        let worst = hostile.map { LatencyMath.driverReportFrames(ringTargetFrames: $0.0, chainFrames: 72, deviceFrames: 528,
                                                                 outputRate: $0.1, sourceRate: $0.2) }
        r.check("'eqtl' report survives non-finite / absurd rates and fills (no trap, 0…1e9 frames)",
                worst.allSatisfy { $0 >= 0 && $0 <= 1_000_000_000 }, "\(worst)")

        // Latency reports are configuration changes now (an IO restart each): one per route, then only big moves.
        r.check("latency report: the first one on a route is always sent", LatencyMath.shouldReport(9_000, last: -1, sourceRate: 48_000))
        r.check("latency report: a move under 20 ms is not re-sent (no IO restart when a stream starts)",
                !LatencyMath.shouldReport(9_000 + 959, last: 9_000, sourceRate: 48_000)
                    && !LatencyMath.shouldReport(9_000 - 366, last: 9_000, sourceRate: 48_000))
        r.check("latency report: a move of 20 ms or more is re-sent (speakers → AirPods, a 4096-frame writer)",
                LatencyMath.shouldReport(9_000 + 960, last: 9_000, sourceRate: 48_000)
                    && LatencyMath.shouldReport(2_400, last: 9_000, sourceRate: 48_000))
        r.check("latency report: the threshold scales with the rate, and survives a nonsense rate",
                !LatencyMath.shouldReport(9_000 + 3_000, last: 9_000, sourceRate: 192_000)
                    && LatencyMath.shouldReport(9_000 + 960, last: 9_000, sourceRate: .nan))
        r.check("ring target estimate = the reader's rule (512/512 → 1298 frames, AirPods 256/256 → 786)",
                RingReader.targetFill(writerFrames: 512, outputFramesInSource: 512, kernelTaps: ResamplerTable.baseTaps) == 1_298
                    && RingReader.targetFill(writerFrames: 256, outputFramesInSource: 256, kernelTaps: ResamplerTable.baseTaps) == 786,
                "\(RingReader.targetFill(writerFrames: 512, outputFramesInSource: 512, kernelTaps: ResamplerTable.baseTaps))")

        // Output IO buffer request (lower latency: the buffer is paid in the ring AND at the device).
        r.check("IO buffer: asks for the preferred size on a default 512 device",
                HAL.bufferRequest(current: 512, preferred: 128, range: 15 ... 4_096) == 128)
        r.check("IO buffer: clamped up to a device's minimum (Bluetooth-style 256…4096)",
                HAL.bufferRequest(current: 512, preferred: 128, range: 256 ... 4_096) == 256)
        r.check("IO buffer: nothing set when the minimum is the current size",
                HAL.bufferRequest(current: 512, preferred: 128, range: 512 ... 4_096) == nil)
        r.check("IO buffer: never made larger than the device runs now",
                HAL.bufferRequest(current: 64, preferred: 128, range: 15 ... 4_096) == nil
                    && HAL.bufferRequest(current: 128, preferred: 128, range: nil) == nil)
        r.check("IO buffer: no range reported → the preferred size; nonsense preference → nothing",
                HAL.bufferRequest(current: 512, preferred: 128, range: nil) == 128
                    && HAL.bufferRequest(current: 512, preferred: 0, range: nil) == nil)
    }

    private static func burstGuard(_ r: SelfTestReport) {
        r.section("Follow-macOS feedback guard")
        var g = BurstGuard(limit: 6, window: 10)
        let firstSix = (0 ..< 6).allSatisfy { g.record(at: Double($0)) }
        let seventh = g.record(at: 5.5)
        var g2 = BurstGuard(limit: 6, window: 10)
        let spaced = (0 ..< 20).allSatisfy { g2.record(at: Double($0) * 2) }
        r.check("6 output changes in 10 s are followed", firstSix)
        r.check("the 7th within 10 s trips the guard (engine steps aside)", !seventh)
        r.check("one change every 2 s is followed forever", spaced)
    }

    // MARK: Watchdog

    private static func watchdog(_ r: SelfTestReport) {
        r.section("Ring watchdog (dead mapping → re-open)")
        var w = RingWatchdog()
        var head: Int64 = 0
        var fired = false
        for i in 0 ..< 20 { head += 512; fired = fired || w.observe(valid: true, head: head, stamp: UInt64(i + 1), deviceRunning: true, dt: 0.5) }
        r.check("advancing ring: never re-opened", !fired)
        var seq: [Bool] = []
        for _ in 0 ..< 4 { seq.append(w.observe(valid: true, head: head, stamp: 20, deviceRunning: true, dt: 0.5)) }
        r.check("frozen header while the device runs: re-open after 2 s", seq == [false, false, false, true], "\(seq)")
        w.reset()
        var idle = false
        for _ in 0 ..< 20 { idle = idle || w.observe(valid: true, head: head, stamp: 20, deviceRunning: false, dt: 0.5) }
        r.check("frozen header while nothing plays: never re-opened", !idle)
        w.reset()
        var inv: [Bool] = []
        for _ in 0 ..< 4 { inv.append(w.observe(valid: false, head: 0, stamp: 0, deviceRunning: false, dt: 0.5)) }
        r.check("invalid header for 2 s: re-open", inv == [false, false, false, true], "\(inv)")
        w.reset()
        let blip = w.observe(valid: false, head: 0, stamp: 0, deviceRunning: true, dt: 0.5)
            || w.observe(valid: true, head: 512, stamp: 1, deviceRunning: true, dt: 0.5)
            || w.observe(valid: false, head: 0, stamp: 0, deviceRunning: true, dt: 0.5)
        r.check("brief invalid blips (driver re-initialising the header): no re-open", !blip)
    }

    // MARK: Listeners

    private final class Recorder {
        var added: [ObjectIdentifier] = []
        var removed: [ObjectIdentifier] = []
        var blocks: [HALListenerBlock] = []
        var addStatus: OSStatus = noErr
    }

    private static func listeners(_ r: SelfTestReport) {
        r.section("Property listener bookkeeping")
        let rec = Recorder()
        let api = HALListenerAPI(
            add: { _, _, _, block in
                rec.added.append(ObjectIdentifier(unsafeBitCast(block, to: AnyObject.self)))
                rec.blocks.append(block)
                return rec.addStatus
            },
            remove: { _, _, _, block in
                rec.removed.append(ObjectIdentifier(unsafeBitCast(block, to: AnyObject.self)))
                return noErr
            })
        let q = DispatchQueue(label: "test")
        var fired = 0
        let l = PropertyListener(object: 1, address: HAL.address(kAudioHardwarePropertyDevices), queue: q, api: api) { fired += 1 }
        var addr = HAL.address(kAudioHardwarePropertyDevices)
        rec.blocks.last?(1, &addr)
        r.check("the registered block calls the handler", fired == 1)
        l.cancel()
        l.cancel()
        r.check("remove gets the SAME block object that was added", rec.added.count == 1 && rec.removed == rec.added)
        r.check("cancel is idempotent (one removal)", rec.removed.count == 1)
        do {
            _ = PropertyListener(object: 1, address: addr, queue: q, api: api) {}
        }
        r.check("a dropped listener removes itself (deinit)", rec.removed.count == 2 && rec.removed[1] == rec.added[1])
        rec.addStatus = kAudioHardwareBadObjectError
        let failed = PropertyListener(object: 1, address: addr, queue: q, api: api) {}
        failed.cancel()
        r.check("a listener whose add failed never calls remove", !failed.isRegistered && rec.removed.count == 2)
    }

    private static func transport(_ r: SelfTestReport) {
        r.section("Transport mapping")
        let table: [(UInt32, OutputTransport)] = [
            (kAudioDeviceTransportTypeBuiltIn, .builtIn), (kAudioDeviceTransportTypeBluetooth, .bluetooth),
            (kAudioDeviceTransportTypeBluetoothLE, .bluetooth), (kAudioDeviceTransportTypeUSB, .usb),
            (kAudioDeviceTransportTypeHDMI, .hdmi), (kAudioDeviceTransportTypeDisplayPort, .displayPort),
            (kAudioDeviceTransportTypeAirPlay, .airPlay), (kAudioDeviceTransportTypeThunderbolt, .thunderbolt),
            (kAudioDeviceTransportTypeVirtual, .virtual), (kAudioDeviceTransportTypeAggregate, .aggregate),
            (kAudioDeviceTransportTypeAutoAggregate, .aggregate), (kAudioDeviceTransportTypePCI, .other), (0, .other),
        ]
        let bad = table.filter { OutputTransport(halTransport: $0.0) != $0.1 }
        r.check("HAL transport → OutputTransport (\(table.count) cases)", bad.isEmpty, bad.map { "\($0.0)" }.joined(separator: ","))
    }

    private static func ringOpen(_ r: SelfTestReport) {
        r.section("Ring mapping")
        let missing = RingMapping.open(name: "/eqt.selftest.\(getpid()).missing")
        if case .failure(.notFound) = missing { r.check("missing ring → .notFound (not a crash, not a create)", true) }
        else { r.check("missing ring → .notFound (not a crash, not a create)", false, "\(missing)") }
        let mem = RingMapping.inProcess()
        r.check("fresh in-process ring is invalid until the writer publishes magic", !mem.isValid)
        SimWriter.initialize(mem.mutableHeader!, sampleRate: 48_000)
        r.check("…and valid after (EQTRingHeaderIsValid)", mem.isValid && mem.sampleRate == 48_000 && mem.generation == 1)
        let other = RingMapping.inProcess()
        r.check("header comparison tells two ring objects apart", !mem.hasSameHeaderBytes(as: other) && mem.hasSameHeaderBytes(as: mem))
    }

    // MARK: Render callback edge cases

    private static func callback(_ r: SelfTestReport) {
        r.section("Render callback: odd buffer lists never crash and never leave garbage")
        let ring = RingMapping.inProcess()
        SimWriter.initialize(ring.mutableHeader!, sampleRate: 48_000)
        let reader = RingReader(header: ring.header)
        reader.configure(outputSampleRate: 48_000, outputMaxFrames: 4_096, outputBufferFrames: 512)
        let chain = ProcessingChain(maxFrames: 4_096, maxChannels: 2)
        chain.prepare(sampleRate: 48_000, channelCount: 2)
        let ctx = RenderContext(reader: reader, chain: chain, ring: ring, sampleRate: 48_000)
        let ref = Unmanaged.passUnretained(ctx).toOpaque()
        var stamp = AudioTimeStamp()
        let n = 256
        let storage = UnsafeMutablePointer<Float>.allocate(capacity: 4 * (n + 16))
        defer { storage.deallocate() }
        let abl = AudioBufferList.allocate(maximumBuffers: 3)
        defer { free(abl.unsafeMutablePointer) }
        func buf(_ i: Int) -> UnsafeMutablePointer<Float> { storage + i * (n + 16) }
        func prefill() { storage.update(repeating: .nan, count: 4 * (n + 16)) }
        func clean(_ i: Int, _ count: Int) -> Bool { (0 ..< count).allSatisfy { buf(i)[$0] == 0 } }

        var flags = AudioUnitRenderActionFlags()
        let callsBefore = ctx.renderCalls.load(ordering: .relaxed)
        let s0 = EQTRenderCallback(ref, &flags, &stamp, 0, UInt32(n), nil)
        r.check("nil buffer list: noErr, nothing rendered", s0 == noErr && ctx.renderCalls.load(ordering: .relaxed) == callsBefore)

        // Normal stereo (empty ring → silence, but every frame written).
        prefill()
        abl.count = 2
        abl[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(n * 4), mData: buf(0))
        abl[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(n * 4), mData: buf(1))
        flags = []
        _ = EQTRenderCallback(ref, &flags, &stamp, 0, UInt32(n), abl.unsafeMutablePointer)
        r.check("stereo: every frame written (NaN prefill gone), no silence flag",
                clean(0, n) && clean(1, n) && !flags.contains(.unitRenderAction_OutputIsSilence))

        // Too-small buffer: rejected, zeroed within its OWN size only.
        prefill()
        abl[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32((n - 8) * 4), mData: buf(0))
        abl[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(n * 4), mData: buf(1))
        flags = []
        let rej0 = ctx.rejectedBuffers.load(ordering: .relaxed)
        _ = EQTRenderCallback(ref, &flags, &stamp, 0, UInt32(n), abl.unsafeMutablePointer)
        r.check("short buffer: rejected → silence flag, zeroed, nothing past its end touched",
                flags.contains(.unitRenderAction_OutputIsSilence) && clean(0, n - 8) && buf(0)[n - 8].isNaN
                    && clean(1, n) && ctx.rejectedBuffers.load(ordering: .relaxed) == rej0 + 1)

        // nil mData.
        prefill()
        abl[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(n * 4), mData: nil)
        abl[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(n * 4), mData: buf(1))
        flags = []
        _ = EQTRenderCallback(ref, &flags, &stamp, 0, UInt32(n), abl.unsafeMutablePointer)
        r.check("nil mData: rejected, other buffer zeroed", flags.contains(.unitRenderAction_OutputIsSilence) && clean(1, n))

        // Interleaved buffer (a format we never asked for).
        prefill()
        abl.count = 1
        abl[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(2 * n * 4), mData: buf(0))
        flags = []
        _ = EQTRenderCallback(ref, &flags, &stamp, 0, UInt32(n), abl.unsafeMutablePointer)
        r.check("interleaved buffer: rejected and zeroed", flags.contains(.unitRenderAction_OutputIsSilence) && clean(0, 2 * n))

        // Three buffers: third zeroed, first two rendered.
        prefill()
        abl.count = 3
        for i in 0 ..< 3 { abl[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(n * 4), mData: buf(i)) }
        flags = []
        _ = EQTRenderCallback(ref, &flags, &stamp, 0, UInt32(n), abl.unsafeMutablePointer)
        r.check("3 buffers: all written, extra one silent", clean(0, n) && clean(1, n) && clean(2, n) && !flags.contains(.unitRenderAction_OutputIsSilence))

        // Mono.
        prefill()
        abl.count = 1
        abl[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(n * 4), mData: buf(0))
        flags = []
        _ = EQTRenderCallback(ref, &flags, &stamp, 0, UInt32(n), abl.unsafeMutablePointer)
        r.check("mono buffer list: rendered (L/R average), finite", clean(0, n) && !flags.contains(.unitRenderAction_OutputIsSilence))

        // Stream start → chain reset (differential: see resumeEnergy).
        let withReset = resumeEnergy(throughCallback: true)
        let without = resumeEnergy(throughCallback: false)
        r.check("stream start resets the chain (3 ms duck present vs. a no-reset control run)",
                withReset.discontinuities == 1 && without.energy > 0 && withReset.energy < 0.9 * without.energy,
                "first 10 ms energy \(withReset.energy.f(3)) vs \(without.energy.f(3)) without reset")

        // Teardown fade (review fix: power-off / quit / reroute cut the device to zero mid-waveform).
        let faded = teardownFade(fade: true)
        let cut = teardownFade(fade: false)
        r.check("teardown fade: the output ramps to zero in \(faded.fadeFrames) frames (5 ms) and reports it",
                faded.fadedOut && faded.framesToZero <= faded.fadeFrames && faded.levelBefore > 0.4,
                "zero after \(faded.framesToZero) frames, level before \(faded.levelBefore.f(3))")
        r.check("teardown fade: largest sample step ≤ level / ramp length (no click), vs. the cut it replaces",
                faded.maxStep <= faded.levelBefore / Double(faded.fadeFrames) * 1.05 + 1e-6 && cut.maxStep > 0.4,
                "max step \(faded.maxStep.f(5)) with the fade, \(cut.maxStep.f(3)) when cut")
        r.check("teardown fade: exact zeros after the ramp, while the ring keeps delivering audio", faded.zerosAfter)
        r.check("teardown fade: nothing requested → keeps playing, never reports faded", !cut.fadedOut && cut.levelBefore > 0.4)
        r.check("fade wait: one IO buffer + ramp, ≤ 50 ms",
                abs(OutputUnit.fadeWaitSeconds(bufferFrames: 512, sampleRate: 48_000) - (2 * 512.0 / 48_000 + 0.01)) < 1e-9
                    && OutputUnit.fadeWaitSeconds(bufferFrames: 4_096, sampleRate: 48_000) == 0.05
                    && OutputUnit.fadeWaitSeconds(bufferFrames: 512, sampleRate: .nan) == 0.05)

        // After quiesce: silence, no reader / chain access.
        r.check("quiesce returns promptly when idle", ctx.quiesce(timeoutSeconds: 0.1))
        prefill()
        abl.count = 2
        abl[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(n * 4), mData: buf(0))
        abl[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(n * 4), mData: buf(1))
        flags = []
        let rejBefore = ctx.rejectedBuffers.load(ordering: .relaxed)
        _ = EQTRenderCallback(ref, &flags, &stamp, 0, UInt32(n), abl.unsafeMutablePointer)
        r.check("after quiesce: silence flagged, buffers zeroed, not counted as rejected",
                flags.contains(.unitRenderAction_OutputIsSilence) && clean(0, n) && clean(1, n)
                    && ctx.rejectedBuffers.load(ordering: .relaxed) == rejBefore)
        ctx.requestFadeOut()
        _ = EQTRenderCallback(ref, &flags, &stamp, 0, UInt32(n), abl.unsafeMutablePointer)
        r.check("fade requested while already silent (quiesced) → reported faded at once", ctx.isFadedOut)
    }

    /// Steady DC 0.5 through the real callback (flat chain), then — if `fade` —
    /// `requestFadeOut()` and keep rendering while the writer keeps writing;
    /// otherwise `quiesce()` alone (what teardown did before the fade: the
    /// next buffer is digital zero). Measures the transition.
    static func teardownFade(fade: Bool) -> (fadedOut: Bool, framesToZero: Int, fadeFrames: Int, maxStep: Double,
                                             levelBefore: Double, zerosAfter: Bool) {
        let ring = RingMapping.inProcess()
        let h = ring.mutableHeader!
        SimWriter.initialize(h, sampleRate: 48_000)
        let tps = RingReader.hostTicksPerSecond
        let clock = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        defer { clock.deallocate() }
        clock.pointee = UInt64(10 * tps)
        let reader = RingReader(header: ring.header)
        reader.hostClockOverride = clock
        reader.configure(outputSampleRate: 48_000, outputMaxFrames: 4_096, outputBufferFrames: 512)
        let chain = ProcessingChain(maxFrames: 4_096, maxChannels: 2)
        chain.prepare(sampleRate: 48_000, channelCount: 2)
        let ctx = RenderContext(reader: reader, chain: chain, ring: ring, sampleRate: 48_000)
        let ref = Unmanaged.passUnretained(ctx).toOpaque()
        let abl = AudioBufferList.allocate(maximumBuffers: 2)
        let l = UnsafeMutablePointer<Float>.allocate(capacity: 512), rr = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        defer { l.deallocate(); rr.deallocate(); free(abl.unsafeMutablePointer) }
        let dc = UnsafeMutablePointer<Float>.allocate(capacity: 1024)
        defer { dc.deallocate() }
        dc.update(repeating: 0.5, count: 1024)
        var stamp = AudioTimeStamp()
        var flags = AudioUnitRenderActionFlags()
        let period = 512.0 / 48_000
        var out: [Float] = []
        var markAt = 0
        for k in 0 ..< 160 {
            let t = 10 + Double(k) * period
            clock.pointee = UInt64(t * tps)
            let first = Int64(k * 512)
            let slot = Int(first & Int64(EQT_RING_CAPACITY_FRAMES - 1))
            (EQTRingSamples(h) + slot * 2).update(from: dc, count: 1024)
            EQTRingStoreWriteHead(h, first + 512)
            EQTRingStoreIOBufferFrames(h, 512)
            EQTRingStoreLastWriteHostTime(h, clock.pointee)
            clock.pointee = UInt64((t + period / 2) * tps)
            if k == 120 {                              // teardown begins here
                markAt = out.count
                if fade { ctx.requestFadeOut() } else { ctx.quiesce(timeoutSeconds: 0.1) }
            }
            abl[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 2048, mData: l)
            abl[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 2048, mData: rr)
            _ = EQTRenderCallback(ref, &flags, &stamp, 0, 512, abl.unsafeMutablePointer)
            out.append(contentsOf: UnsafeBufferPointer(start: l, count: 512))
        }
        let before = Double(out[markAt - 1])
        var maxStep = 0.0
        for i in (markAt - 512) ..< out.count { maxStep = max(maxStep, abs(Double(out[i] - out[i - 1]))) }
        let zeroAt = out[markAt...].firstIndex(where: { $0 == 0 }).map { $0 - markAt } ?? Int.max
        let zerosAfter = zeroAt != Int.max && out[(markAt + zeroAt)...].allSatisfy { $0 == 0 }
        return (ctx.isFadedOut, zeroAt == Int.max ? Int.max : zeroAt + 1, ctx.fadeFrames, maxStep, before, zerosAfter)
    }

    /// Stream start through the real callback vs. the same reader + chain
    /// driven WITHOUT `requestReset`. The only difference between the runs is
    /// the reset, whose 3 ms duck makes the start measurably quieter — so this
    /// fails if the callback ever stops resetting the chain on a discontinuity.
    static func resumeEnergy(throughCallback: Bool) -> (energy: Double, discontinuities: UInt64) {
        let ring = RingMapping.inProcess()
        let h = ring.mutableHeader!
        SimWriter.initialize(h, sampleRate: 48_000)
        let tps = RingReader.hostTicksPerSecond
        let clock = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        defer { clock.deallocate() }
        clock.pointee = UInt64(10 * tps)
        let reader = RingReader(header: ring.header)
        reader.hostClockOverride = clock
        reader.configure(outputSampleRate: 48_000, outputMaxFrames: 4_096, outputBufferFrames: 512)
        let chain = ProcessingChain(maxFrames: 4_096, maxChannels: 2)
        chain.prepare(sampleRate: 48_000, channelCount: 2)
        let ctx = RenderContext(reader: reader, chain: chain, ring: ring, sampleRate: 48_000)
        let ref = Unmanaged.passUnretained(ctx).toOpaque()
        let abl = AudioBufferList.allocate(maximumBuffers: 2)
        let l = UnsafeMutablePointer<Float>.allocate(capacity: 512), r = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        defer { l.deallocate(); r.deallocate(); free(abl.unsafeMutablePointer) }
        let table = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 2)
        defer { table.deallocate() }
        table[0] = l; table[1] = r
        let dc = UnsafeMutablePointer<Float>.allocate(capacity: 1024)
        defer { dc.deallocate() }
        dc.update(repeating: 0.5, count: 1024)
        var out: [Float] = []
        var stamp = AudioTimeStamp()
        var flags = AudioUnitRenderActionFlags()
        let period = 512.0 / 48_000
        for k in 0 ..< 200 {
            // writer: 512 frames of DC at t = k·period
            let t = 10 + Double(k) * period
            clock.pointee = UInt64(t * tps)
            let first = Int64(k * 512)
            let slot = Int(first & Int64(EQT_RING_CAPACITY_FRAMES - 1))
            (EQTRingSamples(h) + slot * 2).update(from: dc, count: 1024)
            EQTRingStoreWriteHead(h, first + 512)
            EQTRingStoreIOBufferFrames(h, 512)
            EQTRingStoreLastWriteHostTime(h, clock.pointee)
            // device pull half a period later
            clock.pointee = UInt64((t + period / 2) * tps)
            if throughCallback {
                abl[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 2048, mData: l)
                abl[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 2048, mData: r)
                _ = EQTRenderCallback(ref, &flags, &stamp, 0, 512, abl.unsafeMutablePointer)
            } else {
                let io = UnsafeMutableBufferPointer(start: table, count: 2)
                reader.render(into: io, frameCount: 512)
                _ = reader.consumeDiscontinuity()          // ← no requestReset
                chain.process(io, frameCount: 512)
            }
            out.append(contentsOf: UnsafeBufferPointer(start: l, count: 512))
        }
        guard let start = out.firstIndex(where: { $0 != 0 }) else { return (0, 0) }
        let e = out[start ..< min(out.count, start + 480)].reduce(0.0) { $0 + Double($1) * Double($1) }
        return (e, ctx.discontinuities.load(ordering: .relaxed))
    }

    // MARK: Installer

    private static func runScript(_ lines: [String], _ args: [String]) -> DriverInstaller.ScriptResult? {
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var out: DriverInstaller.ScriptResult?
        Task.detached {
            out = try? await DriverInstaller.runOSAScript(lines, arguments: args)
            sem.signal()
        }
        sem.wait()
        return out
    }

    /// Runs the installer's real `unquarantineCommand` (unprivileged) on a
    /// scratch bundle copied with `ditto`, as a downloaded app's embedded
    /// driver would be: the copy must lose `com.apple.quarantine`, keep its
    /// other attributes, and leave a symlink's target outside it untouched.
    private static func quarantine(_ r: SelfTestReport, in tmp: URL) {
        let src = tmp.appendingPathComponent("Qtn.driver")
        let dst = tmp.appendingPathComponent("QtnInstalled.driver")
        let outside = tmp.appendingPathComponent("qtn-outside")
        let plist = src.appendingPathComponent("Contents/Info.plist")
        try? FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: plist.path, contents: Data("x".utf8))
        FileManager.default.createFile(atPath: outside.path, contents: Data("o".utf8))
        try? FileManager.default.createSymbolicLink(atPath: src.appendingPathComponent("Contents/link").path,
                                                    withDestinationPath: outside.path)
        let qtn = "com.apple.quarantine", flag = "0081;00000000;Safari;"
        func has(_ path: String, _ name: String) -> Bool { getxattr(path, name, nil, 0, 0, 0) >= 0 }
        let set = [src.path, plist.path, outside.path].allSatisfy { setxattr($0, qtn, flag, flag.utf8.count, 0, 0) == 0 }
            && setxattr(plist.path, "com.eqtargets.keep", "1", 1, 0, 0) == 0
        func sh(_ cmd: String) -> Int32 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", cmd]
            p.standardError = FileHandle.nullDevice
            p.standardOutput = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
            return p.terminationStatus
        }
        let q = "'\(dst.path)'"
        let copied = sh("/usr/bin/ditto '\(src.path)' \(q)") == 0
        let out = dst.appendingPathComponent("Contents/Info.plist").path
        let carried = has(out, qtn)          // proves the check below can fail
        let ran = sh(DriverInstaller.unquarantineCommand(q)) == 0
        r.check("unquarantineCommand: a downloaded (quarantined) driver installs without the quarantine flag",
                set && copied && carried && ran && !has(dst.path, qtn) && !has(out, qtn),
                "flag set \(set), copied \(copied), ditto carried it \(carried), ran \(ran)")
        r.check("unquarantineCommand: other attributes kept, symlink target outside the bundle untouched",
                has(out, "com.eqtargets.keep") && has(outside.path, qtn))
        let again = sh(DriverInstaller.unquarantineCommand(q)) == 0
        r.check("unquarantineCommand: exits 0 on a bundle with no quarantine (never blocks the install)", again)
    }

    /// Runs the installer's real `hardenCommand` (unprivileged, on a scratch
    /// bundle this process owns) against what a tampered source could carry:
    /// an "everyone allow write" ACL, setuid / setgid / sticky bits,
    /// group/world write. `ditto` (even --noacl) keeps such ACLs.
    private static func hardening(_ r: SelfTestReport, in tmp: URL) {
        let bundle = tmp.appendingPathComponent("Harden.driver")
        let exe = bundle.appendingPathComponent("Contents/MacOS/EQtargetsAudio")
        try? FileManager.default.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: exe.path, contents: Data([0x23, 0x21]))
        func sh(_ cmd: String) -> Int32 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", cmd]
            p.standardError = FileHandle.nullDevice
            p.standardOutput = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
            return p.terminationStatus
        }
        let q = "'\(bundle.path)'"
        let planted = sh("/bin/chmod 6777 '\(exe.path)' && /bin/chmod 1777 '\(exe.deletingLastPathComponent().path)'"
                         + " && /bin/chmod +a 'everyone allow write,delete,append' '\(exe.path)'") == 0
        func hasACL(_ path: String) -> Bool {
            guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return false }
            acl_free(UnsafeMutableRawPointer(acl))
            return true
        }
        func badMode(_ path: String) -> Bool {
            var st = stat()
            guard lstat(path, &st) == 0 else { return true }
            return st.st_mode & (S_ISUID | S_ISGID | S_ISVTX | S_IWGRP | S_IWOTH) != 0
        }
        let paths = [bundle.path, bundle.appendingPathComponent("Contents").path,
                     exe.deletingLastPathComponent().path, exe.path]
        let plantedOK = planted && hasACL(exe.path) && badMode(exe.path) && badMode(exe.deletingLastPathComponent().path)
        let ran = sh(DriverInstaller.hardenCommand(q)) == 0
        let clean = paths.allSatisfy { !hasACL($0) && !badMode($0) }
        r.check("hardenCommand strips a planted ACL, setuid/setgid/sticky and group/world write from every file",
                plantedOK && ran && clean, "planted \(plantedOK), ran \(ran), clean \(clean)")
    }

    private static func installer(_ r: SelfTestReport) {
        r.section("Driver installer (no install is performed)")
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("eqt-selftest-\(getpid())")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let marker = tmp.appendingPathComponent("pwned").path
        let outFile = tmp.appendingPathComponent("arg.txt").path
        let hostile = [
            "/Applications/EQtargets.app/Contents/Resources/EQtargetsAudio.driver",
            "/Users/me/My Apps/EQ's \"Beta\" build/EQtargetsAudio.driver",
            "/tmp/$(touch \(marker))`touch \(marker)`;touch \(marker)",
            "/tmp/back\\slash \\\"q\\\" & ampersand | pipe > redirect",
            "/tmp/ünïcødé 日本語/ドライバ.driver",
            "/tmp/new\nline\ttab",
        ]
        // Same argv → quoted form of → do shell script pipeline as the real
        // install script, unprivileged, writing the argument it received.
        let probe = DriverInstaller.scriptLines(shellPrefix: "/usr/bin/printf %s ", shellSuffix: " > '\(outFile)'", privileged: false)
        var exact = 0
        for path in hostile {
            try? FileManager.default.removeItem(atPath: outFile)
            let res = runScript(probe, [path])
            let got = (try? String(contentsOfFile: outFile, encoding: .utf8)) ?? "<none>"
            if res?.status == 0, got == path { exact += 1 } else { r.note("mismatch for \(path.debugDescription): got \(got.debugDescription), stderr \(res?.stderr ?? "-")") }
        }
        r.check("source path reaches the shell byte-identical (\(hostile.count) hostile paths)", exact == hostile.count, "\(exact)/\(hostile.count)")
        r.check("no injected command ran", !FileManager.default.fileExists(atPath: marker))

        // The privileged scripts compile (osacompile never runs them).
        for (name, lines) in [("install", DriverInstaller.installScript), ("uninstall", DriverInstaller.uninstallScript)] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
            p.arguments = ["-o", tmp.appendingPathComponent("\(name).scpt").path] + lines.flatMap { ["-e", $0] }
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
            r.check("\(name) AppleScript compiles", p.terminationStatus == 0)
        }
        let script = DriverInstaller.installScript.joined(separator: "\n")
        r.check("install script: admin prompt, ditto, root:wheel, coreaudiod restart with fallback",
                script.contains("with administrator privileges") && script.contains("/usr/bin/ditto")
                    && script.contains("chown -R root:wheel") && script.contains("kickstart -k system/com.apple.audio.coreaudiod")
                    && script.contains("killall coreaudiod") && script.contains("'/Library/Audio/Plug-Ins/HAL/EQtargetsAudio.driver'"))

        let hardenAt = script.range(of: "chmod -R -N")?.lowerBound
        let unqAt = script.range(of: DriverInstaller.unquarantineCommand("'/Library/Audio/Plug-Ins/HAL/EQtargetsAudio.driver'"))?.lowerBound
        let restartAt = script.range(of: "kickstart -k")?.lowerBound
        r.check("install script: download quarantine dropped from the installed copy, before coreaudiod restarts",
                hardenAt != nil && unqAt != nil && restartAt != nil && hardenAt! < unqAt! && unqAt! < restartAt!)
        quarantine(r, in: tmp)

        let chownAt = script.range(of: "chown -R root:wheel")?.lowerBound
        let aclAt = script.range(of: "chmod -R -N")?.lowerBound
        r.check("install script: ACLs and set-id / sticky bits stripped after the copy (hardenCommand)",
                script.contains(DriverInstaller.hardenCommand("'/Library/Audio/Plug-Ins/HAL/EQtargetsAudio.driver'"))
                    && chownAt != nil && aclAt != nil && chownAt! < aclAt!)
        hardening(r, in: tmp)

        let cancel = DriverInstaller.error(from: .init(status: 1, stdout: "", stderr: "0:211: execution error: User canceled. (-128)\n"))
        r.check("password prompt cancelled → NSUserCancelledError", (cancel as NSError?)?.code == NSUserCancelledError
                    && (cancel as NSError?)?.domain == NSCocoaErrorDomain)
        let fail = DriverInstaller.error(from: .init(status: 1, stdout: "", stderr: "0:211: execution error: ditto: /x: No such file or directory (1)\n"))
        r.check("script failure → readable message", (fail as? DriverInstallError) == .failed("ditto: /x: No such file or directory (1)"),
                fail?.localizedDescription ?? "nil")
        r.check("success → no error", DriverInstaller.error(from: .init(status: 0, stdout: "", stderr: "")) == nil)

        do { try DriverInstaller.validate(tmp.appendingPathComponent("missing.driver")); r.check("validate: missing bundle refused", false) }
        catch { r.check("validate: missing bundle refused", (error as? DriverInstallError).map { if case .bundleMissing = $0 { true } else { false } } ?? false) }
        do { try DriverInstaller.validate(tmp); r.check("validate: a plain folder is refused", false) }
        catch { r.check("validate: a plain folder is refused", (error as? DriverInstallError).map { if case .invalidBundle = $0 { true } else { false } } ?? false) }

        // If the app was built next to this tool, its embedded driver must be found and valid.
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let app = exe.deletingLastPathComponent().appendingPathComponent("EQtargets.app")
        if let bundle = Bundle(url: app) {
            let embedded = DriverInstaller.embeddedDriver(in: bundle)
            let ok = (try? DriverInstaller.validate(embedded)) != nil
            r.check("embedded driver found inside the built app and valid", ok, embedded.path)
        } else {
            r.note("(EQtargets.app not built next to eqt-engine; embedded-driver lookup not checked)")
        }
    }
}
