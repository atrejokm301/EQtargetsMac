//
//  HAL.swift
//  EQtargets (macOS)
//
//  Thin, typed access to the Core Audio HAL object model, used by the engine
//  (main thread only — none of this is real-time safe: every call may IPC to
//  coreaudiod).
//
//  • `HAL`              — property get / set / has / settable, defaults, rates,
//                         volume and mute on the main element or channels 1/2.
//  • `DeviceCatalog`    — which devices are real outputs (never our own device,
//                         never an aggregate that contains it), as `OutputDevice`.
//  • `PropertyListener` — a block listener on a private serial queue that is
//                         always removed again (the exact same block object is
//                         passed to add and remove; the HAL matches by identity).
//

import CoreAudio
import Foundation

enum HAL {

    static let systemObject = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    // MARK: Generic property access

    static func has(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var a = address
        return AudioObjectHasProperty(object, &a)
    }

    static func isSettable(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var a = address
        guard AudioObjectHasProperty(object, &a) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(object, &a, &settable) == noErr && settable.boolValue
    }

    /// A fixed-size, trivially copyable value (UInt32, Float32, Float64,
    /// AudioObjectID, AudioValueRange, AudioStreamBasicDescription…). Returns
    /// nil on any error or if the HAL returned a different size.
    static func get<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, as type: T.Type = T.self) -> T? {
        var a = address
        var size = UInt32(MemoryLayout<T>.size)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
        defer { raw.deallocate() }
        let status = AudioObjectGetPropertyData(object, &a, 0, nil, &size, raw)
        guard status == noErr, Int(size) == MemoryLayout<T>.size else { return nil }
        return raw.load(as: T.self)
    }

    @discardableResult
    static func set<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: T) -> OSStatus {
        var a = address
        var v = value
        return withUnsafePointer(to: &v) { p in
            AudioObjectSetPropertyData(object, &a, 0, nil, UInt32(MemoryLayout<T>.size), p)
        }
    }

    /// A variable-length array of trivially copyable elements.
    static func array<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, of type: T.Type = T.self) -> [T] {
        var a = address
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size) == noErr else { return [] }
        let capacity = Int(size) / MemoryLayout<T>.stride
        guard capacity > 0 else { return [] }
        return [T](unsafeUninitializedCapacity: capacity) { buffer, initialized in
            var s = UInt32(capacity * MemoryLayout<T>.stride)
            let status = AudioObjectGetPropertyData(object, &a, 0, nil, &s, buffer.baseAddress!)
            initialized = status == noErr ? min(capacity, Int(s) / MemoryLayout<T>.stride) : 0
        }
    }

    /// A CFString property. The HAL hands out a +1 reference; it is consumed here.
    static func string(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> String? {
        var a = address
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { p in
            AudioObjectGetPropertyData(object, &a, 0, nil, &size, p)
        }
        guard status == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    // MARK: System

    static func deviceIDs() -> [AudioObjectID] {
        array(systemObject, address(kAudioHardwarePropertyDevices), of: AudioObjectID.self)
    }

    /// UID → object ID through the HAL's translator (unknown UID → nil).
    static func device(uid: String) -> AudioObjectID? {
        var a = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var cfUID = uid as CFString
        var device = unknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { q in
            AudioObjectGetPropertyData(systemObject, &a, UInt32(MemoryLayout<CFString>.size), q, &size, &device)
        }
        return status == noErr && device != unknown ? device : nil
    }

    /// Bundle ID → plug-in object through the HAL's translator (nil if not loaded).
    static func plugIn(bundleID: String) -> AudioObjectID? {
        var a = address(kAudioHardwarePropertyTranslateBundleIDToPlugIn)
        var cfID = bundleID as CFString
        var plugIn = unknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &cfID) { q in
            AudioObjectGetPropertyData(systemObject, &a, UInt32(MemoryLayout<CFString>.size), q, &size, &plugIn)
        }
        return status == noErr && plugIn != unknown ? plugIn : nil
    }

    static func uid(_ device: AudioObjectID) -> String? {
        string(device, address(kAudioDevicePropertyDeviceUID))
    }

    static func name(_ device: AudioObjectID) -> String? {
        string(device, address(kAudioObjectPropertyName))
    }

    /// macOS's default OUTPUT device (what apps play to). Never confuse with the
    /// system/alert output, which the engine leaves alone.
    static func defaultOutputDevice() -> AudioObjectID? {
        let id: AudioObjectID? = get(systemObject, address(kAudioHardwarePropertyDefaultOutputDevice))
        return id == unknown ? nil : id
    }

    @discardableResult
    static func setDefaultOutputDevice(_ device: AudioObjectID) -> OSStatus {
        set(systemObject, address(kAudioHardwarePropertyDefaultOutputDevice), device)
    }

    static func defaultSystemOutputDevice() -> AudioObjectID? {
        let id: AudioObjectID? = get(systemObject, address(kAudioHardwarePropertyDefaultSystemOutputDevice))
        return id == unknown ? nil : id
    }

    // MARK: Device

    static func outputStreamCount(_ device: AudioObjectID) -> Int {
        array(device, address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput), of: AudioObjectID.self).count
    }

    static func outputChannelCount(_ device: AudioObjectID) -> Int {
        var a = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func transportType(_ device: AudioObjectID) -> UInt32 {
        get(device, address(kAudioDevicePropertyTransportType)) ?? 0
    }

    static func nominalSampleRate(_ device: AudioObjectID) -> Double? {
        let r: Float64? = get(device, address(kAudioDevicePropertyNominalSampleRate))
        guard let r, r.isFinite, r > 0 else { return nil }
        return r
    }

    @discardableResult
    static func setNominalSampleRate(_ device: AudioObjectID, _ rate: Double) -> OSStatus {
        set(device, address(kAudioDevicePropertyNominalSampleRate), Float64(rate))
    }

    static func bufferFrameSize(_ device: AudioObjectID) -> Int? {
        let v: UInt32? = get(device, address(kAudioDevicePropertyBufferFrameSize))
        return v.map(Int.init)
    }

    /// The IO buffer sizes the device accepts, in frames (nil if unreadable or
    /// nonsensical — the values come from a driver, so nothing is trusted).
    static func bufferFrameSizeRange(_ device: AudioObjectID) -> ClosedRange<Int>? {
        guard let r: AudioValueRange = get(device, address(kAudioDevicePropertyBufferFrameSizeRange)),
              r.mMinimum.isFinite, r.mMaximum.isFinite, r.mMinimum >= 1, r.mMaximum >= r.mMinimum,
              r.mMaximum <= 1_048_576 else { return nil }
        let lo = Int(r.mMinimum.rounded(.up)), hi = Int(r.mMaximum.rounded(.down))
        return lo <= hi ? lo ... hi : nil
    }

    /// Asks `device` for an IO buffer of at most `frames` for THIS process
    /// (the HAL keeps the size per process and forgets it when the process
    /// exits). Never asks for a larger buffer than the device runs now, stays
    /// inside the device's range, and returns the size the device reports
    /// afterwards — so a device that refuses simply keeps its current size.
    static func requestBufferFrameSize(_ device: AudioObjectID, atMost frames: Int) -> Int? {
        guard let current = bufferFrameSize(device) else { return nil }
        guard let want = bufferRequest(current: current, preferred: frames, range: bufferFrameSizeRange(device)),
              isSettable(device, address(kAudioDevicePropertyBufferFrameSize)) else { return current }
        set(device, address(kAudioDevicePropertyBufferFrameSize), UInt32(want))
        return bufferFrameSize(device) ?? current
    }

    /// Pure part of `requestBufferFrameSize`: the size to ask for, or nil when
    /// nothing should be set (the device already runs that small or smaller).
    static func bufferRequest(current: Int, preferred: Int, range: ClosedRange<Int>?) -> Int? {
        guard preferred > 0 else { return nil }
        var want = preferred
        if let range { want = min(max(want, range.lowerBound), range.upperBound) }
        return want < current ? want : nil
    }

    static func isAlive(_ device: AudioObjectID) -> Bool {
        (get(device, address(kAudioDevicePropertyDeviceIsAlive)) as UInt32?).map { $0 != 0 } ?? false
    }

    static func isHidden(_ device: AudioObjectID) -> Bool {
        (get(device, address(kAudioDevicePropertyIsHidden)) as UInt32?).map { $0 != 0 } ?? false
    }

    /// True while ANY process runs IO on the device (the virtual device's
    /// "something is playing" signal for idle power management).
    static func isRunningSomewhere(_ device: AudioObjectID) -> Bool {
        (get(device, address(kAudioDevicePropertyDeviceIsRunningSomewhere)) as UInt32?).map { $0 != 0 } ?? false
    }

    /// Frames between a sample leaving our render callback and reaching the
    /// speaker: device latency + safety offset + stream latency + one IO buffer.
    static func outputPresentationLatencyFrames(_ device: AudioObjectID) -> Int {
        let out = kAudioObjectPropertyScopeOutput
        let latency: UInt32 = get(device, address(kAudioDevicePropertyLatency, out)) ?? 0
        let safety: UInt32 = get(device, address(kAudioDevicePropertySafetyOffset, out)) ?? 0
        let buffer: UInt32 = get(device, address(kAudioDevicePropertyBufferFrameSize)) ?? 0
        var stream: UInt32 = 0
        if let first = array(device, address(kAudioDevicePropertyStreams, out), of: AudioObjectID.self).first {
            stream = get(first, address(kAudioStreamPropertyLatency)) ?? 0
        }
        return Int(latency) + Int(safety) + Int(stream) + Int(buffer)
    }

    /// Sub-devices of an aggregate (empty for anything else).
    static func aggregateSubDevices(_ device: AudioObjectID) -> [AudioObjectID] {
        let a = address(kAudioAggregateDevicePropertyActiveSubDeviceList)
        guard has(device, a) else { return [] }
        return array(device, a, of: AudioObjectID.self)
    }

    // MARK: Volume / mute (output scope)

    /// Where a device's output volume can be SET: the main element, else
    /// channels 1 and 2 together, else nowhere (→ digital fallback).
    static func settableVolumeElements(_ device: AudioObjectID) -> [AudioObjectPropertyElement] {
        settableElements(device, kAudioDevicePropertyVolumeScalar)
    }

    static func settableMuteElements(_ device: AudioObjectID) -> [AudioObjectPropertyElement] {
        settableElements(device, kAudioDevicePropertyMute)
    }

    private static func settableElements(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectPropertyElement] {
        let out = kAudioObjectPropertyScopeOutput
        if isSettable(device, address(selector, out, kAudioObjectPropertyElementMain)) {
            return [kAudioObjectPropertyElementMain]
        }
        if isSettable(device, address(selector, out, 1)), isSettable(device, address(selector, out, 2)) {
            return [1, 2]
        }
        return []
    }

    private static func channelVolumes(_ device: AudioObjectID, _ elements: [AudioObjectPropertyElement]) -> [Float] {
        elements.compactMap {
            get(device, address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, $0)) as Float32?
        }
    }

    /// Scalar over `elements` (0…1): the main element, or for a per-channel
    /// device its loudest channel (`VolumeLaw.combinedVolume`, as macOS shows it).
    static func volumeScalar(_ device: AudioObjectID, elements: [AudioObjectPropertyElement]) -> Float? {
        let values = channelVolumes(device, elements)
        guard !values.isEmpty, values.count == elements.count else { return nil }
        return VolumeLaw.combinedVolume(values)
    }

    /// Sets the volume over `elements`. Per-channel devices keep their L/R
    /// balance (`VolumeLaw.channelVolumes`): the loudest channel lands on
    /// `value`, the others keep their ratio to it.
    @discardableResult
    static func setVolumeScalar(_ device: AudioObjectID, elements: [AudioObjectPropertyElement], _ value: Float) -> OSStatus {
        var result = noErr
        let v = Float32(min(max(value.isFinite ? value : 0, 0), 1))
        var targets = Array(repeating: v, count: elements.count)
        if elements.count > 1 {
            let current = channelVolumes(device, elements)
            if current.count == elements.count { targets = VolumeLaw.channelVolumes(current: current, target: v) }
        }
        for (e, t) in zip(elements, targets) {
            let s = set(device, address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, e), t)
            if s != noErr { result = s }
        }
        return result
    }

    /// Muted if every element is muted.
    static func isMuted(_ device: AudioObjectID, elements: [AudioObjectPropertyElement]) -> Bool? {
        let values = elements.compactMap {
            get(device, address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, $0)) as UInt32?
        }
        guard !values.isEmpty, values.count == elements.count else { return nil }
        return values.allSatisfy { $0 != 0 }
    }

    @discardableResult
    static func setMuted(_ device: AudioObjectID, elements: [AudioObjectPropertyElement], _ muted: Bool) -> OSStatus {
        var result = noErr
        for e in elements {
            let s = set(device, address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, e), UInt32(muted ? 1 : 0))
            if s != noErr { result = s }
        }
        return result
    }

    /// Output volume in dB as the device itself maps it (main element).
    static func volumeDecibels(_ device: AudioObjectID) -> Double? {
        let v: Float32? = get(device, address(kAudioDevicePropertyVolumeDecibels, kAudioObjectPropertyScopeOutput))
        guard let v, v.isFinite else { return nil }
        return Double(v)
    }

    // MARK: Custom properties (CFPropertyList-typed: the value is a CFNumber)

    /// A CFNumber-valued custom property ('eqtl', 'eqta'), or nil if the
    /// object doesn't have it (an older driver) or it isn't a number.
    static func customNumber(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Double? {
        var a = address(selector)
        guard AudioObjectHasProperty(object, &a) else { return nil }
        var value: Unmanaged<CFPropertyList>?
        var size = UInt32(MemoryLayout<Unmanaged<CFPropertyList>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { p in
            AudioObjectGetPropertyData(object, &a, 0, nil, &size, p)
        }
        guard status == noErr, let v = value?.takeRetainedValue() else { return nil }
        return (v as? NSNumber)?.doubleValue
    }

    @discardableResult
    static func setCustomNumber(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: Double) -> OSStatus {
        var a = address(selector)
        var number: CFNumber = NSNumber(value: value) as CFNumber
        return withUnsafePointer(to: &number) { p in
            AudioObjectSetPropertyData(object, &a, 0, nil, UInt32(MemoryLayout<CFNumber>.size), p)
        }
    }

    // MARK: Errors

    /// "'!dev' (560227702)" for four-char codes, else the number.
    static func describe(_ status: OSStatus) -> String {
        let u = UInt32(bitPattern: status)
        let bytes = [UInt8(u >> 24 & 0xFF), UInt8(u >> 16 & 0xFF), UInt8(u >> 8 & 0xFF), UInt8(u & 0xFF)]
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }), let s = String(bytes: bytes, encoding: .ascii) {
            return "'\(s)' (\(status))"
        }
        return "\(status)"
    }
}

// MARK: - Transport

extension OutputTransport {
    init(halTransport raw: UInt32) {
        switch raw {
        case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: self = .bluetooth
        case kAudioDeviceTransportTypeUSB: self = .usb
        case kAudioDeviceTransportTypeHDMI: self = .hdmi
        case kAudioDeviceTransportTypeDisplayPort: self = .displayPort
        case kAudioDeviceTransportTypeAirPlay: self = .airPlay
        case kAudioDeviceTransportTypeThunderbolt: self = .thunderbolt
        case kAudioDeviceTransportTypeVirtual: self = .virtual
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: self = .aggregate
        default: self = .other
        }
    }
}

// MARK: - Device catalog

enum DeviceCatalog {

    /// The UID this process treats as "our" device. Always `EQT_DEVICE_UID`,
    /// except that DEBUG builds honour `$EQT_DEVICE_UID_OVERRIDE` (test only,
    /// like the driver's `$EQT_RING_NAME_OVERRIDE`). Pointing it at a UID that
    /// doesn't exist hides an installed driver, so the "driver missing" paths
    /// (CLI refusal, onboarding, never touching the default output) can be
    /// exercised on a Mac where the driver IS installed — without sudo and
    /// without uninstalling it. It can only hide the driver: `describe` and
    /// `RoutingPolicy` still exclude the real EQT_DEVICE_UID from the outputs.
    static var virtualDeviceUID: String {
        #if DEBUG
        if let o = getenv("EQT_DEVICE_UID_OVERRIDE"), o.pointee != 0 { return String(cString: o) }
        #endif
        return EQT_DEVICE_UID
    }

    /// The EQtargets Audio virtual device, found by UID (never by name).
    ///
    /// While no app reads the ring, a current driver HIDES the device ('eqta'
    /// in EQTRingProtocol.h). Hidden devices are not in the system device
    /// list; the HAL documents that they are still found by UID. As a second
    /// path that doesn't depend on that, the device is also looked up in our
    /// own plug-in's device list (found by the driver's bundle ID). Never
    /// under the DEBUG override, which exists to hide the driver.
    static func virtualDevice() -> AudioObjectID? {
        if let d = HAL.device(uid: virtualDeviceUID) { return d }
        guard virtualDeviceUID == EQT_DEVICE_UID, let plugIn = HAL.plugIn(bundleID: EQT_DRIVER_BUNDLE_ID) else { return nil }
        return HAL.array(plugIn, HAL.address(kAudioPlugInPropertyDeviceList), of: AudioObjectID.self)
            .first { HAL.uid($0) == EQT_DEVICE_UID }
    }

    /// Every device the processed audio could be played on: has an output
    /// stream, is not hidden, is not EQtargets Audio, and is not an aggregate
    /// that contains EQtargets Audio (that would feed our output back into our
    /// input — a loop). Unsorted.
    static func outputDevices() -> [OutputDevice] {
        let virtualID = virtualDevice()
        return HAL.deviceIDs().compactMap { describe($0, virtualID: virtualID) }
    }

    static func describe(_ id: AudioObjectID, virtualID: AudioObjectID? = virtualDevice()) -> OutputDevice? {
        guard id != HAL.unknown, id != virtualID else { return nil }
        guard HAL.outputStreamCount(id) > 0, !HAL.isHidden(id) else { return nil }
        guard let uid = HAL.uid(id), uid != EQT_DEVICE_UID else { return nil }
        let rawTransport = HAL.transportType(id)
        let transport = OutputTransport(halTransport: rawTransport)
        if transport == .aggregate, let v = virtualID, HAL.aggregateSubDevices(id).contains(v) { return nil }
        return OutputDevice(
            objectID: id,
            uid: uid,
            name: HAL.name(id) ?? uid,
            transport: transport,
            nominalSampleRate: HAL.nominalSampleRate(id) ?? 0,
            hasHardwareVolume: !HAL.settableVolumeElements(id).isEmpty
        )
    }
}

// MARK: - Property listener

/// A listener block as a real ObjC block object (8 bytes), not a Swift closure.
typealias HALListenerBlock = @convention(block) (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void

/// The two HAL entry points a listener uses. Injectable so the add/remove
/// pairing can also be checked without touching any device.
struct HALListenerAPI {
    var add: (AudioObjectID, AudioObjectPropertyAddress, DispatchQueue, @escaping HALListenerBlock) -> OSStatus
    var remove: (AudioObjectID, AudioObjectPropertyAddress, DispatchQueue, @escaping HALListenerBlock) -> OSStatus

    /// WHY dlsym: the SDK imports `AudioObjectPropertyListenerBlock` as a
    /// Swift closure type (16 bytes), so every call to
    /// AudioObjectAdd/RemovePropertyListenerBlock bridges a NEW block object.
    /// The HAL matches removal by block identity, returns noErr anyway, and
    /// keeps the listener alive. Measured on macOS 27.2 with the device's
    /// IsRunning property: after a "successful" Swift-closure removal the
    /// listener still fired twice per start/stop. Calling the same C entry
    /// points through a block-typed pointer hands the HAL the identical block
    /// object both times; then removal works (0 fires after removal).
    static let coreAudio: HALListenerAPI = {
        typealias Entry = @convention(c) (AudioObjectID, UnsafePointer<AudioObjectPropertyAddress>,
                                          DispatchQueue?, HALListenerBlock) -> OSStatus
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        let addSym = dlsym(rtldDefault, "AudioObjectAddPropertyListenerBlock")
        let removeSym = dlsym(rtldDefault, "AudioObjectRemovePropertyListenerBlock")
        guard let addSym, let removeSym else {
            let unavailable: (AudioObjectID, AudioObjectPropertyAddress, DispatchQueue, @escaping HALListenerBlock) -> OSStatus = { _, _, _, _ in
                kAudioHardwareUnspecifiedError
            }
            return HALListenerAPI(add: unavailable, remove: unavailable)
        }
        let addFn = unsafeBitCast(addSym, to: Entry.self)
        let removeFn = unsafeBitCast(removeSym, to: Entry.self)
        return HALListenerAPI(
            add: { object, address, queue, block in
                var a = address
                return addFn(object, &a, queue, block)
            },
            remove: { object, address, queue, block in
                var a = address
                return removeFn(object, &a, queue, block)
            })
    }()
}

/// One block-based property listener. The handler runs on `queue` (a private
/// serial queue — never the render thread); owners hop to the main actor.
/// The ONE block object registered is the one removed (see HALListenerAPI);
/// `cancel()` is idempotent and also runs on deinit.
final class PropertyListener {
    let objectID: AudioObjectID
    let address: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private let block: HALListenerBlock
    private let api: HALListenerAPI
    private(set) var isRegistered = false
    let registrationStatus: OSStatus

    init(object: AudioObjectID, address: AudioObjectPropertyAddress, queue: DispatchQueue,
         api: HALListenerAPI = .coreAudio, handler: @escaping () -> Void) {
        self.objectID = object
        self.address = address
        self.queue = queue
        self.api = api
        self.block = { _, _ in handler() }
        registrationStatus = api.add(object, address, queue, block)
        isRegistered = registrationStatus == noErr
    }

    func cancel() {
        guard isRegistered else { return }
        isRegistered = false
        _ = api.remove(objectID, address, queue, block)
    }

    deinit { cancel() }
}
