//
//  DriverContractTests.swift
//  EQtargets (iOS)
//
//  Drives the REAL AudioServerPlugIn through its C interface with a fake host.
//  Checks the contract AudioServerPlugIn.h states for a Media Device Extension,
//  plus internal consistency. It cannot prove the system's audio server accepts
//  the device: that needs a signed extension on an iPhone.
//

import CoreAudio
import XCTest

private func fcc(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

private let pluginObject: AudioObjectID = 1
private let deviceObject: AudioObjectID = 2
private let streamObject: AudioObjectID = 3
private let global = fcc("glob")
private let outputScope = fcc("outp")
private let inputScope = fcc("inpt")

final class DriverContractTests: XCTestCase {

    private let uid = EQT_ROUTE_DEVICE_UUID_STRING

    private var driver: AudioServerPlugInDriverRef!
    private var vt: AudioServerPlugInDriverInterface { driver.pointee!.pointee }

    override func setUp() {
        super.setUp()
        XCTAssertEqual(EQTDeviceDriver.shared.publish(withDeviceUID: uid), noErr)
        driver = EQTTestCapturedDriver()
        XCTAssertNotNil(driver)
    }

    override func tearDown() {
        EQTDeviceDriver.shared.stopCapture()
        _ = vt.StopIO(driver, deviceObject, 1)
        super.tearDown()
    }

    private func address(_ selector: String, scope: UInt32 = global) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: fcc(selector), mScope: scope, mElement: 0)
    }

    private func has(_ object: AudioObjectID, _ selector: String, scope: UInt32 = global) -> Bool {
        var a = address(selector, scope: scope)
        return vt.HasProperty(driver, object, 0, &a).boolValue
    }

    private func dataSize(_ object: AudioObjectID, _ selector: String, scope: UInt32 = global) -> (OSStatus, UInt32) {
        var a = address(selector, scope: scope)
        var size: UInt32 = 0
        let st = vt.GetPropertyDataSize(driver, object, 0, &a, 0, nil, &size)
        return (st, size)
    }

    private func get<T>(_ object: AudioObjectID, _ selector: String, scope: UInt32 = global,
                        as type: T.Type, initial: T, file: StaticString = #filePath, line: UInt = #line) -> T {
        var a = address(selector, scope: scope)
        var value = initial
        var used: UInt32 = 0
        let st = withUnsafeMutablePointer(to: &value) {
            vt.GetPropertyData(driver, object, 0, &a, 0, nil, UInt32(MemoryLayout<T>.size), &used, $0)
        }
        XCTAssertEqual(st, noErr, "get \(selector)", file: file, line: line)
        XCTAssertEqual(Int(used), MemoryLayout<T>.size, "size of \(selector)", file: file, line: line)
        return value
    }

    private func u32(_ object: AudioObjectID, _ selector: String, scope: UInt32 = global,
                     file: StaticString = #filePath, line: UInt = #line) -> UInt32 {
        get(object, selector, scope: scope, as: UInt32.self, initial: 0, file: file, line: line)
    }

    private func string(_ object: AudioObjectID, _ selector: String,
                        file: StaticString = #filePath, line: UInt = #line) -> String {
        var a = address(selector)
        var raw: UnsafeRawPointer?
        var used: UInt32 = 0
        let st = withUnsafeMutablePointer(to: &raw) {
            vt.GetPropertyData(driver, object, 0, &a, 0, nil, UInt32(MemoryLayout<UnsafeRawPointer?>.size), &used, $0)
        }
        XCTAssertEqual(st, noErr, file: file, line: line)
        guard let raw else { return "" }
        return Unmanaged<CFString>.fromOpaque(raw).takeRetainedValue() as String
    }

    // MARK: Header contract

    func test_publishesASingleOutputDevice() {
        let (st, size) = dataSize(pluginObject, "dev#")
        XCTAssertEqual(st, noErr)
        XCTAssertEqual(Int(size), MemoryLayout<AudioObjectID>.size, "the header allows one device")
        XCTAssertEqual(get(pluginObject, "dev#", as: AudioObjectID.self, initial: 0), deviceObject)
    }

    func test_transportType_isOneTheSystemAccepts() {
        XCTAssertEqual(u32(deviceObject, "tran"), kAudioDeviceTransportTypeRemoteStreaming)
    }

    func test_deviceUID_equalsTheMediaOutputDeviceID() {
        XCTAssertEqual(string(deviceObject, "uid "), uid)
        XCTAssertEqual(UUID(uuidString: uid)?.uuidString, uid, "must be the canonical UUID string")
    }

    func test_zeroTimestampPeriod_meetsTheDocumentedMinimum() {
        XCTAssertGreaterThanOrEqual(u32(deviceObject, "ring"), 10_923)
    }

    func test_neverOffersItselfAsTheDefaultOutput() {
        XCTAssertEqual(u32(deviceObject, "dflt"), 0)
        XCTAssertEqual(u32(deviceObject, "sflt"), 0)
    }

    func test_hasNoInputStream() {
        XCTAssertEqual(dataSize(deviceObject, "stm#", scope: inputScope).1, 0)
        XCTAssertEqual(get(deviceObject, "stm#", scope: outputScope, as: AudioObjectID.self, initial: 0), streamObject)
        XCTAssertEqual(u32(streamObject, "sdir"), 0, "0 = output")
    }

    func test_streamFormat_isInterleavedFloat32Stereo48k() {
        let f = get(streamObject, "sfmt", as: AudioStreamBasicDescription.self, initial: AudioStreamBasicDescription())
        XCTAssertEqual(f.mSampleRate, EQT_LINK_SAMPLE_RATE)
        XCTAssertEqual(f.mFormatID, kAudioFormatLinearPCM)
        XCTAssertNotEqual(f.mFormatFlags & kAudioFormatFlagIsFloat, 0)
        XCTAssertEqual(f.mFormatFlags & kAudioFormatFlagIsNonInterleaved, 0)
        XCTAssertEqual(f.mChannelsPerFrame, EQT_LINK_CHANNELS)
        XCTAssertEqual(f.mBitsPerChannel, 32)
        XCTAssertEqual(f.mBytesPerFrame, 8)
    }

    func test_deviceNameIsEQtargets() {
        XCTAssertEqual(string(deviceObject, "lnam"), EQT_ROUTE_NAME_STRING)
    }

    // MARK: Internal consistency

    func test_everyDeclaredProperty_reportsASizeItCanActuallyFill() {
        let selectors = ["bcls", "clas", "stdv", "lnam", "lmak", "ownd", "dev#", "uid ", "muid", "tran",
                         "akin", "clkd", "livn", "goin", "dflt", "sflt", "ltnc", "stm#", "saft", "nsrt",
                         "nsr#", "hidn", "ring", "dch2", "slay", "srnd", "ctrl", "sact", "sdir", "term",
                         "schn", "sfmt", "pft ", "sfma", "pfta"]
        var checked = 0
        for object in [pluginObject, deviceObject, streamObject] {
            for scope in [global, outputScope, inputScope] {
                for s in selectors where has(object, s, scope: scope) {
                    let (st, size) = dataSize(object, s, scope: scope)
                    XCTAssertEqual(st, noErr, "\(object) \(s)")
                    guard size > 0 else { continue }
                    var a = address(s, scope: scope)
                    let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
                    defer { buffer.deallocate() }
                    var used: UInt32 = 0
                    let got = vt.GetPropertyData(driver, object, 0, &a, 0, nil, size, &used, buffer)
                    XCTAssertEqual(got, noErr, "\(object) \(s)")
                    XCTAssertEqual(used, size, "\(object) \(s) size disagrees with its data")
                    if ["lnam", "lmak", "uid ", "muid"].contains(s), got == noErr {
                        Unmanaged<CFString>.fromOpaque(buffer.load(as: UnsafeRawPointer.self)).release()
                    }
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 40)
    }

    func test_translateUID_findsOnlyOurDevice() {
        func translate(_ value: String) -> AudioObjectID {
            var a = address("uidd")
            var q: CFString = value as CFString
            var out: AudioObjectID = 99
            var used: UInt32 = 0
            let st = withUnsafePointer(to: &q) {
                vt.GetPropertyData(driver, pluginObject, 0, &a, UInt32(MemoryLayout<CFString>.size), $0,
                                    UInt32(MemoryLayout<AudioObjectID>.size), &used, &out)
            }
            XCTAssertEqual(st, noErr)
            return out
        }
        XCTAssertEqual(translate(uid), deviceObject)
        XCTAssertEqual(translate("something-else"), 0)
    }

    func test_refusesAnyRateButTheLinkRate() {
        var a = address("nsrt")
        var good = EQT_LINK_SAMPLE_RATE
        var bad = 44_100.0
        XCTAssertEqual(vt.SetPropertyData(driver, deviceObject, 0, &a, 0, nil, 8, &good), noErr)
        XCTAssertNotEqual(vt.SetPropertyData(driver, deviceObject, 0, &a, 0, nil, 8, &bad), noErr)
    }

    func test_unknownObject_isRejected() {
        XCTAssertFalse(has(77, "clas"))
        XCTAssertEqual(vt.StartIO(driver, 77, 1), kAudioHardwareBadObjectError)
    }

    // MARK: IO

    func test_onlyWriteMixIsClaimed() {
        func claims(_ op: UInt32) -> Bool {
            var will: DarwinBoolean = false
            var inPlace: DarwinBoolean = false
            XCTAssertEqual(vt.WillDoIOOperation(driver, deviceObject, 1, op, &will, &inPlace), noErr)
            return will.boolValue
        }
        XCTAssertTrue(claims(fcc("rite")))
        for op in ["thrd", "cycl", "read", "cinp", "pinp", "pout", "mixo", "pmix", "cmix"] {
            XCTAssertFalse(claims(fcc(op)), op)
        }
    }

    func test_zeroTimestamp_keepsItsSeedWhileRunning_andChangesItOnRestart() {
        XCTAssertEqual(vt.StartIO(driver, deviceObject, 1), noErr)
        var time = 0.0
        var host: UInt64 = 0
        var first: UInt64 = 0
        var second: UInt64 = 0
        XCTAssertEqual(vt.GetZeroTimeStamp(driver, deviceObject, 1, &time, &host, &first), noErr)
        usleep(5_000)
        XCTAssertEqual(vt.GetZeroTimeStamp(driver, deviceObject, 1, &time, &host, &second), noErr)
        XCTAssertEqual(first, second, "a seed change forces a re-anchor and broke later activations")
        XCTAssertEqual(vt.StopIO(driver, deviceObject, 1), noErr)
        XCTAssertEqual(vt.StartIO(driver, deviceObject, 1), noErr)
        XCTAssertEqual(vt.GetZeroTimeStamp(driver, deviceObject, 1, &time, &host, &second), noErr)
        XCTAssertNotEqual(first, second, "StartIO rewinds the timeline, so the seed must change")
    }

    private func writeMix(frames: UInt32, value: Float) -> OSStatus {
        var samples = [Float](repeating: value, count: Int(frames) * 2)
        var cycle = AudioServerPlugInIOCycleInfo()
        return samples.withUnsafeMutableBytes { raw in
            vt.DoIOOperation(driver, deviceObject, streamObject, 1, fcc("rite"), frames, &cycle,
                              raw.baseAddress, nil)
        }
    }

    func test_writeMix_reachesTheSender_onlyWhileCapturing() {
        let sender = keyedSender(48_299)
        defer { EQTLinkSenderDestroy(sender) }
        var stats = EQTLinkSenderStats()
        XCTAssertEqual(vt.StartIO(driver, deviceObject, 1), noErr)

        XCTAssertEqual(writeMix(frames: 64, value: 0.1), noErr)
        EQTLinkSenderGetStats(sender, &stats)
        XCTAssertEqual(stats.pushedFrames, 0, "nothing before capture starts")

        EQTDeviceDriver.shared.startCapture(with: sender)
        XCTAssertEqual(writeMix(frames: 256, value: 0.2), noErr)
        EQTLinkSenderGetStats(sender, &stats)
        XCTAssertEqual(stats.pushedFrames, 256)

        EQTDeviceDriver.shared.stopCapture()
        XCTAssertEqual(writeMix(frames: 256, value: 0.3), noErr)
        EQTLinkSenderGetStats(sender, &stats)
        XCTAssertEqual(stats.pushedFrames, 256, "capture stopped")
    }

    /// An IO cycle overlapping the last StopIO must not push behind the end marker.
    func test_aCycleOverlappingTheLastStop_cannotPush_andStartIOReopens() {
        let sender = keyedSender(48_299)
        defer {
            EQTDeviceDriver.shared.stopCapture()
            EQTLinkSenderDestroy(sender)
        }
        var stats = EQTLinkSenderStats()
        EQTDeviceDriver.shared.startCapture(with: sender)
        XCTAssertEqual(vt.StartIO(driver, deviceObject, 1), noErr)
        XCTAssertEqual(writeMix(frames: 64, value: 0.1), noErr)
        EQTLinkSenderGetStats(sender, &stats)
        XCTAssertEqual(stats.pushedFrames, 64)

        let stopped = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        XCTAssertEqual(vt.StopIO(driver, deviceObject, 1), noErr)
        XCTAssertEqual(writeMix(frames: 64, value: 0.2), noErr)
        EQTLinkSenderGetStats(sender, &stats)
        // The gate lasts 100 ms. A machine stalled past that proves nothing here.
        if clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - stopped < 90_000_000 {
            XCTAssertEqual(stats.pushedFrames, 64, "no audio may follow the end of the stream")
        }

        let before = stats.pushedFrames
        XCTAssertEqual(vt.StopIO(driver, deviceObject, 1), noErr)   // closes it again
        XCTAssertEqual(vt.StartIO(driver, deviceObject, 1), noErr)
        XCTAssertEqual(writeMix(frames: 64, value: 0.3), noErr)
        EQTLinkSenderGetStats(sender, &stats)
        XCTAssertEqual(stats.pushedFrames, before + 64, "the next start delivers at once")
    }

    /// If the system ever sends a stop it doesn't mean, the client still playing
    /// must come back after a short gap. It must never leave the phone silent.
    func test_aStrayStopIO_cannotSilenceAClientThatKeepsPlaying() {
        let sender = keyedSender(48_299)
        defer {
            EQTDeviceDriver.shared.stopCapture()
            EQTLinkSenderDestroy(sender)
        }
        var stats = EQTLinkSenderStats()
        EQTDeviceDriver.shared.startCapture(with: sender)
        XCTAssertEqual(vt.StartIO(driver, deviceObject, 1), noErr)
        XCTAssertEqual(vt.StopIO(driver, deviceObject, 1), noErr)   // IO cycles carry on
        usleep(120_000)         // past the gate: a stalled machine only waits longer
        XCTAssertEqual(writeMix(frames: 64, value: 0.1), noErr)
        EQTLinkSenderGetStats(sender, &stats)
        XCTAssertEqual(stats.pushedFrames, 64, "a stray stop must not silence the phone")
    }

    /// The system can start a new client while the last stop is still waiting.
    /// That stop must not then end the stream the new client is playing into.
    func test_startIODuringStopIOsWait_keepsTheStreamRunning() {
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(EQTRingTotalBytes()), alignment: 4096)
        let ring = memory.bindMemory(to: EQTRingHeader.self, capacity: 1)
        EQTLinkRingFormat(ring)
        let receiver = keyedReceiver(48_294, ring)
        let sender = keyedSender(48_294)
        defer {
            EQTTestSetPushesInFlight(0)
            EQTDeviceDriver.shared.stopCapture()
            EQTLinkSenderDestroy(sender)
            EQTLinkReceiverDestroy(receiver)
            memory.deallocate()
        }
        XCTAssertEqual(EQTLinkReceiverStart(receiver), 0)
        XCTAssertEqual(EQTLinkSenderStart(sender), 0)
        var rx = EQTLinkReceiverStats()
        var s = EQTLinkSenderStats()
        func waitFor(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(5)
            while !condition(), Date() < deadline { usleep(500) }
        }
        waitFor {
            EQTLinkReceiverGetStats(receiver, &rx)
            EQTLinkSenderGetStats(sender, &s)
            return rx.hasPeer == 1 && s.connected == 1
        }
        EQTDeviceDriver.shared.startCapture(with: sender)
        XCTAssertEqual(vt.StartIO(driver, deviceObject, 1), noErr)
        XCTAssertEqual(writeMix(frames: 128, value: 0.2), noErr)
        waitFor { EQTRingLoadIORunning(ring) == 1 }
        XCTAssertEqual(EQTRingLoadIORunning(ring), 1)

        EQTTestSetPushesInFlight(1)
        let stopping = DispatchGroup()
        DispatchQueue.global(qos: .userInteractive).async(group: stopping) { [self] in
            _ = vt.StopIO(driver, deviceObject, 1)
        }
        // The device reads as stopped from the moment StopIO reaches its wait.
        waitFor { u32(deviceObject, "goin") == 0 }
        XCTAssertEqual(vt.StartIO(driver, deviceObject, 2), noErr)
        EQTTestSetPushesInFlight(0)
        stopping.wait()

        usleep(100_000)         // a wrongly sent end marker would have landed by now
        XCTAssertEqual(EQTRingLoadIORunning(ring), 1, "the new client is playing")
        XCTAssertEqual(writeMix(frames: 128, value: 0.3), noErr)
        waitFor {
            EQTLinkReceiverGetStats(receiver, &rx)
            return rx.receivedFrames == 256
        }
        XCTAssertEqual(rx.receivedFrames, 256, "its audio still arrives")

        XCTAssertEqual(vt.StopIO(driver, deviceObject, 2), noErr)
        waitFor { EQTRingLoadIORunning(ring) == 0 }
        XCTAssertEqual(EQTRingLoadIORunning(ring), 0, "its own stop still ends the stream")
    }

    /// Without the wait, a push already past its load of the sender lands after
    /// the stop, and its frames would follow the end-of-stream marker.
    func test_stopCapture_leavesNoPushInFlight() {
        final class Flag { var done = false }
        let flag = Flag()
        let sender = keyedSender(48_298)
        defer { EQTLinkSenderDestroy(sender) }
        XCTAssertEqual(vt.StartIO(driver, deviceObject, 1), noErr)
        let io = DispatchGroup()
        DispatchQueue(label: "test.io", qos: .userInteractive).async(group: io) { [self] in
            while !flag.done { _ = writeMix(frames: 512, value: 0.1) }
        }
        var late = 0
        var before = EQTLinkSenderStats()
        var after = EQTLinkSenderStats()
        for _ in 0 ..< 3_000 {
            EQTDeviceDriver.shared.startCapture(with: sender)
            for _ in 0 ..< 20 { sched_yield() }
            EQTDeviceDriver.shared.stopCapture()
            EQTLinkSenderGetStats(sender, &before)
            for _ in 0 ..< 20 { sched_yield() }
            EQTLinkSenderGetStats(sender, &after)
            if after.pushedFrames != before.pushedFrames { late += 1 }
        }
        flag.done = true
        io.wait()
        XCTAssertEqual(late, 0, "a push landed after stopCapture returned")
    }

    func test_stopCapture_givesUpOnAStuckPush() {
        let sender = keyedSender(48_297)
        defer {
            EQTTestSetPushesInFlight(0)
            EQTLinkSenderDestroy(sender)
        }
        EQTDeviceDriver.shared.startCapture(with: sender)
        EQTTestSetPushesInFlight(1)
        let started = Date()
        EQTDeviceDriver.shared.stopCapture()
        let waited = Date().timeIntervalSince(started)
        XCTAssertGreaterThan(waited, 0.03, "it must actually wait for the push")
        XCTAssertLessThan(waited, 1, "a stuck IO thread must never hang a stop")
    }

    /// The last IO cycle may still be pushing when StopIO arrives. Its frames must
    /// land before the end-of-stream marker, so StopIO waits for it, within a limit.
    func test_stopIO_waitsForAPushInFlight_beforeEndingTheStream() {
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(EQTRingTotalBytes()), alignment: 4096)
        let ring = memory.bindMemory(to: EQTRingHeader.self, capacity: 1)
        EQTLinkRingFormat(ring)
        let receiver = keyedReceiver(48_295, ring)
        let sender = keyedSender(48_295)
        defer {
            EQTTestSetPushesInFlight(0)
            EQTDeviceDriver.shared.stopCapture()
            EQTLinkSenderDestroy(sender)
            EQTLinkReceiverDestroy(receiver)
            memory.deallocate()
        }
        XCTAssertEqual(EQTLinkReceiverStart(receiver), 0)
        XCTAssertEqual(EQTLinkSenderStart(sender), 0)
        var rx = EQTLinkReceiverStats()
        var s = EQTLinkSenderStats()
        func waitFor(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(5)
            while !condition(), Date() < deadline { usleep(2_000) }
        }
        waitFor {
            EQTLinkReceiverGetStats(receiver, &rx)
            EQTLinkSenderGetStats(sender, &s)
            return rx.hasPeer == 1 && s.connected == 1
        }
        EQTDeviceDriver.shared.startCapture(with: sender)
        XCTAssertEqual(vt.StartIO(driver, deviceObject, 1), noErr)
        XCTAssertEqual(writeMix(frames: 128, value: 0.2), noErr)
        waitFor { EQTRingLoadIORunning(ring) == 1 }
        XCTAssertEqual(EQTRingLoadIORunning(ring), 1)

        EQTTestSetPushesInFlight(1)
        let started = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let stopping = DispatchGroup()
        DispatchQueue.global(qos: .userInteractive).async(group: stopping) { [self] in
            _ = vt.StopIO(driver, deviceObject, 1)
        }
        // The wait lasts 50 ms. Reading the ring BEFORE the clock means a stalled test
        // thread can only miss an early end, never report a normal end as early.
        var endedEarly = false
        while true {
            let running = EQTRingLoadIORunning(ring)
            guard clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - started < 40_000_000 else { break }
            if running == 0 {
                endedEarly = true
                break
            }
            usleep(500)
        }
        XCTAssertFalse(endedEarly, "the stream ended while a push was still in flight")

        stopping.wait()
        let waited = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - started) / 1e9
        XCTAssertGreaterThan(waited, 0.03, "StopIO must wait for the push")
        XCTAssertLessThan(waited, 1, "a stuck IO thread must never hang StopIO")
        waitFor { EQTRingLoadIORunning(ring) == 0 }
        XCTAssertEqual(EQTRingLoadIORunning(ring), 0, "the stream still ends after the wait")
    }

    func test_writeMix_audioArrivesThroughTheRealLink() {
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(EQTRingTotalBytes()), alignment: 4096)
        let ring = memory.bindMemory(to: EQTRingHeader.self, capacity: 1)
        EQTLinkRingFormat(ring)
        let receiver = keyedReceiver(48_298, ring)
        let sender = keyedSender(48_298)
        defer {
            EQTDeviceDriver.shared.stopCapture()
            EQTLinkSenderDestroy(sender)
            EQTLinkReceiverDestroy(receiver)
            memory.deallocate()
        }
        XCTAssertEqual(EQTLinkReceiverStart(receiver), 0)
        XCTAssertEqual(EQTLinkSenderStart(sender), 0)
        var rx = EQTLinkReceiverStats()
        var s = EQTLinkSenderStats()
        let deadline = Date().addingTimeInterval(5)
        repeat {
            usleep(2_000)
            EQTLinkReceiverGetStats(receiver, &rx)
            EQTLinkSenderGetStats(sender, &s)
        } while (rx.hasPeer == 0 || s.connected == 0) && Date() < deadline
        XCTAssertEqual(rx.hasPeer, 1)

        EQTDeviceDriver.shared.startCapture(with: sender)
        XCTAssertEqual(vt.StartIO(driver, deviceObject, 1), noErr)
        XCTAssertEqual(writeMix(frames: 480, value: 0.25), noErr)
        let until = Date().addingTimeInterval(5)
        repeat {
            usleep(2_000)
            EQTLinkReceiverGetStats(receiver, &rx)
        } while rx.receivedFrames < 480 && Date() < until
        XCTAssertEqual(rx.receivedFrames, 480)
        let samples = EQTRingSamples(ring)!
        XCTAssertEqual(samples[0], 0.25)
        XCTAssertEqual(samples[959], 0.25)
    }

    func test_stopIO_tellsTheAppTheStreamEnded_andStartIOResumes() {
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(EQTRingTotalBytes()), alignment: 4096)
        let ring = memory.bindMemory(to: EQTRingHeader.self, capacity: 1)
        EQTLinkRingFormat(ring)
        let receiver = keyedReceiver(48_297, ring)
        let sender = keyedSender(48_297)
        defer {
            EQTDeviceDriver.shared.stopCapture()
            EQTLinkSenderDestroy(sender)
            EQTLinkReceiverDestroy(receiver)
            memory.deallocate()
        }
        XCTAssertEqual(EQTLinkReceiverStart(receiver), 0)
        XCTAssertEqual(EQTLinkSenderStart(sender), 0)
        var rx = EQTLinkReceiverStats()
        var s = EQTLinkSenderStats()
        func waitFor(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(5)
            while !condition(), Date() < deadline { usleep(2_000) }
        }
        waitFor {
            EQTLinkReceiverGetStats(receiver, &rx)
            EQTLinkSenderGetStats(sender, &s)
            return rx.hasPeer == 1 && s.connected == 1
        }
        EQTDeviceDriver.shared.startCapture(with: sender)
        XCTAssertEqual(vt.StartIO(driver, deviceObject, 1), noErr)
        XCTAssertEqual(writeMix(frames: 128, value: 0.2), noErr)
        waitFor { EQTRingLoadIORunning(ring) == 1 }
        XCTAssertEqual(EQTRingLoadIORunning(ring), 1)

        XCTAssertEqual(vt.StopIO(driver, deviceObject, 1), noErr)
        waitFor { EQTRingLoadIORunning(ring) == 0 }
        XCTAssertEqual(EQTRingLoadIORunning(ring), 0, "the reader must learn delivery stopped")

        XCTAssertEqual(vt.StartIO(driver, deviceObject, 1), noErr)
        XCTAssertEqual(writeMix(frames: 128, value: 0.3), noErr)
        waitFor { EQTRingLoadIORunning(ring) == 1 }
        XCTAssertEqual(EQTRingLoadIORunning(ring), 1)
    }

    func test_ioClientsAreCounted_onlyTheLastStopEndsTheStream() {
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(EQTRingTotalBytes()), alignment: 4096)
        let ring = memory.bindMemory(to: EQTRingHeader.self, capacity: 1)
        EQTLinkRingFormat(ring)
        let receiver = keyedReceiver(48_296, ring)
        let sender = keyedSender(48_296)
        defer {
            EQTDeviceDriver.shared.stopCapture()
            EQTLinkSenderDestroy(sender)
            EQTLinkReceiverDestroy(receiver)
            memory.deallocate()
        }
        XCTAssertEqual(EQTLinkReceiverStart(receiver), 0)
        XCTAssertEqual(EQTLinkSenderStart(sender), 0)
        var s = EQTLinkSenderStats()
        func waitFor(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(5)
            while !condition(), Date() < deadline { usleep(2_000) }
        }
        waitFor {
            EQTLinkSenderGetStats(sender, &s)
            return s.connected == 1
        }
        EQTDeviceDriver.shared.startCapture(with: sender)

        var time = 0.0, host: UInt64 = 0, first: UInt64 = 0, second: UInt64 = 0
        XCTAssertEqual(vt.StartIO(driver, deviceObject, 1), noErr)
        XCTAssertEqual(vt.GetZeroTimeStamp(driver, deviceObject, 1, &time, &host, &first), noErr)
        XCTAssertEqual(vt.StartIO(driver, deviceObject, 2), noErr)
        XCTAssertEqual(vt.GetZeroTimeStamp(driver, deviceObject, 2, &time, &host, &second), noErr)
        XCTAssertEqual(first, second, "a second client must not re-anchor the clock under the first")

        XCTAssertEqual(writeMix(frames: 128, value: 0.2), noErr)
        waitFor { EQTRingLoadIORunning(ring) == 1 }
        XCTAssertEqual(vt.StopIO(driver, deviceObject, 2), noErr)
        // Straight away: one client's stop must not hold back the other's audio.
        XCTAssertEqual(writeMix(frames: 128, value: 0.3), noErr)
        EQTLinkSenderGetStats(sender, &s)
        XCTAssertEqual(s.pushedFrames, 256, "client 1's audio still goes out")
        usleep(100_000)
        XCTAssertEqual(EQTRingLoadIORunning(ring), 1, "client 1 is still playing")

        XCTAssertEqual(vt.StopIO(driver, deviceObject, 1), noErr)
        waitFor { EQTRingLoadIORunning(ring) == 0 }
        XCTAssertEqual(EQTRingLoadIORunning(ring), 0)
    }

    // MARK: Identity stays in sync across files

    func test_protocolID_matchesTheEntitlementAndInfoPlist() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let ext = root.appendingPathComponent("Sources/Extension")

        let entData = try Data(contentsOf: ext.appendingPathComponent("Extension.entitlements"))
        let ent = try XCTUnwrap(PropertyListSerialization.propertyList(from: entData, format: nil) as? [String: Any])
        let ids = try XCTUnwrap(ent["com.apple.developer.media-device-extension"] as? [String])
        XCTAssertEqual(ids, [EQT_PROTOCOL_ID_STRING], "must be an array with exactly this one element")

        let plistData = try Data(contentsOf: ext.appendingPathComponent("Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any])
        let types = try XCTUnwrap(plist["UTExportedTypeDeclarations"] as? [[String: Any]])
        XCTAssertEqual(types.first?["UTTypeIdentifier"] as? String, EQT_PROTOCOL_ID_STRING)
        XCTAssertEqual(types.first?["UTTypeConformsTo"] as? [String], ["public.media-sharing-protocol"])
        let attrs = try XCTUnwrap(plist["EXAppExtensionAttributes"] as? [String: Any])
        XCTAssertEqual(attrs["EXExtensionPointIdentifier"] as? String, "com.apple.media-device-extension")

        let hostData = try Data(contentsOf: root.appendingPathComponent("Sources/App/EQtargets.entitlements"))
        let host = try XCTUnwrap(PropertyListSerialization.propertyList(from: hostData, format: nil) as? [String: Any])
        let hostIDs = try XCTUnwrap(host["com.apple.developer.media-device-extension"] as? [String])
        XCTAssertTrue(hostIDs.isEmpty, "any value here makes iOS refuse the app's audio session")
    }
}

private let EQT_ROUTE_DEVICE_UUID_STRING = String(cString: EQTTestString(0))
private let EQT_ROUTE_NAME_STRING = String(cString: EQTTestString(1))
private let EQT_PROTOCOL_ID_STRING = String(cString: EQTTestString(2))
