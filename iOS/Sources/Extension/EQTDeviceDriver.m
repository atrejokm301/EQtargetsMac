//
//  EQTDeviceDriver.m
//  EQtargets (iOS)
//
//  The AudioServerPlugIn the Media Device Extension publishes. The system mix
//  arrives in DoIOOperation at kAudioServerPlugInIOOperationWriteMix.
//
//  Adapted from ios27-media-device-passthrough (MIT No Attribution), whose
//  behaviour was measured on a device. Keep these rules:
//  - One output device only, transport RemoteStreaming or RemoteScreen, and its
//    UID must equal MediaOutputDevice.id, or registration fails.
//  - ZeroTimeStampPeriod must be at least 10923 frames.
//  - The zero-timestamp seed changes only when StartIO re-anchors the timeline.
//    Changing it every period made later session activations fail with '!pla'.
//  - CanBeDefaultDevice stays 0, so new sessions do not fall onto this device.
//  - There is no unregister call. Registering NULL crashes, and a second
//    registration in one process leaves a dead port that makes the next pick
//    fail. The extension therefore ends its process after each deactivation.
//  - DoIOOperation is real-time: no retain/release, locks or allocation.
//

#import "EQTDeviceDriver.h"
#import "EQTIdentity.h"
#import <CoreAudio/AudioServerPlugIn.h>
#import <os/log.h>
#import <pthread.h>
#import <mach/mach_time.h>
#import <stdatomic.h>
#import <sched.h>
#import <time.h>

enum {
    kObjectID_PlugIn        = kAudioObjectPlugInObject,   // 1
    kObjectID_Device        = 2,
    kObjectID_Stream_Output = 3,
};

enum {
    kEQTStreamConfiguration    = 'slay',
    kEQTPreferredChannelLayout = 'srnd',
};

static const Float64  kSampleRate     = 48000.0;
static const UInt32   kChannelCount   = 2;
static const UInt32   kRingFrames     = 16384;

static os_log_t gLog;

static AudioServerPlugInDriverInterface   gInterface;
static AudioServerPlugInDriverInterface  *gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef         gDriverRef    = &gInterfacePtr;
static AudioServerPlugInHostRef           gHost         = NULL;

static pthread_mutex_t  gStateMutex = PTHREAD_MUTEX_INITIALIZER;
static UInt32           gRefCount   = 1;
static CFStringRef      gDeviceUID  = NULL;
static Boolean          gRegistered = false;
static Boolean          gIORunning  = false;
static UInt32           gIOClients  = 0;
static UInt64           gIOCount    = 0;

static Float64  gZeroSampleTime = 0;
static UInt64   gZeroHostTime   = 0;
static UInt64   gAnchorHostTime = 0;
static UInt64   gPeriodCount    = 0;
static UInt64   gTimelineSeed   = 1;

/// Read on the IO thread, so it is a plain atomic pointer (no ARC).
static _Atomic(EQTLinkSender *) gSender = NULL;
/// Pushes running on the IO thread, so a stop can wait them out.
static _Atomic uint32_t gPushesInFlight = 0;
/// The last StopIO closes this until the given host time, so a late IO cycle can't
/// push audio behind the end-of-stream marker. Timed, not a flag: if the system ever
/// sends a stop it doesn't mean, the client still playing gets a short gap instead
/// of a silent phone. The next StartIO reopens it at once.
static _Atomic uint64_t gPushesClosedUntil = 0;
static const double     kPushesClosedNs    = 100000000.0;   // longer than WaitForPushes

static uint64_t PushesClosedDeadline(void) {
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    return mach_absolute_time() + (uint64_t)(kPushesClosedNs * (double)tb.denom / (double)tb.numer);
}

/// A push still running would publish audio after the end-of-stream marker and
/// reopen the stream. Bounded, so a stuck IO thread can never hang a stop.
static void WaitForPushes(void) {
    const uint64_t giveUp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + 50000000ull;
    while (atomic_load_explicit(&gPushesInFlight, memory_order_seq_cst) != 0
           && clock_gettime_nsec_np(CLOCK_UPTIME_RAW) < giveUp) {
        sched_yield();
    }
}

/// After this returns, no push can land.
static void DetachSender(void) {
    atomic_store_explicit(&gSender, NULL, memory_order_seq_cst);
    WaitForPushes();
}

#if EQT_TEST_HOOKS
void EQTTestSetPushesInFlight(uint32_t count) {
    atomic_store_explicit(&gPushesInFlight, count, memory_order_seq_cst);
}
#endif

static float   gVolume = 1.0f;
static BOOL    gMuted  = NO;

static void FourCCStr(uint32_t v, char out[5]) {
    out[0] = (char)((v >> 24) & 0xff);
    out[1] = (char)((v >> 16) & 0xff);
    out[2] = (char)((v >> 8) & 0xff);
    out[3] = (char)(v & 0xff);
    out[4] = 0;
    for (int i = 0; i < 4; i++) if (out[i] < 0x20 || out[i] > 0x7e) out[i] = '.';
}

#define LOGPROP(tag, obj, addr)                                                  do {                                                                             char _s[5], _c[5];                                                           FourCCStr((addr)->mSelector, _s);                                            FourCCStr((addr)->mScope, _c);                                               os_log(gLog, "%{public}s obj=%u sel=%{public}s scope=%{public}s el=%u",                tag, (unsigned)(obj), _s, _c, (unsigned)(addr)->mElement);        } while (0)

static AudioStreamBasicDescription EQTLinkFormat(void) {
    AudioStreamBasicDescription f = {0};
    f.mSampleRate       = kSampleRate;
    f.mFormatID         = kAudioFormatLinearPCM;
    f.mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    f.mBytesPerPacket   = 4 * kChannelCount;
    f.mFramesPerPacket  = 1;
    f.mBytesPerFrame    = 4 * kChannelCount;
    f.mChannelsPerFrame = kChannelCount;
    f.mBitsPerChannel   = 32;
    return f;
}

// ---- IUnknown ----

static HRESULT EQTD_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface) {
    if (inDriver != gDriverRef || outInterface == NULL) return kAudioHardwareBadObjectError;
    CFUUIDRef req = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    CFUUIDRef iunknown = IUnknownUUID;
    CFUUIDRef plugin   = kAudioServerPlugInDriverInterfaceUUID;
    HRESULT rc = E_NOINTERFACE;
    if (CFEqual(req, iunknown) || CFEqual(req, plugin)) {
        pthread_mutex_lock(&gStateMutex);
        gRefCount++;
        pthread_mutex_unlock(&gStateMutex);
        *outInterface = gDriverRef;
        rc = S_OK;
    }
    CFRelease(req);
    return rc;
}

static ULONG EQTD_AddRef(void *inDriver) {
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex);
    ULONG n = ++gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return n;
}

static ULONG EQTD_Release(void *inDriver) {
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex);
    ULONG n = gRefCount > 0 ? --gRefCount : 0;
    pthread_mutex_unlock(&gStateMutex);
    return n;
}

static OSStatus EQTD_Initialize(AudioServerPlugInDriverRef inDriver,
                              AudioServerPlugInHostRef inHost) {
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    gHost = inHost;
    gAnchorHostTime = 0;
    os_log(gLog, "Initialize");
    return noErr;
}

static OSStatus EQTD_CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc,
                                const AudioServerPlugInClientInfo *c, AudioObjectID *out) {
    (void)d; (void)desc; (void)c; (void)out;
    return kAudioHardwareUnsupportedOperationError;
}
static OSStatus EQTD_DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID id) {
    (void)d; (void)id;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus EQTD_AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID dev,
                                   const AudioServerPlugInClientInfo *info) {
    (void)d;
    if (dev != kObjectID_Device) return kAudioHardwareBadObjectError;
    os_log(gLog, "AddDeviceClient pid=%d bundle=%{public}@",
           info ? info->mProcessID : -1,
           info ? (__bridge NSString *)info->mBundleID : @"-");
    return noErr;
}

static OSStatus EQTD_RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID dev,
                                      const AudioServerPlugInClientInfo *info) {
    (void)d; (void)info;
    if (dev != kObjectID_Device) return kAudioHardwareBadObjectError;
    os_log(gLog, "RemoveDeviceClient");
    return noErr;
}

static OSStatus EQTD_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef d,
                                                    AudioObjectID dev, UInt64 action,
                                                    void *info) {
    (void)d; (void)dev; (void)action; (void)info;
    return noErr;
}
static OSStatus EQTD_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef d,
                                                  AudioObjectID dev, UInt64 action,
                                                  void *info) {
    (void)d; (void)dev; (void)action; (void)info;
    return noErr;
}

static Boolean EQTD_HasProperty(AudioServerPlugInDriverRef d, AudioObjectID obj,
                              pid_t client, const AudioObjectPropertyAddress *addr) {
    (void)d; (void)client;
    if (!addr) return false;
    switch (obj) {
        case kObjectID_PlugIn:
            switch (addr->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioObjectPropertyManufacturer:
                case kAudioObjectPropertyOwnedObjects:
                case kAudioPlugInPropertyDeviceList:
                case kAudioPlugInPropertyTranslateUIDToDevice:
                    return true;
            }
            return false;
        case kObjectID_Device:
            switch (addr->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioObjectPropertyName:
                case kAudioObjectPropertyManufacturer:
                case kAudioObjectPropertyOwnedObjects:
                case kAudioDevicePropertyDeviceUID:
                case kAudioDevicePropertyModelUID:
                case kAudioDevicePropertyTransportType:
                case kAudioDevicePropertyRelatedDevices:
                case kAudioDevicePropertyClockDomain:
                case kAudioDevicePropertyDeviceIsAlive:
                case kAudioDevicePropertyDeviceIsRunning:
                case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                case kAudioDevicePropertyLatency:
                case kAudioDevicePropertyStreams:
                case kAudioDevicePropertySafetyOffset:
                case kAudioDevicePropertyNominalSampleRate:
                case kAudioDevicePropertyAvailableNominalSampleRates:
                case kAudioDevicePropertyIsHidden:
                case kAudioDevicePropertyZeroTimeStampPeriod:
                case kAudioDevicePropertyPreferredChannelsForStereo:
                case kEQTStreamConfiguration:
                case kEQTPreferredChannelLayout:
                case kAudioObjectPropertyControlList:
                    return true;
            }
            return false;
        case kObjectID_Stream_Output:
            switch (addr->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioStreamPropertyIsActive:
                case kAudioStreamPropertyDirection:
                case kAudioStreamPropertyTerminalType:
                case kAudioStreamPropertyStartingChannel:
                case kAudioStreamPropertyLatency:
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat:
                case kAudioStreamPropertyAvailableVirtualFormats:
                case kAudioStreamPropertyAvailablePhysicalFormats:
                    return true;
            }
            return false;
    }
    LOGPROP("HAS-NO", obj, addr);
    return false;
}

static OSStatus EQTD_IsPropertySettable(AudioServerPlugInDriverRef d, AudioObjectID obj,
                                      pid_t client, const AudioObjectPropertyAddress *addr,
                                      Boolean *outSettable) {
    (void)d; (void)client;
    if (!addr || !outSettable) return kAudioHardwareIllegalOperationError;
    *outSettable = false;
    if (obj == kObjectID_Device && addr->mSelector == kAudioDevicePropertyNominalSampleRate) {
        *outSettable = true;
    }
    if (obj == kObjectID_Stream_Output && addr->mSelector == kAudioStreamPropertyIsActive) {
        *outSettable = true;
    }
    return noErr;
}

#define REQTD_SIZE(n)  do { if (outSize) *outSize = (n); return noErr; } while (0)

static OSStatus EQTD_GetPropertyDataSize(AudioServerPlugInDriverRef d, AudioObjectID obj,
                                       pid_t client, const AudioObjectPropertyAddress *addr,
                                       UInt32 qualSize, const void *qual, UInt32 *outSize) {
    (void)d; (void)client; (void)qualSize; (void)qual;
    if (!addr || !outSize) return kAudioHardwareIllegalOperationError;

    switch (obj) {
        case kObjectID_PlugIn:
            switch (addr->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:              REQTD_SIZE(sizeof(AudioClassID));
                case kAudioObjectPropertyOwner:              REQTD_SIZE(sizeof(AudioObjectID));
                case kAudioObjectPropertyManufacturer:        REQTD_SIZE(sizeof(CFStringRef));
                case kAudioObjectPropertyOwnedObjects:
                case kAudioPlugInPropertyDeviceList:          REQTD_SIZE(sizeof(AudioObjectID));
                case kAudioPlugInPropertyTranslateUIDToDevice: REQTD_SIZE(sizeof(AudioObjectID));
            }
            break;
        case kObjectID_Device:
            switch (addr->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:              REQTD_SIZE(sizeof(AudioClassID));
                case kAudioObjectPropertyOwner:              REQTD_SIZE(sizeof(AudioObjectID));
                case kAudioObjectPropertyName:
                case kAudioObjectPropertyManufacturer:
                case kAudioDevicePropertyDeviceUID:
                case kAudioDevicePropertyModelUID:            REQTD_SIZE(sizeof(CFStringRef));
                case kAudioObjectPropertyOwnedObjects:
                case kAudioDevicePropertyStreams:
                    REQTD_SIZE(addr->mScope == kAudioObjectPropertyScopeInput
                             ? 0u : (UInt32)sizeof(AudioObjectID));
                case kAudioDevicePropertyTransportType:
                case kAudioDevicePropertyClockDomain:
                case kAudioDevicePropertyDeviceIsAlive:
                case kAudioDevicePropertyDeviceIsRunning:
                case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                case kAudioDevicePropertyLatency:
                case kAudioDevicePropertySafetyOffset:
                case kAudioDevicePropertyIsHidden:
                case kAudioDevicePropertyZeroTimeStampPeriod: REQTD_SIZE(sizeof(UInt32));
                case kAudioDevicePropertyRelatedDevices:      REQTD_SIZE(sizeof(AudioObjectID));
                case kAudioDevicePropertyNominalSampleRate:   REQTD_SIZE(sizeof(Float64));
                case kAudioDevicePropertyAvailableNominalSampleRates:
                                                              REQTD_SIZE(sizeof(AudioValueRange));
                case kAudioDevicePropertyPreferredChannelsForStereo:
                                                              REQTD_SIZE(2 * sizeof(UInt32));
                case kEQTStreamConfiguration:
                    REQTD_SIZE(addr->mScope == kAudioObjectPropertyScopeInput
                             ? (UInt32)offsetof(AudioBufferList, mBuffers)
                             : (UInt32)(offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer)));
                case kEQTPreferredChannelLayout:
                    REQTD_SIZE(offsetof(AudioChannelLayout, mChannelDescriptions));
                case kAudioObjectPropertyControlList:
                    REQTD_SIZE(0);
            }
            break;
        case kObjectID_Stream_Output:
            switch (addr->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:              REQTD_SIZE(sizeof(AudioClassID));
                case kAudioObjectPropertyOwner:              REQTD_SIZE(sizeof(AudioObjectID));
                case kAudioStreamPropertyIsActive:
                case kAudioStreamPropertyDirection:
                case kAudioStreamPropertyTerminalType:
                case kAudioStreamPropertyStartingChannel:
                case kAudioStreamPropertyLatency:            REQTD_SIZE(sizeof(UInt32));
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat:
                                            REQTD_SIZE(sizeof(AudioStreamBasicDescription));
                case kAudioStreamPropertyAvailableVirtualFormats:
                case kAudioStreamPropertyAvailablePhysicalFormats:
                                            REQTD_SIZE(sizeof(AudioStreamRangedDescription));
            }
            break;
    }
    LOGPROP("SIZE-UNKNOWN", obj, addr);
    return kAudioHardwareUnknownPropertyError;
}

#undef REQTD_SIZE

#define PUT(type, value) \
    do { if (inDataSize < sizeof(type)) return kAudioHardwareBadPropertySizeError; \
         *((type *)outData) = (value); *outDataSize = sizeof(type); return noErr; } while (0)

static OSStatus EQTD_GetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID obj,
                                   pid_t client, const AudioObjectPropertyAddress *addr,
                                   UInt32 qualSize, const void *qual,
                                   UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    (void)d; (void)client;
    if (!addr || !outDataSize || !outData) return kAudioHardwareIllegalOperationError;

    switch (obj) {
        case kObjectID_PlugIn:
            switch (addr->mSelector) {
                case kAudioObjectPropertyBaseClass: PUT(AudioClassID, kAudioObjectClassID);
                case kAudioObjectPropertyClass:     PUT(AudioClassID, kAudioPlugInClassID);
                case kAudioObjectPropertyOwner:     PUT(AudioObjectID, kAudioObjectUnknown);
                case kAudioObjectPropertyManufacturer:
                    PUT(CFStringRef, (CFStringRef)CFRetain(CFSTR(EQT_ROUTE_MANUFACTURER)));
                case kAudioObjectPropertyOwnedObjects:
                case kAudioPlugInPropertyDeviceList:
                    if (inDataSize < sizeof(AudioObjectID)) { *outDataSize = 0; return noErr; }
                    ((AudioObjectID *)outData)[0] = kObjectID_Device;
                    *outDataSize = sizeof(AudioObjectID);
                    return noErr;
                case kAudioPlugInPropertyTranslateUIDToDevice: {
                    if (qualSize != sizeof(CFStringRef) || !qual)
                        return kAudioHardwareBadPropertySizeError;
                    CFStringRef want = *((CFStringRef *)qual);
                    AudioObjectID r = kAudioObjectUnknown;
                    if (gDeviceUID && want && CFEqual(want, gDeviceUID)) r = kObjectID_Device;
                    PUT(AudioObjectID, r);
                }
            }
            break;

        case kObjectID_Device:
            switch (addr->mSelector) {
                case kAudioObjectPropertyBaseClass: PUT(AudioClassID, kAudioObjectClassID);
                case kAudioObjectPropertyClass:     PUT(AudioClassID, kAudioDeviceClassID);
                case kAudioObjectPropertyOwner:     PUT(AudioObjectID, kObjectID_PlugIn);
                case kAudioObjectPropertyName:
                    PUT(CFStringRef, (CFStringRef)CFRetain(CFSTR(EQT_ROUTE_NAME)));
                case kAudioObjectPropertyManufacturer:
                    PUT(CFStringRef, (CFStringRef)CFRetain(CFSTR(EQT_ROUTE_MANUFACTURER)));
                case kAudioDevicePropertyDeviceUID:
                    PUT(CFStringRef, gDeviceUID ? (CFStringRef)CFRetain(gDeviceUID)
                                                : (CFStringRef)CFRetain(CFSTR("")));
                case kAudioDevicePropertyModelUID:
                    PUT(CFStringRef, (CFStringRef)CFRetain(CFSTR(EQT_ROUTE_MODEL_UID)));
                case kAudioDevicePropertyTransportType:
                    PUT(UInt32, kAudioDeviceTransportTypeRemoteStreaming);
                case kAudioDevicePropertyRelatedDevices:
                    if (inDataSize < sizeof(AudioObjectID)) { *outDataSize = 0; return noErr; }
                    ((AudioObjectID *)outData)[0] = kObjectID_Device;
                    *outDataSize = sizeof(AudioObjectID);
                    return noErr;
                case kAudioDevicePropertyClockDomain:       PUT(UInt32, 0);
                case kAudioDevicePropertyDeviceIsAlive:     PUT(UInt32, 1);
                case kAudioDevicePropertyDeviceIsRunning:   PUT(UInt32, gIORunning ? 1 : 0);
                case kAudioDevicePropertyDeviceCanBeDefaultDevice:       PUT(UInt32, 0);
                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: PUT(UInt32, 0);
                case kAudioDevicePropertyLatency:           PUT(UInt32, 0);
                case kAudioObjectPropertyOwnedObjects:
                case kAudioDevicePropertyStreams: {
                    AudioObjectID ids[1];
                    UInt32 n = 0;
                    if (addr->mScope != kAudioObjectPropertyScopeInput) {
                        ids[n++] = kObjectID_Stream_Output;
                    }
                    UInt32 fit = inDataSize / (UInt32)sizeof(AudioObjectID);
                    if (fit > n) fit = n;
                    for (UInt32 i = 0; i < fit; i++) ((AudioObjectID *)outData)[i] = ids[i];
                    *outDataSize = fit * (UInt32)sizeof(AudioObjectID);
                    return noErr;
                }
                case kAudioDevicePropertySafetyOffset:      PUT(UInt32, 512);
                case kAudioDevicePropertyNominalSampleRate: PUT(Float64, kSampleRate);
                case kAudioDevicePropertyAvailableNominalSampleRates: {
                    if (inDataSize < sizeof(AudioValueRange)) { *outDataSize = 0; return noErr; }
                    AudioValueRange *r = (AudioValueRange *)outData;
                    r[0].mMinimum = kSampleRate;
                    r[0].mMaximum = kSampleRate;
                    *outDataSize = sizeof(AudioValueRange);
                    return noErr;
                }
                case kAudioDevicePropertyIsHidden:          PUT(UInt32, 0);
                case kAudioDevicePropertyZeroTimeStampPeriod: PUT(UInt32, kRingFrames);
                case kAudioDevicePropertyPreferredChannelsForStereo: {
                    if (inDataSize < 2 * sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                    ((UInt32 *)outData)[0] = 1;
                    ((UInt32 *)outData)[1] = 2;
                    *outDataSize = 2 * sizeof(UInt32);
                    return noErr;
                }
                case kEQTStreamConfiguration: {
                    AudioBufferList *bl = (AudioBufferList *)outData;
                    if (addr->mScope == kAudioObjectPropertyScopeInput) {
                        size_t need = offsetof(AudioBufferList, mBuffers);
                        if (inDataSize < need) return kAudioHardwareBadPropertySizeError;
                        bl->mNumberBuffers = 0;
                        *outDataSize = (UInt32)need;
                        return noErr;
                    }
                    size_t need = offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer);
                    if (inDataSize < need) return kAudioHardwareBadPropertySizeError;
                    bl->mNumberBuffers = 1;
                    bl->mBuffers[0].mNumberChannels = kChannelCount;
                    bl->mBuffers[0].mDataByteSize = 0;
                    bl->mBuffers[0].mData = NULL;
                    *outDataSize = (UInt32)need;
                    return noErr;
                }
                case kAudioObjectPropertyControlList:
                    *outDataSize = 0;
                    return noErr;
                case kEQTPreferredChannelLayout: {
                    size_t need = offsetof(AudioChannelLayout, mChannelDescriptions);
                    if (inDataSize < need) return kAudioHardwareBadPropertySizeError;
                    AudioChannelLayout *cl = (AudioChannelLayout *)outData;
                    cl->mChannelLayoutTag = kAudioChannelLayoutTag_Stereo;
                    cl->mChannelBitmap = 0;
                    cl->mNumberChannelDescriptions = 0;
                    *outDataSize = (UInt32)need;
                    return noErr;
                }
            }
            break;

        case kObjectID_Stream_Output:
            switch (addr->mSelector) {
                case kAudioObjectPropertyBaseClass: PUT(AudioClassID, kAudioObjectClassID);
                case kAudioObjectPropertyClass:     PUT(AudioClassID, kAudioStreamClassID);
                case kAudioObjectPropertyOwner:     PUT(AudioObjectID, kObjectID_Device);
                case kAudioStreamPropertyIsActive:  PUT(UInt32, 1);
                case kAudioStreamPropertyDirection:
                    PUT(UInt32, 0);
                case kAudioStreamPropertyTerminalType:
                    PUT(UInt32, kAudioStreamTerminalTypeSpeaker);
                case kAudioStreamPropertyStartingChannel: PUT(UInt32, 1);
                case kAudioStreamPropertyLatency:         PUT(UInt32, 0);
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat:
                    PUT(AudioStreamBasicDescription, EQTLinkFormat());
                case kAudioStreamPropertyAvailableVirtualFormats:
                case kAudioStreamPropertyAvailablePhysicalFormats: {
                    if (inDataSize < sizeof(AudioStreamRangedDescription)) { *outDataSize = 0; return noErr; }
                    AudioStreamRangedDescription *r = (AudioStreamRangedDescription *)outData;
                    r[0].mFormat = EQTLinkFormat();
                    r[0].mSampleRateRange.mMinimum = kSampleRate;
                    r[0].mSampleRateRange.mMaximum = kSampleRate;
                    *outDataSize = sizeof(AudioStreamRangedDescription);
                    return noErr;
                }
            }
            break;
    }
    LOGPROP("DATA-UNKNOWN", obj, addr);
    return kAudioHardwareUnknownPropertyError;
}

#undef PUT

static OSStatus EQTD_SetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID obj,
                                   pid_t client, const AudioObjectPropertyAddress *addr,
                                   UInt32 qualSize, const void *qual,
                                   UInt32 inDataSize, const void *inData) {
    (void)d; (void)client; (void)qualSize; (void)qual;
    if (!addr) return kAudioHardwareIllegalOperationError;

    if (obj == kObjectID_Stream_Output && addr->mSelector == kAudioStreamPropertyIsActive) {
        return noErr;
    }
    if (obj == kObjectID_Device && addr->mSelector == kAudioDevicePropertyNominalSampleRate) {
        if (!inData || inDataSize < sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
        Float64 want = *((const Float64 *)inData);
        if (want > kSampleRate - 1.0 && want < kSampleRate + 1.0) return noErr;
        return kAudioHardwareIllegalOperationError;
    }

    return kAudioHardwareUnknownPropertyError;
}

// ---- IO ----

static OSStatus EQTD_StartIO(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client) {
    (void)d; (void)client;
    if (dev != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    // One device clock for all clients: only the first start re-anchors it.
    const Boolean first = gIOClients == 0;
    gIOClients += 1;
    if (first) {
        gIORunning = true;
        gIOCount = 0;
        gTimelineSeed++;
        gAnchorHostTime = 0;
        gZeroSampleTime = 0;
        gZeroHostTime = 0;
        gPeriodCount = 0;
        atomic_store_explicit(&gPushesClosedUntil, 0, memory_order_seq_cst);
        // Under the lock, so it can't interleave with a stop finishing its wait.
        EQTLinkSender *sender = atomic_load_explicit(&gSender, memory_order_acquire);
        if (sender) EQTLinkSenderSetDelivering(sender, 1);
    }
    pthread_mutex_unlock(&gStateMutex);
    os_log(gLog, "StartIO");
    return noErr;
}

static OSStatus EQTD_StopIO(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client) {
    (void)d; (void)client;
    if (dev != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    if (gIOClients > 0) gIOClients -= 1;
    const Boolean last = gIOClients == 0;
    if (last) {
        gIORunning = false;
        atomic_store_explicit(&gPushesClosedUntil, PushesClosedDeadline(), memory_order_seq_cst);
    }
    pthread_mutex_unlock(&gStateMutex);
    EQTLinkSender *sender = atomic_load_explicit(&gSender, memory_order_acquire);
    if (last && sender) {
        WaitForPushes();    // the last IO cycle may still be finishing
        pthread_mutex_lock(&gStateMutex);
        // A new client may have started during the wait. Its stream must keep running.
        if (gIOClients == 0) EQTLinkSenderSetDelivering(sender, 0);
        pthread_mutex_unlock(&gStateMutex);
    }
    os_log(gLog, "StopIO frames=%llu", (unsigned long long)gIOCount);
    return noErr;
}

static OSStatus EQTD_GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID dev,
                                    UInt32 client, Float64 *outSampleTime,
                                    UInt64 *outHostTime, UInt64 *outSeed) {
    (void)d; (void)client;
    if (dev != kObjectID_Device) return kAudioHardwareBadObjectError;

    static mach_timebase_info_data_t tb;
    if (tb.denom == 0) mach_timebase_info(&tb);

    const Float64 nsPerFrame = 1.0e9 / kSampleRate;
    const Float64 hostTicksPerFrame = nsPerFrame * (Float64)tb.denom / (Float64)tb.numer;
    const Float64 hostTicksPerRing = hostTicksPerFrame * (Float64)kRingFrames;

    UInt64 now = mach_absolute_time();

    if (gAnchorHostTime == 0) {
        gAnchorHostTime = now;
        gPeriodCount = 0;
    }
    Float64 offset = ((Float64)(gPeriodCount + 1)) * hostTicksPerRing;
    UInt64 nextHostTime = gAnchorHostTime + (UInt64)offset;
    if (nextHostTime <= now) {
        gPeriodCount++;
    }
    Float64 st = (Float64)(gPeriodCount * (UInt64)kRingFrames);
    UInt64 ht = gAnchorHostTime + (UInt64)(((Float64)gPeriodCount) * hostTicksPerRing);
    gZeroSampleTime = st;
    gZeroHostTime = ht;

    if (outSampleTime) *outSampleTime = st;
    if (outHostTime)   *outHostTime   = ht;
    if (outSeed)       *outSeed       = gTimelineSeed;
    return noErr;
}

static OSStatus EQTD_WillDoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev,
                                     UInt32 client, UInt32 op,
                                     Boolean *outWillDo, Boolean *outWillDoInPlace) {
    (void)d; (void)client;
    if (dev != kObjectID_Device) return kAudioHardwareBadObjectError;
    Boolean will = false, inPlace = true;
    switch (op) {
        case kAudioServerPlugInIOOperationWriteMix:
            will = true;
            break;
        default:
            will = false;
            break;
    }
    if (outWillDo) *outWillDo = will;
    if (outWillDoInPlace) *outWillDoInPlace = inPlace;
    return noErr;
}

static OSStatus EQTD_BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev,
                                    UInt32 client, UInt32 op, UInt32 frames,
                                    const AudioServerPlugInIOCycleInfo *cycle) {
    (void)d; (void)dev; (void)client; (void)op; (void)frames; (void)cycle;
    return noErr;
}

static OSStatus EQTD_DoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev,
                                 AudioObjectID stream, UInt32 client, UInt32 op,
                                 UInt32 frames, const AudioServerPlugInIOCycleInfo *cycle,
                                 void *ioMainBuffer, void *ioSecondaryBuffer) {
    (void)d; (void)stream; (void)client; (void)cycle; (void)ioSecondaryBuffer;
    if (dev != kObjectID_Device) return kAudioHardwareBadObjectError;
    if (!ioMainBuffer || frames == 0) return noErr;

    if (op != kAudioServerPlugInIOOperationWriteMix) return noErr;

    gIOCount += frames;

    // The stream format is interleaved float32 stereo. The write time is what
    // lets the app's PLL ignore socket jitter (see EQTLink.h).
    atomic_fetch_add_explicit(&gPushesInFlight, 1, memory_order_seq_cst);   // see DetachSender
    EQTLinkSender *sender = atomic_load_explicit(&gSender, memory_order_seq_cst);
    // Read after the count: a stop closing this either sees the count or is seen here.
    if (sender && mach_absolute_time() >= atomic_load_explicit(&gPushesClosedUntil, memory_order_seq_cst)) {
        EQTLinkSenderPush(sender, (const float *)ioMainBuffer, frames, kChannelCount,
                          mach_absolute_time());
    }
    atomic_fetch_sub_explicit(&gPushesInFlight, 1, memory_order_release);

    if (gMuted) {
        memset(ioMainBuffer, 0, (size_t)frames * kChannelCount * sizeof(float));
    }
    return noErr;
}

static OSStatus EQTD_EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev,
                                  UInt32 client, UInt32 op, UInt32 frames,
                                  const AudioServerPlugInIOCycleInfo *cycle) {
    (void)d; (void)dev; (void)client; (void)op; (void)frames; (void)cycle;
    return noErr;
}

@implementation EQTDeviceDriver

+ (EQTDeviceDriver *)shared {
    static EQTDeviceDriver *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gLog = os_log_create(EQT_LOG_SUBSYSTEM, "driver");
        s = [[EQTDeviceDriver alloc] init];
    });
    return s;
}

- (float)volume { return gVolume; }
- (void)setVolume:(float)v { gVolume = v; }
- (BOOL)muted { return gMuted; }
- (void)setMuted:(BOOL)m { gMuted = m; }
- (double)sampleRate { return kSampleRate; }
- (uint32_t)channelCount { return kChannelCount; }
- (uint64_t)framesDelivered { return gIOCount; }

static void EQTFillInterfaceOnce(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gInterface._reserved                        = NULL;
        gInterface.QueryInterface                   = EQTD_QueryInterface;
        gInterface.AddRef                           = EQTD_AddRef;
        gInterface.Release                          = EQTD_Release;
        gInterface.Initialize                       = EQTD_Initialize;
        gInterface.CreateDevice                     = EQTD_CreateDevice;
        gInterface.DestroyDevice                    = EQTD_DestroyDevice;
        gInterface.AddDeviceClient                  = EQTD_AddDeviceClient;
        gInterface.RemoveDeviceClient               = EQTD_RemoveDeviceClient;
        gInterface.PerformDeviceConfigurationChange = EQTD_PerformDeviceConfigurationChange;
        gInterface.AbortDeviceConfigurationChange   = EQTD_AbortDeviceConfigurationChange;
        gInterface.HasProperty                      = EQTD_HasProperty;
        gInterface.IsPropertySettable               = EQTD_IsPropertySettable;
        gInterface.GetPropertyDataSize              = EQTD_GetPropertyDataSize;
        gInterface.GetPropertyData                  = EQTD_GetPropertyData;
        gInterface.SetPropertyData                  = EQTD_SetPropertyData;
        gInterface.StartIO                          = EQTD_StartIO;
        gInterface.StopIO                           = EQTD_StopIO;
        gInterface.GetZeroTimeStamp                 = EQTD_GetZeroTimeStamp;
        gInterface.WillDoIOOperation                = EQTD_WillDoIOOperation;
        gInterface.BeginIOOperation                 = EQTD_BeginIOOperation;
        gInterface.DoIOOperation                    = EQTD_DoIOOperation;
        gInterface.EndIOOperation                   = EQTD_EndIOOperation;
    });
}

- (OSStatus)publishWithDeviceUID:(NSString *)uid {
    // Constant for the life of the process, and HAL threads read it without a lock.
    if (!gDeviceUID) gDeviceUID = (CFStringRef)CFBridgingRetain([uid copy]);

    EQTFillInterfaceOnce();

    OSStatus st = AudioServerPlugInRegisterMediaDeviceExtension(gDriverRef, ^{
        gRegistered = false;
        os_log_error(gLog, "connection to the audio server was interrupted");
        void (^lost)(void) = self.onAudioServerLost;
        if (lost) lost();
    });
    if (st == noErr) gRegistered = true;
    os_log_error(gLog, "publish uid=%{public}@ status=%d registered=%d",
                 uid, (int)st, (int)gRegistered);
    return st;
}

/// Stops delivery. It cannot remove the registration: see the header comment.
- (void)unpublish {
    DetachSender();

    gRegistered = false;

    os_log(gLog, "unpublish frames=%llu registered=%d",
           (unsigned long long)gIOCount, (int)gRegistered);
}

- (void)startCaptureWithSender:(EQTLinkSender *)sender {
    atomic_store_explicit(&gSender, sender, memory_order_release);
    gIOCount = 0;
    os_log(gLog, "startCapture");
}

- (void)stopCapture {
    DetachSender();
    os_log(gLog, "stopCapture frames=%llu", (unsigned long long)gIOCount);
}

@end
