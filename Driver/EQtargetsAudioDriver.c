//
//  EQtargetsAudioDriver.c
//  EQtargets Audio — AudioServerPlugIn (HAL driver), C17.
//
//  WHAT IT IS
//  An OUTPUT-ONLY virtual audio device, "EQtargets Audio". While EQtargets is
//  on, macOS's default output points at it: coreaudiod mixes every app into
//  this device and our WriteMix copies that mix, bit for bit, into the
//  shared-memory ring (Shared/EQTRingProtocol.h). EQtargets.app reads the ring,
//  runs the EQ chain and plays the result on the real output device.
//
//  WHY OUTPUT-ONLY (do not "simplify")
//  A loopback cable (BlackHole / eqMac style) publishes an input stream, and
//  any input stream costs the app Microphone permission and lights the orange
//  recording indicator. This device has NO input stream and answers every
//  input-scope query with "nothing here" (zero streams, zero owned objects,
//  cannot be the default input). The mix leaves through shared memory instead.
//
//  STRUCTURE (modelled on Apple's NullAudio sample)
//      plug-in (1) ─┬─ box (2)
//                   └─ device (3) ─┬─ output stream (4)   2 ch float32 interleaved
//                                  ├─ master output volume control (5)
//                                  └─ master output mute control (6)
//
//  THREADING
//  • Property state lives behind gStateMutex, which is only ever taken on
//    non-IO threads.
//  • Host callbacks (PropertiesChanged, RequestDeviceConfigurationChange,
//    storage) are never made while holding gStateMutex: a host may call
//    straight back into the driver (the test harness's host does).
//  • The IO thread (GetZeroTimeStamp, Begin/Do/EndIOOperation) takes no lock,
//    allocates nothing, makes no CF or logging calls: it reads the clock
//    through atomics and writes the ring lock-free. Those functions are
//    CA_REALTIME_API (nonblocking) and EQTDriver.h turns on
//    -Wfunction-effects, so the compiler enforces it.
//
//  VOLUME / MUTE
//  The device exposes a master output volume and mute so the Mac's volume keys
//  and the Sound menu keep working while EQtargets Audio is the default output.
//  The driver does NOT apply them: the ring stays bit-transparent and the app
//  mirrors the values onto the real output device (or applies them digitally
//  when that device has no hardware volume). Both values are persisted through
//  the host's storage, so a coreaudiod restart never makes the volume jump.
//
//  VOLUME TAPER (scalar s ∈ [0, 1]  ↔  gain g ∈ [−64, 0] dB)
//      a(s) = F + (1 − F)·s,            F = 10^(−64/60) ≈ 0.0857696
//      g(s) = 20·log10(a³) = 60·log10(a)
//      s(g) = (10^(g/60) − F) / (1 − F)
//  The amplitude is the CUBE of a linearly moving value — the "cubic" volume
//  law used by PulseAudio and most media players, which tracks perceived
//  loudness far better than a linear-amplitude or linear-dB slider. The offset
//  F lands the curve exactly on −64 dB at s = 0 (a pure cube would reach −∞
//  and leave a dead zone at the bottom), so the mapping is a strict, smooth
//  bijection. Reference points: s = 1 → 0 dB, 0.75 → −6.8 dB, 0.5 → −15.9 dB,
//  0.25 → −30.2 dB, 0 → −64 dB. Each of the 16 volume-key steps is ≈ 1.5 dB
//  near the top and ≈ 13 dB at the very bottom.
//

#include "EQTDriver.h"

#include <dispatch/dispatch.h>
#include <errno.h>
#include <mach/mach_time.h>
#include <math.h>
#include <os/log.h>
#include <pthread.h>
#include <signal.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

// ================================================================ constants

static const Float64 kEQTSampleRates[] = { 44100.0, 48000.0, 88200.0, 96000.0, 176400.0, 192000.0 };
#define kEQTSampleRateCount ((UInt32)(sizeof(kEQTSampleRates) / sizeof(kEQTSampleRates[0])))

#define kEQTVolumeMinDB   (-64.0)
#define kEQTVolumeMaxDB   (0.0)
#define kEQTVolumeFloor   0.08576958985908942   /* 10^(-64/60): see VOLUME TAPER above */

/// Delay before persisting volume/mute, so a slider drag or a held volume key
/// becomes one storage write instead of dozens.
#define kEQTPersistDelayNs   (250ull * NSEC_PER_MSEC)

/// |sample time| beyond this is treated as garbage (it is ~1500 years @ 192 kHz).
#define kEQTMaxAbsSampleTime 9.0e15

/// Processes that can be attached as ring readers at once ('eqta'). One app
/// is the design; a second copy (or the CLI) fits easily.
#define kEQTMaxReaders 8u

static CFStringRef const kEQTStorageKeyVolume = CFSTR("output.volume.scalar");
static CFStringRef const kEQTStorageKeyMute   = CFSTR("output.mute");

// ================================================================ state

static os_log_t EQTLog(void) {
    static os_log_t sLog;
    static dispatch_once_t sOnce;
    dispatch_once(&sOnce, ^{ sLog = os_log_create(EQT_DRIVER_BUNDLE_ID, "driver"); });
    return sLog;
}

static pthread_mutex_t gStateMutex = PTHREAD_MUTEX_INITIALIZER;

// ---- guarded by gStateMutex ----
static UInt32                   gRefCount         = 0;
static AudioServerPlugInHostRef gHost             = NULL;   // written once in Initialize
static Float64                  gSampleRate       = EQT_DEFAULT_SAMPLE_RATE;
static UInt32                   gIOClientCount    = 0;
static Float32                  gVolumeScalar     = 1.0f;
static UInt32                   gMute             = 0;
static UInt32                   gStreamIsActive   = 1;
/// Frames from the app via 'eqtl', as APPLIED: what kAudioDevicePropertyLatency
/// reports. Changed only inside PerformDeviceConfigurationChange — the HAL does
/// not pass a plain PropertiesChanged for the latency on to running clients
/// (measured 2026-11-14: the 'eqtl' notice arrived, the latency one never did),
/// so players kept the latency they read at start until relaunched.
static UInt32                   gClientLatency    = 0;
/// The latency most recently ASKED for via 'eqtl' (what 'eqtl' reads back). It
/// differs from gClientLatency while a configuration change is pending.
static UInt32                   gRequestedLatency = 0;
/// The rate most recently ASKED for (set nominal rate / stream format). It
/// differs from gSampleRate while a configuration change is pending; see
/// EQT_SetNominalRate.
static Float64                  gRequestedRate    = EQT_DEFAULT_SAMPLE_RATE;
/// 'eqta' (see EQTRingProtocol.h): which processes read the ring. Until any
/// process sets the property the device is always visible (legacy).
static Boolean                  gVisibilityManaged = false;
static UInt32                   gReaderCount      = 0;
static pid_t                    gReaderPIDs[kEQTMaxReaders];
static dispatch_source_t        gReaderWatches[kEQTMaxReaders];   // exit watch per reader (may be NULL)
static Boolean                  gPersistPending   = false;

// ---- set once in Initialize (before the host can start IO), then read-only ----
static EQTRingHeader *gRing               = NULL;
static double         gHostTicksPerSecond = 0.0;

// ---- clock: written (under gStateMutex) only while IO is stopped, read by the
//      IO thread lock-free; accessed exclusively through __atomic builtins ----
static uint64_t gClockAnchorHostTime    = 0;
static uint64_t gClockTicksPerFrameBits = 0;   // IEEE-754 bits of host ticks per frame
static uint64_t gClockPeriodCount       = 0;   // advanced only by GetZeroTimeStamp (IO thread)
static uint64_t gClockSeed              = 0;   // changes whenever the timeline is re-anchored

// ================================================================ interface table

static HRESULT  EQT_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface);
static ULONG    EQT_AddRef(void *inDriver);
static ULONG    EQT_Release(void *inDriver);
static OSStatus EQT_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus EQT_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription,
                                 const AudioServerPlugInClientInfo *inClientInfo, AudioObjectID *outDeviceObjectID);
static OSStatus EQT_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus EQT_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                    const AudioServerPlugInClientInfo *inClientInfo);
static OSStatus EQT_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                       const AudioServerPlugInClientInfo *inClientInfo);
static OSStatus EQT_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                                     UInt64 inChangeAction, void *inChangeInfo);
static OSStatus EQT_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                                   UInt64 inChangeAction, void *inChangeInfo);
static Boolean  EQT_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                const AudioObjectPropertyAddress *inAddress);
static OSStatus EQT_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                       const AudioObjectPropertyAddress *inAddress, Boolean *outIsSettable);
static OSStatus EQT_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                        const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize,
                                        const void *inQualifierData, UInt32 *outDataSize);
static OSStatus EQT_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                    const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize,
                                    const void *inQualifierData, UInt32 inDataSize, UInt32 *outDataSize, void *outData);
static OSStatus EQT_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                    const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize,
                                    const void *inQualifierData, UInt32 inDataSize, const void *inData);
static OSStatus EQT_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus EQT_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus EQT_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                     Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed) CA_REALTIME_API;
static OSStatus EQT_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                      UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace);
static OSStatus EQT_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                     UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                     const AudioServerPlugInIOCycleInfo *inIOCycleInfo) CA_REALTIME_API;
static OSStatus EQT_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID,
                                  UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                  const AudioServerPlugInIOCycleInfo *inIOCycleInfo, void *ioMainBuffer,
                                  void *ioSecondaryBuffer) CA_REALTIME_API;
static OSStatus EQT_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                   UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                   const AudioServerPlugInIOCycleInfo *inIOCycleInfo) CA_REALTIME_API;

static AudioServerPlugInDriverInterface gDriverInterface = {
    ._reserved                        = NULL,
    .QueryInterface                   = EQT_QueryInterface,
    .AddRef                           = EQT_AddRef,
    .Release                          = EQT_Release,
    .Initialize                       = EQT_Initialize,
    .CreateDevice                     = EQT_CreateDevice,
    .DestroyDevice                    = EQT_DestroyDevice,
    .AddDeviceClient                  = EQT_AddDeviceClient,
    .RemoveDeviceClient               = EQT_RemoveDeviceClient,
    .PerformDeviceConfigurationChange = EQT_PerformDeviceConfigurationChange,
    .AbortDeviceConfigurationChange   = EQT_AbortDeviceConfigurationChange,
    .HasProperty                      = EQT_HasProperty,
    .IsPropertySettable               = EQT_IsPropertySettable,
    .GetPropertyDataSize              = EQT_GetPropertyDataSize,
    .GetPropertyData                  = EQT_GetPropertyData,
    .SetPropertyData                  = EQT_SetPropertyData,
    .StartIO                          = EQT_StartIO,
    .StopIO                           = EQT_StopIO,
    .GetZeroTimeStamp                 = EQT_GetZeroTimeStamp,
    .WillDoIOOperation                = EQT_WillDoIOOperation,
    .BeginIOOperation                 = EQT_BeginIOOperation,
    .DoIOOperation                    = EQT_DoIOOperation,
    .EndIOOperation                   = EQT_EndIOOperation
};
static AudioServerPlugInDriverInterface *gDriverInterfacePtr = &gDriverInterface;
static AudioServerPlugInDriverRef        gDriverRef          = &gDriverInterfacePtr;

// ================================================================ small helpers

static Boolean EQT_IsSupportedRate(Float64 rate) {
    for (UInt32 i = 0; i < kEQTSampleRateCount; i++) {
        if (kEQTSampleRates[i] == rate) return true;
    }
    return false;
}

static double EQT_Clamp(double v, double lo, double hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

static double EQT_VolumeScalarToDecibels(double scalar) {
    const double s = EQT_Clamp(scalar, 0.0, 1.0);
    const double a = kEQTVolumeFloor + (1.0 - kEQTVolumeFloor) * s;
    return EQT_Clamp(60.0 * log10(a), kEQTVolumeMinDB, kEQTVolumeMaxDB);
}

static double EQT_VolumeDecibelsToScalar(double dB) {
    const double g = EQT_Clamp(dB, kEQTVolumeMinDB, kEQTVolumeMaxDB);
    const double a = pow(10.0, g / 60.0);
    return EQT_Clamp((a - kEQTVolumeFloor) / (1.0 - kEQTVolumeFloor), 0.0, 1.0);
}

/// The one stream format the device speaks: the ring's layout (float32,
/// interleaved, EQT_RING_CHANNELS channels) at `rate`.
static AudioStreamBasicDescription EQT_StreamFormat(Float64 rate) {
    AudioStreamBasicDescription f;
    memset(&f, 0, sizeof f);
    f.mSampleRate       = rate;
    f.mFormatID         = kAudioFormatLinearPCM;
    f.mFormatFlags      = kAudioFormatFlagsNativeFloatPacked;
    f.mBytesPerPacket   = EQT_RING_CHANNELS * (UInt32)sizeof(Float32);
    f.mFramesPerPacket  = 1;
    f.mBytesPerFrame    = EQT_RING_CHANNELS * (UInt32)sizeof(Float32);
    f.mChannelsPerFrame = EQT_RING_CHANNELS;
    f.mBitsPerChannel   = 32;
    return f;
}

static Boolean EQT_ScopeIsInputSide(AudioObjectPropertyScope scope) {
    return scope == kAudioObjectPropertyScopeInput || scope == kAudioObjectPropertyScopePlayThrough;
}

/// Re-anchors the device clock at `now` for `rate`. Caller holds gStateMutex
/// and IO is stopped (first StartIO, or PerformDeviceConfigurationChange).
static void EQT_ClockResetLocked(Float64 rate, uint64_t now) {
    const double ticksPerFrame = gHostTicksPerSecond / rate;
    uint64_t bits;
    memcpy(&bits, &ticksPerFrame, sizeof bits);
    __atomic_store_n(&gClockTicksPerFrameBits, bits, __ATOMIC_RELAXED);
    __atomic_store_n(&gClockAnchorHostTime, now, __ATOMIC_RELAXED);
    __atomic_store_n(&gClockPeriodCount, (uint64_t)0, __ATOMIC_RELAXED);
    __atomic_add_fetch(&gClockSeed, 1, __ATOMIC_RELEASE);
}

// ---------------------------------------------------------------- notifications

static void EQT_Notify(AudioObjectID objectID, UInt32 count, const AudioObjectPropertyAddress *addresses) {
    AudioServerPlugInHostRef host = gHost;
    if (host != NULL && host->PropertiesChanged != NULL) {
        host->PropertiesChanged(host, objectID, count, addresses);
    }
}

/// Runs on a GCD thread after PerformDeviceConfigurationChange applied a new
/// rate. Dispatched rather than called inline so we never re-enter the host
/// from inside its own configuration-change machinery.
static void EQT_NotifyRateChangedWork(void *context) {
    (void)context;
    const AudioObjectPropertyAddress deviceAddr[] = {
        { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
    };
    const AudioObjectPropertyAddress streamAddr[] = {
        { kAudioStreamPropertyVirtualFormat,  kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
        { kAudioStreamPropertyPhysicalFormat, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
    };
    EQT_Notify(kEQTObjectDevice, 1, deviceAddr);
    EQT_Notify(kEQTObjectStreamOutput, 2, streamAddr);
}

static void EQT_RequestRateChangeWork(void *context) {
    const UInt64 rate = (UInt64)(uintptr_t)context;
    AudioServerPlugInHostRef host = gHost;
    if (host == NULL || host->RequestDeviceConfigurationChange == NULL) return;
    const OSStatus err = host->RequestDeviceConfigurationChange(host, kEQTObjectDevice, rate, NULL);
    if (err != kAudioHardwareNoError) {
        os_log_error(EQTLog(), "RequestDeviceConfigurationChange(%llu Hz) failed: %d", (unsigned long long)rate, (int)err);
        // Nothing is pending for this rate any more: forget it (if it is still
        // the latest), or setting the same rate again would be dropped.
        pthread_mutex_lock(&gStateMutex);
        if (gRequestedRate == (Float64)rate) gRequestedRate = gSampleRate;
        pthread_mutex_unlock(&gStateMutex);
    }
}

/// A rate change affects IO, so it must go through the host's
/// Request/PerformDeviceConfigurationChange handshake. Like Apple's NullAudio
/// we dispatch the request: the host may stop IO and call back into
/// PerformDeviceConfigurationChange before returning, and the client that set
/// the property must not be blocked on that. The new rate is the change action.
static void EQT_RequestRateChange(Float64 rate) {
    dispatch_async_f(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
                     (void *)(uintptr_t)(UInt64)rate, EQT_RequestRateChangeWork);
}

// ---------------------------------------------------------------- latency ('eqtl')
//
// A latency change goes through the same Request/Perform handshake as a rate
// change: that is the change the HAL announces to running clients. The change
// action is kEQTLatencyActionTag | frames — far above any sample rate, so the
// two kinds can never be confused. Like rates, the latest request wins.

#define kEQTLatencyActionTag (1ull << 32)

static Boolean EQT_IsLatencyAction(UInt64 action) { return (action >> 32) == 1u; }

static void EQT_NotifyLatencyChangedWork(void *context) {
    (void)context;
    const AudioObjectPropertyAddress addrs[] = {
        { kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain },
        { EQT_PROPERTY_CLIENT_LATENCY, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
    };
    EQT_Notify(kEQTObjectDevice, 2, addrs);
}

/// Applies the latest requested latency. Returns true if it changed.
static Boolean EQT_ApplyRequestedLatency(void) {
    pthread_mutex_lock(&gStateMutex);
    const Boolean changed = gRequestedLatency != gClientLatency;
    gClientLatency = gRequestedLatency;
    pthread_mutex_unlock(&gStateMutex);
    return changed;
}

static void EQT_RequestLatencyChangeWork(void *context) {
    const UInt64 action = kEQTLatencyActionTag | (UInt64)(uintptr_t)context;
    AudioServerPlugInHostRef host = gHost;
    const OSStatus err = (host != NULL && host->RequestDeviceConfigurationChange != NULL)
        ? host->RequestDeviceConfigurationChange(host, kEQTObjectDevice, action, NULL)
        : kAudioHardwareUnspecifiedError;
    if (err != kAudioHardwareNoError) {
        // No handshake: apply it directly, as before. New players still read
        // the right value; only running ones may miss the change.
        os_log_error(EQTLog(), "RequestDeviceConfigurationChange(latency %u) failed: %d; applied directly",
                     (unsigned)(UInt32)action, (int)err);
        if (EQT_ApplyRequestedLatency()) EQT_NotifyLatencyChangedWork(NULL);
    }
}

static void EQT_RequestLatencyChange(UInt32 frames) {
    dispatch_async_f(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
                     (void *)(uintptr_t)frames, EQT_RequestLatencyChangeWork);
}

// ---------------------------------------------------------------- ring readers ('eqta')

/// Caller holds gStateMutex.
static Boolean EQT_DeviceVisibleLocked(void) {
    return !gVisibilityManaged || gReaderCount > 0;
}

static void EQT_NotifyReaders(Boolean visibilityChanged) {
    const AudioObjectPropertyAddress addrs[] = {
        { EQT_PROPERTY_READER_ATTACHED, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
        { kAudioDevicePropertyIsHidden, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
        { kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain },
        { kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
    };
    EQT_Notify(kEQTObjectDevice, visibilityChanged ? 4u : 1u, addrs);
}

/// Caller holds gStateMutex. Index of `pid` in the reader table, or -1.
static int EQT_ReaderSlotLocked(pid_t pid) {
    for (UInt32 i = 0; i < gReaderCount; i++) {
        if (gReaderPIDs[i] == pid) return (int)i;
    }
    return -1;
}

static OSStatus EQT_SetReaderAttached(pid_t pid, Boolean attach);

/// A reader process exited (crash, kill -9, normal quit): it reads nothing
/// any more, whatever it last said.
static void EQT_ReaderExited(void *context) {
    (void)EQT_SetReaderAttached((pid_t)(intptr_t)context, false);
}

/// 'eqta' SET. Not for the IO thread (locks, allocates, makes host calls).
/// Every call marks visibility as managed; attaching is idempotent per pid.
static OSStatus EQT_SetReaderAttached(pid_t pid, Boolean attach) {
    dispatch_source_t watch = NULL;
    if (attach && pid > 0) {
        pthread_mutex_lock(&gStateMutex);
        const Boolean needWatch = EQT_ReaderSlotLocked(pid) < 0 && gReaderCount < kEQTMaxReaders;
        pthread_mutex_unlock(&gStateMutex);
        if (needWatch) {
            // Best effort: if the host's sandbox refuses the process watch the
            // reader is still attached, it just isn't dropped on a crash.
            watch = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, (uintptr_t)pid, DISPATCH_PROC_EXIT,
                                           dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
            if (watch != NULL) {
                dispatch_set_context(watch, (void *)(intptr_t)pid);
                dispatch_source_set_event_handler_f(watch, EQT_ReaderExited);
            }
        }
    }

    OSStatus result = kAudioHardwareNoError;
    dispatch_source_t retired = NULL;
    Boolean armed = false;
    pthread_mutex_lock(&gStateMutex);
    const Boolean wasVisible = EQT_DeviceVisibleLocked();
    const UInt32 countBefore = gReaderCount;
    gVisibilityManaged = true;
    const int slot = EQT_ReaderSlotLocked(pid);
    if (attach) {
        if (slot < 0) {
            if (gReaderCount < kEQTMaxReaders) {
                gReaderPIDs[gReaderCount] = pid;
                gReaderWatches[gReaderCount] = watch;
                gReaderCount++;
                if (watch != NULL) { dispatch_resume(watch); armed = true; }
                watch = NULL;   // owned by the table now
            } else {
                result = kAudioHardwareIllegalOperationError;
            }
        }
    } else if (slot >= 0) {
        retired = gReaderWatches[slot];
        gReaderCount--;
        gReaderPIDs[slot] = gReaderPIDs[gReaderCount];
        gReaderWatches[slot] = gReaderWatches[gReaderCount];
        gReaderWatches[gReaderCount] = NULL;
    }
    const Boolean visibilityChanged = wasVisible != EQT_DeviceVisibleLocked();
    const Boolean countChanged = gReaderCount != countBefore;
    pthread_mutex_unlock(&gStateMutex);

    if (watch != NULL) {   // created but not needed after all (raced with another attach, or table full)
        dispatch_source_cancel(watch);
        dispatch_resume(watch);   // a suspended source must not be released
        dispatch_release(watch);
    }
    if (retired != NULL) {
        dispatch_source_cancel(retired);
        dispatch_release(retired);
    }
    if (countChanged || visibilityChanged) EQT_NotifyReaders(visibilityChanged);
    // The process may have exited before the watch was armed.
    if (armed && kill(pid, 0) != 0 && errno == ESRCH) (void)EQT_SetReaderAttached(pid, false);
    return result;
}

// ---------------------------------------------------------------- persistence

static void EQT_LoadPersistedState(AudioServerPlugInHostRef host, Float32 *ioVolume, UInt32 *ioMute) {
    if (host->CopyFromStorage == NULL) return;
    CFPropertyListRef value = NULL;
    if (host->CopyFromStorage(host, kEQTStorageKeyVolume, &value) == kAudioHardwareNoError && value != NULL) {
        Float64 v = 0.0;
        if (CFGetTypeID(value) == CFNumberGetTypeID()
            && CFNumberGetValue((CFNumberRef)value, kCFNumberFloat64Type, &v) && isfinite(v)) {
            *ioVolume = (Float32)EQT_Clamp(v, 0.0, 1.0);
        }
        CFRelease(value);
    }
    value = NULL;
    if (host->CopyFromStorage(host, kEQTStorageKeyMute, &value) == kAudioHardwareNoError && value != NULL) {
        if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
            *ioMute = CFBooleanGetValue((CFBooleanRef)value) ? 1u : 0u;
        }
        CFRelease(value);
    }
}

static void EQT_PersistWork(void *context) {
    (void)context;
    pthread_mutex_lock(&gStateMutex);
    const Float32 volume = gVolumeScalar;
    const UInt32 mute = gMute;
    gPersistPending = false;
    AudioServerPlugInHostRef host = gHost;
    pthread_mutex_unlock(&gStateMutex);

    if (host == NULL || host->WriteToStorage == NULL) return;
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberFloat32Type, &volume);
    if (number != NULL) {
        host->WriteToStorage(host, kEQTStorageKeyVolume, number);
        CFRelease(number);
    }
    host->WriteToStorage(host, kEQTStorageKeyMute, mute ? kCFBooleanTrue : kCFBooleanFalse);
}

static void EQT_SchedulePersist(void) {
    pthread_mutex_lock(&gStateMutex);
    const Boolean schedule = !gPersistPending;
    gPersistPending = true;
    pthread_mutex_unlock(&gStateMutex);
    if (schedule) {
        dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)kEQTPersistDelayNs),
                         dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), NULL, EQT_PersistWork);
    }
}

// ================================================================ factory + IUnknown

void *EQTargets_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID) {
    (void)inAllocator;
    // The host asks for the AudioServerPlugIn type; we only ever vend the one
    // static driver object (the plug-in is a singleton by design).
    if (inRequestedTypeUUID != NULL && CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) {
        return gDriverRef;
    }
    return NULL;
}

static HRESULT EQT_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface) {
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (outInterface == NULL) return kAudioHardwareIllegalOperationError;

    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    if (requested == NULL) return E_OUTOFMEMORY;
    HRESULT result = E_NOINTERFACE;
    // AudioServerPlugInDriverInterface derives from IUnknown, so both UUIDs
    // resolve to the same object.
    if (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID)) {
        pthread_mutex_lock(&gStateMutex);
        ++gRefCount;
        pthread_mutex_unlock(&gStateMutex);
        *outInterface = gDriverRef;
        result = S_OK;
    } else {
        *outInterface = NULL;
    }
    CFRelease(requested);
    return result;
}

static ULONG EQT_AddRef(void *inDriver) {
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex);
    if (gRefCount < UINT32_MAX) ++gRefCount;
    const ULONG count = gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return count;
}

static ULONG EQT_Release(void *inDriver) {
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex);
    if (gRefCount > 0) --gRefCount;   // the object is static: nothing to free at zero
    const ULONG count = gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return count;
}

// ================================================================ basic operations

static OSStatus EQT_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inHost == NULL) return kAudioHardwareIllegalOperationError;

    // Host calls happen before taking the lock (see THREADING).
    Float32 volume = 1.0f;
    UInt32 mute = 0;
    EQT_LoadPersistedState(inHost, &volume, &mute);

    mach_timebase_info_data_t timebase = { 0, 0 };
    mach_timebase_info(&timebase);
    if (timebase.numer == 0 || timebase.denom == 0) { timebase.numer = 1; timebase.denom = 1; }

    // The test harness points the driver at a private ring so it can never
    // collide with a real installed driver. coreaudiod never sets this.
    const char *ringName = getenv("EQT_RING_NAME_OVERRIDE");
    if (ringName == NULL || ringName[0] == '\0') ringName = EQT_RING_SHM_NAME;

    pthread_mutex_lock(&gStateMutex);
    if (gHost != NULL) {
        pthread_mutex_unlock(&gStateMutex);
        return kAudioHardwareIllegalOperationError;   // Initialize is called exactly once
    }
    gHost = inHost;
    gHostTicksPerSecond = 1.0e9 * (double)timebase.denom / (double)timebase.numer;
    gVolumeScalar = volume;
    gMute = mute;
    const uint64_t now = mach_absolute_time();
    EQT_ClockResetLocked(gSampleRate, now);
    gRing = EQTDriverRingOpen(ringName, gSampleRate, now);
    const Boolean ringOK = gRing != NULL;
    pthread_mutex_unlock(&gStateMutex);

    if (!ringOK) {
        // Keep publishing the device: apps can still play to it (silently) and
        // the app can report "driver loaded, ring unavailable" instead of
        // "driver missing". WriteMix is a no-op without a ring.
        os_log_error(EQTLog(), "EQtargets Audio: shared-memory ring unavailable; device published without audio export");
    }
    return kAudioHardwareNoError;
}

static OSStatus EQT_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription,
                                 const AudioServerPlugInClientInfo *inClientInfo, AudioObjectID *outDeviceObjectID) {
    (void)inDescription; (void)inClientInfo; (void)outDeviceObjectID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    return kAudioHardwareUnsupportedOperationError;   // one fixed device, no transport manager
}

static OSStatus EQT_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID) {
    (void)inDeviceObjectID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus EQT_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                    const AudioServerPlugInClientInfo *inClientInfo) {
    if (inDriver != gDriverRef || inDeviceObjectID != kEQTObjectDevice) return kAudioHardwareBadObjectError;
    if (inClientInfo == NULL) return kAudioHardwareIllegalOperationError;
    return kAudioHardwareNoError;   // no per-client state
}

static OSStatus EQT_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                       const AudioServerPlugInClientInfo *inClientInfo) {
    if (inDriver != gDriverRef || inDeviceObjectID != kEQTObjectDevice) return kAudioHardwareBadObjectError;
    if (inClientInfo == NULL) return kAudioHardwareIllegalOperationError;
    return kAudioHardwareNoError;
}

static OSStatus EQT_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                                     UInt64 inChangeAction, void *inChangeInfo) {
    (void)inChangeInfo;
    if (inDriver != gDriverRef || inDeviceObjectID != kEQTObjectDevice) return kAudioHardwareBadObjectError;
    if (EQT_IsLatencyAction(inChangeAction)) {
        // Latest request wins (a stale or duplicate Perform is a no-op). No
        // clock re-anchor and no new timeline: the ring is not affected.
        if (EQT_ApplyRequestedLatency()) {
            dispatch_async_f(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), NULL, EQT_NotifyLatencyChangedWork);
        }
        return kAudioHardwareNoError;
    }
    // Otherwise it is a sample-rate change; the action is the rate.
    if (!EQT_IsSupportedRate((Float64)inChangeAction)) return kAudioHardwareIllegalOperationError;

    pthread_mutex_lock(&gStateMutex);
    // Latest request wins. Requests are dispatched (and the host may defer
    // Perform), so they can arrive stale or out of order: 44.1 then 48 kHz set
    // back to back must end at 48 kHz. A Perform that would not change the rate
    // (stale, or a duplicate) is a no-op: no clock re-anchor, no new timeline.
    const Float64 rate = gRequestedRate;
    if (rate == gSampleRate) {
        pthread_mutex_unlock(&gStateMutex);
        return kAudioHardwareNoError;
    }
    gSampleRate = rate;
    // The host has stopped IO for the change, so re-anchoring cannot race the IO thread.
    EQT_ClockResetLocked(rate, mach_absolute_time());
    if (gRing != NULL) {
        // Rate FIRST (release), then the generation bump: a reader that sees
        // the new generation is guaranteed to read the new rate.
        EQTRingStoreSampleRate(gRing, rate);
        EQTDriverRingRestartTimeline(gRing);
    }
    pthread_mutex_unlock(&gStateMutex);

    dispatch_async_f(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), NULL, EQT_NotifyRateChangedWork);
    return kAudioHardwareNoError;
}

static OSStatus EQT_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                                   UInt64 inChangeAction, void *inChangeInfo) {
    (void)inChangeInfo;
    if (inDriver != gDriverRef || inDeviceObjectID != kEQTObjectDevice) return kAudioHardwareBadObjectError;
    // The host dropped this request. If it was the latest one, nothing is
    // pending any more: forget it, so setting that value again asks again.
    pthread_mutex_lock(&gStateMutex);
    if (EQT_IsLatencyAction(inChangeAction)) {
        if ((UInt32)inChangeAction == gRequestedLatency) gRequestedLatency = gClientLatency;
    } else if ((Float64)inChangeAction == gRequestedRate) {
        gRequestedRate = gSampleRate;
    }
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareNoError;
}

// ================================================================ property engine
//
// One getter per object serves GetPropertyData, GetPropertyDataSize AND
// HasProperty (HasProperty == "the size query succeeds"), so the three can
// never disagree. In a size query `out` is NULL and `size` receives the full
// size; in a get, `capacity` is the caller's buffer size and `size` receives
// the bytes written.

typedef struct {
    void   *out;        // NULL → size query
    UInt32  capacity;   // caller's buffer size (get only)
    UInt32  size;       // bytes written (get) / required (size query)
} EQTReply;

static OSStatus EQT_ReplyBytes(EQTReply *r, const void *value, UInt32 size) {
    r->size = size;
    if (r->out == NULL) return kAudioHardwareNoError;
    if (r->capacity < size) return kAudioHardwareBadPropertySizeError;
    memcpy(r->out, value, size);
    return kAudioHardwareNoError;
}

static OSStatus EQT_ReplyU32(EQTReply *r, UInt32 v)       { return EQT_ReplyBytes(r, &v, sizeof v); }
static OSStatus EQT_ReplyF32(EQTReply *r, Float32 v)      { return EQT_ReplyBytes(r, &v, sizeof v); }
static OSStatus EQT_ReplyF64(EQTReply *r, Float64 v)      { return EQT_ReplyBytes(r, &v, sizeof v); }
static OSStatus EQT_ReplyObject(EQTReply *r, AudioObjectID v) { return EQT_ReplyBytes(r, &v, sizeof v); }
/// CFSTR constants are immortal, so handing one out "retained" is correct:
/// the caller's CFRelease is a no-op on them.
static OSStatus EQT_ReplyString(EQTReply *r, CFStringRef v)  { return EQT_ReplyBytes(r, &v, sizeof v); }

/// Arrays may be fetched partially: the HAL is allowed to ask for fewer items
/// than exist, and gets as many whole items as fit.
static OSStatus EQT_ReplyArray(EQTReply *r, const void *items, UInt32 count, UInt32 itemSize) {
    if (r->out == NULL) { r->size = count * itemSize; return kAudioHardwareNoError; }
    UInt32 n = r->capacity / itemSize;
    if (n > count) n = count;
    if (n > 0) memcpy(r->out, items, (size_t)n * itemSize);
    r->size = n * itemSize;
    return kAudioHardwareNoError;
}

static Boolean EQT_ObjectIsKindOf(AudioObjectID objectID, AudioClassID classID) {
    if (classID == kAudioObjectClassID) return true;
    switch (objectID) {
        case kEQTObjectPlugIn:       return classID == kAudioPlugInClassID;
        case kEQTObjectBox:          return classID == kAudioBoxClassID;
        case kEQTObjectDevice:       return classID == kAudioDeviceClassID;
        case kEQTObjectStreamOutput: return classID == kAudioStreamClassID;
        case kEQTObjectVolumeOutput: return classID == kAudioVolumeControlClassID || classID == kAudioLevelControlClassID
                                         || classID == kAudioControlClassID;
        case kEQTObjectMuteOutput:   return classID == kAudioMuteControlClassID || classID == kAudioBooleanControlClassID
                                         || classID == kAudioControlClassID;
        default:                     return false;
    }
}

/// kAudioObjectPropertyOwnedObjects: the qualifier, when present, is an array
/// of AudioClassIDs and limits the answer to objects of (or derived from) them.
static OSStatus EQT_ReplyOwnedObjects(EQTReply *r, const AudioObjectID *ids, UInt32 count,
                                      UInt32 qualifierSize, const void *qualifier) {
    AudioObjectID matched[8];
    UInt32 matchedCount = 0;
    const UInt32 classCount = qualifier != NULL ? qualifierSize / (UInt32)sizeof(AudioClassID) : 0;
    for (UInt32 i = 0; i < count && matchedCount < 8; i++) {
        Boolean keep = classCount == 0;
        for (UInt32 c = 0; c < classCount && !keep; c++) {
            AudioClassID cls;
            memcpy(&cls, (const uint8_t *)qualifier + c * sizeof(AudioClassID), sizeof cls);
            keep = EQT_ObjectIsKindOf(ids[i], cls);
        }
        if (keep) matched[matchedCount++] = ids[i];
    }
    return EQT_ReplyArray(r, matched, matchedCount, sizeof(AudioObjectID));
}

/// kAudioPlugInPropertyTranslateUIDTo*: the qualifier is a CFStringRef UID.
static OSStatus EQT_ReplyTranslateUID(EQTReply *r, UInt32 qualifierSize, const void *qualifier,
                                      CFStringRef knownUID, AudioObjectID knownObject) {
    if (r->out == NULL) { r->size = sizeof(AudioObjectID); return kAudioHardwareNoError; }
    if (qualifier == NULL || qualifierSize != sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
    CFStringRef uid = NULL;
    memcpy(&uid, qualifier, sizeof uid);
    AudioObjectID answer = kAudioObjectUnknown;
    if (uid != NULL && CFGetTypeID(uid) == CFStringGetTypeID()
        && CFStringCompare(uid, knownUID, 0) == kCFCompareEqualTo) {
        answer = knownObject;
    }
    return EQT_ReplyObject(r, answer);
}

// ---------------------------------------------------------------- plug-in

static OSStatus EQT_GetPlugInProperty(const AudioObjectPropertyAddress *a, UInt32 qs, const void *q, EQTReply *r) {
    static const AudioObjectID kOwned[] = { kEQTObjectBox, kEQTObjectDevice };
    static const AudioObjectID kBox[] = { kEQTObjectBox };
    static const AudioObjectID kDevice[] = { kEQTObjectDevice };
    switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass:            return EQT_ReplyU32(r, kAudioObjectClassID);
        case kAudioObjectPropertyClass:                return EQT_ReplyU32(r, kAudioPlugInClassID);
        case kAudioObjectPropertyOwner:                return EQT_ReplyObject(r, kAudioObjectUnknown);
        case kAudioObjectPropertyManufacturer:         return EQT_ReplyString(r, CFSTR(EQT_DEVICE_MANUFACTURER));
        case kAudioObjectPropertyOwnedObjects:         return EQT_ReplyOwnedObjects(r, kOwned, 2, qs, q);
        case kAudioPlugInPropertyBoxList:              return EQT_ReplyArray(r, kBox, 1, sizeof(AudioObjectID));
        case kAudioPlugInPropertyTranslateUIDToBox:    return EQT_ReplyTranslateUID(r, qs, q, CFSTR(EQT_BOX_UID), kEQTObjectBox);
        case kAudioPlugInPropertyDeviceList:           return EQT_ReplyArray(r, kDevice, 1, sizeof(AudioObjectID));
        case kAudioPlugInPropertyTranslateUIDToDevice: return EQT_ReplyTranslateUID(r, qs, q, CFSTR(EQT_DEVICE_UID), kEQTObjectDevice);
        case kAudioPlugInPropertyResourceBundle:       return EQT_ReplyString(r, CFSTR(""));   // our own bundle
        default:                                       return kAudioHardwareUnknownPropertyError;
    }
}

// ---------------------------------------------------------------- box

static OSStatus EQT_GetBoxProperty(const AudioObjectPropertyAddress *a, EQTReply *r) {
    static const AudioObjectID kDevice[] = { kEQTObjectDevice };
    switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass:       return EQT_ReplyU32(r, kAudioObjectClassID);
        case kAudioObjectPropertyClass:           return EQT_ReplyU32(r, kAudioBoxClassID);
        case kAudioObjectPropertyOwner:           return EQT_ReplyObject(r, kEQTObjectPlugIn);
        case kAudioObjectPropertyOwnedObjects:    return EQT_ReplyArray(r, NULL, 0, sizeof(AudioObjectID));
        case kAudioObjectPropertyName:            return EQT_ReplyString(r, CFSTR(EQT_DEVICE_NAME));
        case kAudioObjectPropertyModelName:       return EQT_ReplyString(r, CFSTR(EQT_DEVICE_NAME));
        case kAudioObjectPropertyManufacturer:    return EQT_ReplyString(r, CFSTR(EQT_DEVICE_MANUFACTURER));
        case kAudioBoxPropertyBoxUID:             return EQT_ReplyString(r, CFSTR(EQT_BOX_UID));
        case kAudioBoxPropertyTransportType:      return EQT_ReplyU32(r, kAudioDeviceTransportTypeVirtual);
        case kAudioBoxPropertyHasAudio:           return EQT_ReplyU32(r, 1);
        case kAudioBoxPropertyHasVideo:           return EQT_ReplyU32(r, 0);
        case kAudioBoxPropertyHasMIDI:            return EQT_ReplyU32(r, 0);
        case kAudioBoxPropertyIsProtected:        return EQT_ReplyU32(r, 0);
        // Always acquired: unlike NullAudio's demo box, ours can't be switched
        // off from Audio MIDI Setup (that would silently remove the device).
        case kAudioBoxPropertyAcquired:           return EQT_ReplyU32(r, 1);
        case kAudioBoxPropertyAcquisitionFailed:  return EQT_ReplyU32(r, (UInt32)kAudioHardwareNoError);
        case kAudioBoxPropertyDeviceList:         return EQT_ReplyArray(r, kDevice, 1, sizeof(AudioObjectID));
        default:                                  return kAudioHardwareUnknownPropertyError;
    }
}

// ---------------------------------------------------------------- device

static OSStatus EQT_GetDeviceProperty(const AudioObjectPropertyAddress *a, UInt32 qs, const void *q, EQTReply *r) {
    static const AudioObjectID kOwned[] = { kEQTObjectStreamOutput, kEQTObjectVolumeOutput, kEQTObjectMuteOutput };
    static const AudioObjectID kStreams[] = { kEQTObjectStreamOutput };
    static const AudioObjectID kControls[] = { kEQTObjectVolumeOutput, kEQTObjectMuteOutput };
    static const AudioObjectID kRelated[] = { kEQTObjectDevice };
    const Boolean inputSide = EQT_ScopeIsInputSide(a->mScope);

    switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass:    return EQT_ReplyU32(r, kAudioObjectClassID);
        case kAudioObjectPropertyClass:        return EQT_ReplyU32(r, kAudioDeviceClassID);
        case kAudioObjectPropertyOwner:        return EQT_ReplyObject(r, kEQTObjectPlugIn);
        case kAudioObjectPropertyName:         return EQT_ReplyString(r, CFSTR(EQT_DEVICE_NAME));
        case kAudioObjectPropertyManufacturer: return EQT_ReplyString(r, CFSTR(EQT_DEVICE_MANUFACTURER));

        // Input side owns nothing: no stream, no control. (THE invariant.)
        case kAudioObjectPropertyOwnedObjects:
            return inputSide ? EQT_ReplyArray(r, NULL, 0, sizeof(AudioObjectID))
                             : EQT_ReplyOwnedObjects(r, kOwned, 3, qs, q);
        case kAudioDevicePropertyStreams:
            return inputSide ? EQT_ReplyArray(r, NULL, 0, sizeof(AudioObjectID))
                             : EQT_ReplyArray(r, kStreams, 1, sizeof(AudioObjectID));
        case kAudioObjectPropertyControlList:  return EQT_ReplyArray(r, kControls, 2, sizeof(AudioObjectID));

        case kAudioObjectPropertyCustomPropertyInfoList: {
            const AudioServerPlugInCustomPropertyInfo info[] = {
                { EQT_PROPERTY_CLIENT_LATENCY, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList,
                  kAudioServerPlugInCustomPropertyDataTypeNone },
                { EQT_PROPERTY_READER_ATTACHED, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList,
                  kAudioServerPlugInCustomPropertyDataTypeNone },
            };
            return EQT_ReplyArray(r, info, 2, sizeof(AudioServerPlugInCustomPropertyInfo));
        }
        case EQT_PROPERTY_READER_ATTACHED: {
            // +1 CFNumber: how many processes are attached as ring readers.
            r->size = sizeof(CFPropertyListRef);
            if (r->out == NULL) return kAudioHardwareNoError;
            if (r->capacity < sizeof(CFPropertyListRef)) return kAudioHardwareBadPropertySizeError;
            pthread_mutex_lock(&gStateMutex);
            const SInt32 readers = (SInt32)gReaderCount;
            pthread_mutex_unlock(&gStateMutex);
            CFNumberRef number = CFNumberCreate(NULL, kCFNumberSInt32Type, &readers);
            if (number == NULL) return kAudioHardwareUnspecifiedError;
            CFPropertyListRef plist = number;
            memcpy(r->out, &plist, sizeof plist);
            return kAudioHardwareNoError;
        }
        case EQT_PROPERTY_CLIENT_LATENCY: {
            // CFPropertyList-typed custom property: we hand out a +1 CFNumber
            // (frames) that the caller releases.
            r->size = sizeof(CFPropertyListRef);
            if (r->out == NULL) return kAudioHardwareNoError;
            if (r->capacity < sizeof(CFPropertyListRef)) return kAudioHardwareBadPropertySizeError;
            pthread_mutex_lock(&gStateMutex);
            const SInt32 frames = (SInt32)gRequestedLatency;   // what was asked for (applied once performed)
            pthread_mutex_unlock(&gStateMutex);
            CFNumberRef number = CFNumberCreate(NULL, kCFNumberSInt32Type, &frames);
            if (number == NULL) return kAudioHardwareUnspecifiedError;
            CFPropertyListRef plist = number;
            memcpy(r->out, &plist, sizeof plist);
            return kAudioHardwareNoError;
        }

        case kAudioDevicePropertyDeviceUID:     return EQT_ReplyString(r, CFSTR(EQT_DEVICE_UID));
        case kAudioDevicePropertyModelUID:      return EQT_ReplyString(r, CFSTR(EQT_DEVICE_MODEL_UID));
        case kAudioDevicePropertyTransportType: return EQT_ReplyU32(r, kAudioDeviceTransportTypeVirtual);
        case kAudioDevicePropertyRelatedDevices:return EQT_ReplyArray(r, kRelated, 1, sizeof(AudioObjectID));
        // 0 = "unspecified": never treated as sharing a clock with anything.
        case kAudioDevicePropertyClockDomain:   return EQT_ReplyU32(r, 0);
        case kAudioDevicePropertyDeviceIsAlive: return EQT_ReplyU32(r, 1);
        case kAudioDevicePropertyDeviceIsRunning: {
            pthread_mutex_lock(&gStateMutex);
            const UInt32 running = gIOClientCount > 0 ? 1u : 0u;
            pthread_mutex_unlock(&gStateMutex);
            return EQT_ReplyU32(r, running);
        }
        // Default OUTPUT yes (while visible, see 'eqta'); default input never;
        // system (alert) output no — alerts stay on the real device and never
        // go through the EQ.
        case kAudioDevicePropertyDeviceCanBeDefaultDevice: {
            if (inputSide) return EQT_ReplyU32(r, 0u);
            pthread_mutex_lock(&gStateMutex);
            const Boolean visible = EQT_DeviceVisibleLocked();
            pthread_mutex_unlock(&gStateMutex);
            return EQT_ReplyU32(r, visible ? 1u : 0u);
        }
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: return EQT_ReplyU32(r, 0);
        case kAudioDevicePropertyLatency: {
            if (inputSide) return EQT_ReplyU32(r, 0);
            pthread_mutex_lock(&gStateMutex);
            const UInt32 latency = gClientLatency;   // device latency itself is 0
            pthread_mutex_unlock(&gStateMutex);
            return EQT_ReplyU32(r, latency);
        }
        case kAudioDevicePropertySafetyOffset:  return EQT_ReplyU32(r, 0);
        case kAudioDevicePropertyNominalSampleRate: {
            pthread_mutex_lock(&gStateMutex);
            const Float64 rate = gSampleRate;
            pthread_mutex_unlock(&gStateMutex);
            return EQT_ReplyF64(r, rate);
        }
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            AudioValueRange ranges[kEQTSampleRateCount];
            for (UInt32 i = 0; i < kEQTSampleRateCount; i++) {
                ranges[i].mMinimum = kEQTSampleRates[i];
                ranges[i].mMaximum = kEQTSampleRates[i];
            }
            return EQT_ReplyArray(r, ranges, kEQTSampleRateCount, sizeof(AudioValueRange));
        }
        // Hidden while EQtargets manages visibility and no reader is attached:
        // nothing would play what reaches the device, so it must not be
        // pickable in the Sound menu nor a fallback default ('eqta').
        case kAudioDevicePropertyIsHidden: {
            pthread_mutex_lock(&gStateMutex);
            const Boolean visible = EQT_DeviceVisibleLocked();
            pthread_mutex_unlock(&gStateMutex);
            return EQT_ReplyU32(r, visible ? 0u : 1u);
        }
        case kAudioDevicePropertyPreferredChannelsForStereo: {
            if (inputSide) return kAudioHardwareUnknownPropertyError;   // no input channels exist
            const UInt32 pair[2] = { 1, 2 };
            return EQT_ReplyBytes(r, pair, sizeof pair);
        }
        case kAudioDevicePropertyPreferredChannelLayout: {
            if (inputSide) return kAudioHardwareUnknownPropertyError;
            enum { kLayoutSize = offsetof(AudioChannelLayout, mChannelDescriptions) + 2 * sizeof(AudioChannelDescription) };
            UInt32 storage[(kLayoutSize + sizeof(UInt32) - 1) / sizeof(UInt32)];
            memset(storage, 0, sizeof storage);
            AudioChannelLayout *layout = (AudioChannelLayout *)(void *)storage;
            AudioChannelDescription *descriptions = layout->mChannelDescriptions;
            layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
            layout->mNumberChannelDescriptions = 2;
            descriptions[0].mChannelLabel = kAudioChannelLabel_Left;
            descriptions[1].mChannelLabel = kAudioChannelLabel_Right;
            return EQT_ReplyBytes(r, storage, kLayoutSize);
        }
        case kAudioDevicePropertyZeroTimeStampPeriod: return EQT_ReplyU32(r, EQT_ZERO_TIMESTAMP_PERIOD);
        default:                                      return kAudioHardwareUnknownPropertyError;
    }
}

// ---------------------------------------------------------------- stream

static OSStatus EQT_GetStreamProperty(const AudioObjectPropertyAddress *a, EQTReply *r) {
    switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass:     return EQT_ReplyU32(r, kAudioObjectClassID);
        case kAudioObjectPropertyClass:         return EQT_ReplyU32(r, kAudioStreamClassID);
        case kAudioObjectPropertyOwner:         return EQT_ReplyObject(r, kEQTObjectDevice);
        case kAudioObjectPropertyOwnedObjects:  return EQT_ReplyArray(r, NULL, 0, sizeof(AudioObjectID));
        case kAudioStreamPropertyIsActive: {
            pthread_mutex_lock(&gStateMutex);
            const UInt32 active = gStreamIsActive;
            pthread_mutex_unlock(&gStateMutex);
            return EQT_ReplyU32(r, active);
        }
        case kAudioStreamPropertyDirection:       return EQT_ReplyU32(r, 0);   // 0 = output
        case kAudioStreamPropertyTerminalType:    return EQT_ReplyU32(r, kAudioStreamTerminalTypeSpeaker);
        case kAudioStreamPropertyStartingChannel: return EQT_ReplyU32(r, 1);
        case kAudioStreamPropertyLatency:         return EQT_ReplyU32(r, 0);
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: {
            // Virtual == physical: the HAL hands WriteMix the mix in exactly
            // the ring's layout, so the copy is a straight memcpy.
            pthread_mutex_lock(&gStateMutex);
            const Float64 rate = gSampleRate;
            pthread_mutex_unlock(&gStateMutex);
            const AudioStreamBasicDescription f = EQT_StreamFormat(rate);
            return EQT_ReplyBytes(r, &f, sizeof f);
        }
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            AudioStreamRangedDescription formats[kEQTSampleRateCount];
            for (UInt32 i = 0; i < kEQTSampleRateCount; i++) {
                formats[i].mFormat = EQT_StreamFormat(kEQTSampleRates[i]);
                formats[i].mSampleRateRange.mMinimum = kEQTSampleRates[i];
                formats[i].mSampleRateRange.mMaximum = kEQTSampleRates[i];
            }
            return EQT_ReplyArray(r, formats, kEQTSampleRateCount, sizeof(AudioStreamRangedDescription));
        }
        default: return kAudioHardwareUnknownPropertyError;
    }
}

// ---------------------------------------------------------------- volume / mute

static OSStatus EQT_GetVolumeProperty(const AudioObjectPropertyAddress *a, EQTReply *r) {
    switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass:    return EQT_ReplyU32(r, kAudioLevelControlClassID);
        case kAudioObjectPropertyClass:        return EQT_ReplyU32(r, kAudioVolumeControlClassID);
        case kAudioObjectPropertyOwner:        return EQT_ReplyObject(r, kEQTObjectDevice);
        case kAudioObjectPropertyOwnedObjects: return EQT_ReplyArray(r, NULL, 0, sizeof(AudioObjectID));
        case kAudioControlPropertyScope:       return EQT_ReplyU32(r, kAudioObjectPropertyScopeOutput);
        case kAudioControlPropertyElement:     return EQT_ReplyU32(r, kAudioObjectPropertyElementMain);
        case kAudioLevelControlPropertyScalarValue:
        case kAudioLevelControlPropertyDecibelValue: {
            pthread_mutex_lock(&gStateMutex);
            const Float32 scalar = gVolumeScalar;
            pthread_mutex_unlock(&gStateMutex);
            return EQT_ReplyF32(r, a->mSelector == kAudioLevelControlPropertyScalarValue
                                       ? scalar : (Float32)EQT_VolumeScalarToDecibels(scalar));
        }
        case kAudioLevelControlPropertyDecibelRange: {
            const AudioValueRange range = { kEQTVolumeMinDB, kEQTVolumeMaxDB };
            return EQT_ReplyBytes(r, &range, sizeof range);
        }
        case kAudioLevelControlPropertyConvertScalarToDecibels:
        case kAudioLevelControlPropertyConvertDecibelsToScalar: {
            // In/out property: the value to convert arrives in the out buffer.
            r->size = sizeof(Float32);
            if (r->out == NULL) return kAudioHardwareNoError;
            if (r->capacity < sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
            Float32 v;
            memcpy(&v, r->out, sizeof v);
            // ±inf clamp like any out-of-range value (−inf dB = silence = scalar 0);
            // only NaN has no meaning (EQT_Clamp would pass it through).
            if (isnan(v)) return kAudioHardwareIllegalOperationError;
            const Float32 converted = a->mSelector == kAudioLevelControlPropertyConvertScalarToDecibels
                                          ? (Float32)EQT_VolumeScalarToDecibels(v)
                                          : (Float32)EQT_VolumeDecibelsToScalar(v);
            return EQT_ReplyF32(r, converted);
        }
        default: return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus EQT_GetMuteProperty(const AudioObjectPropertyAddress *a, EQTReply *r) {
    switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass:    return EQT_ReplyU32(r, kAudioBooleanControlClassID);
        case kAudioObjectPropertyClass:        return EQT_ReplyU32(r, kAudioMuteControlClassID);
        case kAudioObjectPropertyOwner:        return EQT_ReplyObject(r, kEQTObjectDevice);
        case kAudioObjectPropertyOwnedObjects: return EQT_ReplyArray(r, NULL, 0, sizeof(AudioObjectID));
        case kAudioControlPropertyScope:       return EQT_ReplyU32(r, kAudioObjectPropertyScopeOutput);
        case kAudioControlPropertyElement:     return EQT_ReplyU32(r, kAudioObjectPropertyElementMain);
        case kAudioBooleanControlPropertyValue: {
            pthread_mutex_lock(&gStateMutex);
            const UInt32 mute = gMute;
            pthread_mutex_unlock(&gStateMutex);
            return EQT_ReplyU32(r, mute);
        }
        default: return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus EQT_GetProperty(AudioObjectID objectID, const AudioObjectPropertyAddress *a,
                                UInt32 qualifierSize, const void *qualifier, EQTReply *r) {
    switch (objectID) {
        case kEQTObjectPlugIn:       return EQT_GetPlugInProperty(a, qualifierSize, qualifier, r);
        case kEQTObjectBox:          return EQT_GetBoxProperty(a, r);
        case kEQTObjectDevice:       return EQT_GetDeviceProperty(a, qualifierSize, qualifier, r);
        case kEQTObjectStreamOutput: return EQT_GetStreamProperty(a, r);
        case kEQTObjectVolumeOutput: return EQT_GetVolumeProperty(a, r);
        case kEQTObjectMuteOutput:   return EQT_GetMuteProperty(a, r);
        default:                     return kAudioHardwareBadObjectError;
    }
}

static Boolean EQT_PropertyIsSettable(AudioObjectID objectID, AudioObjectPropertySelector selector) {
    switch (objectID) {
        case kEQTObjectDevice:
            return selector == kAudioDevicePropertyNominalSampleRate || selector == EQT_PROPERTY_CLIENT_LATENCY
                || selector == EQT_PROPERTY_READER_ATTACHED;
        case kEQTObjectStreamOutput:
            return selector == kAudioStreamPropertyIsActive || selector == kAudioStreamPropertyVirtualFormat
                || selector == kAudioStreamPropertyPhysicalFormat;
        case kEQTObjectVolumeOutput:
            return selector == kAudioLevelControlPropertyScalarValue || selector == kAudioLevelControlPropertyDecibelValue;
        case kEQTObjectMuteOutput:
            return selector == kAudioBooleanControlPropertyValue;
        default:
            return false;
    }
}

// ---------------------------------------------------------------- setters

static OSStatus EQT_SetNominalRate(Float64 rate) {
    if (!EQT_IsSupportedRate(rate)) return kAudioHardwareIllegalOperationError;
    // Compare with the rate last ASKED FOR, not the applied one: while a change
    // is pending gSampleRate is stale, so a quick switch back to it would be
    // dropped, and setting the new rate twice (format, then nominal rate)
    // would queue two changes, i.e. two IO restarts.
    pthread_mutex_lock(&gStateMutex);
    const Boolean differs = rate != gRequestedRate;
    if (differs) gRequestedRate = rate;
    pthread_mutex_unlock(&gStateMutex);
    if (differs) EQT_RequestRateChange(rate);
    return kAudioHardwareNoError;
}

static OSStatus EQT_SetDeviceProperty(pid_t clientPID, const AudioObjectPropertyAddress *a, UInt32 inDataSize,
                                      const void *inData) {
    switch (a->mSelector) {
        case EQT_PROPERTY_READER_ATTACHED: {
            if (inDataSize != sizeof(CFPropertyListRef)) return kAudioHardwareBadPropertySizeError;
            CFPropertyListRef value = NULL;
            memcpy(&value, inData, sizeof value);   // borrowed: the caller owns it
            if (value == NULL || CFGetTypeID(value) != CFNumberGetTypeID()) return kAudioHardwareIllegalOperationError;
            Float64 v = 0.0;
            CFNumberGetValue((CFNumberRef)value, kCFNumberFloat64Type, &v);
            if (isnan(v)) return kAudioHardwareIllegalOperationError;
            return EQT_SetReaderAttached(clientPID, v != 0.0);
        }
        case kAudioDevicePropertyNominalSampleRate: {
            if (inDataSize != sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
            Float64 rate;
            memcpy(&rate, inData, sizeof rate);
            return EQT_SetNominalRate(rate);
        }
        case EQT_PROPERTY_CLIENT_LATENCY: {
            if (inDataSize != sizeof(CFPropertyListRef)) return kAudioHardwareBadPropertySizeError;
            CFPropertyListRef value = NULL;
            memcpy(&value, inData, sizeof value);   // borrowed: the caller owns it
            if (value == NULL || CFGetTypeID(value) != CFNumberGetTypeID()) return kAudioHardwareIllegalOperationError;
            Float64 requested = 0.0;
            CFNumberGetValue((CFNumberRef)value, kCFNumberFloat64Type, &requested);
            if (!isfinite(requested)) return kAudioHardwareIllegalOperationError;
            const UInt32 frames = (UInt32)EQT_Clamp(floor(requested + 0.5), 0.0, (double)EQT_MAX_CLIENT_LATENCY);

            // Compare with the latency last ASKED FOR (see EQT_SetNominalRate):
            // a quick change back while one is pending must still ask, and the
            // same value twice must not queue a second IO restart.
            pthread_mutex_lock(&gStateMutex);
            const Boolean differs = frames != gRequestedLatency;
            if (differs) gRequestedLatency = frames;
            pthread_mutex_unlock(&gStateMutex);
            if (differs) EQT_RequestLatencyChange(frames);
            return kAudioHardwareNoError;
        }
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus EQT_SetStreamProperty(const AudioObjectPropertyAddress *a, UInt32 inDataSize, const void *inData) {
    switch (a->mSelector) {
        case kAudioStreamPropertyIsActive: {
            if (inDataSize != sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            UInt32 v;
            memcpy(&v, inData, sizeof v);
            const UInt32 active = v != 0 ? 1u : 0u;
            pthread_mutex_lock(&gStateMutex);
            const Boolean changed = active != gStreamIsActive;
            gStreamIsActive = active;
            pthread_mutex_unlock(&gStateMutex);
            // Activation does not change IO or structure, so a plain
            // notification is allowed (no configuration change needed).
            if (changed) {
                const AudioObjectPropertyAddress addr = { kAudioStreamPropertyIsActive, kAudioObjectPropertyScopeGlobal,
                                                          kAudioObjectPropertyElementMain };
                EQT_Notify(kEQTObjectStreamOutput, 1, &addr);
            }
            return kAudioHardwareNoError;
        }
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: {
            if (inDataSize != sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
            AudioStreamBasicDescription f;
            memcpy(&f, inData, sizeof f);
            // Only the rate may differ from the one format we speak.
            const AudioStreamBasicDescription want = EQT_StreamFormat(f.mSampleRate);
            if (f.mFormatID != want.mFormatID
                || (f.mFormatFlags & ~(UInt32)kAudioFormatFlagIsNonMixable) != want.mFormatFlags
                || f.mBytesPerPacket != want.mBytesPerPacket || f.mFramesPerPacket != want.mFramesPerPacket
                || f.mBytesPerFrame != want.mBytesPerFrame || f.mChannelsPerFrame != want.mChannelsPerFrame
                || f.mBitsPerChannel != want.mBitsPerChannel || !EQT_IsSupportedRate(f.mSampleRate)) {
                return kAudioDeviceUnsupportedFormatError;
            }
            return EQT_SetNominalRate(f.mSampleRate);
        }
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus EQT_SetVolumeProperty(const AudioObjectPropertyAddress *a, UInt32 inDataSize, const void *inData) {
    if (inDataSize != sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
    Float32 v;
    memcpy(&v, inData, sizeof v);
    if (isnan(v)) return kAudioHardwareIllegalOperationError;
    // Out-of-range values clamp (that is what the HAL's own controls do),
    // ±inf included: −inf dB is how dB-based clients ask for silence.
    const Float32 scalar = a->mSelector == kAudioLevelControlPropertyScalarValue
                               ? (Float32)EQT_Clamp(v, 0.0, 1.0)
                               : (Float32)EQT_VolumeDecibelsToScalar(v);
    pthread_mutex_lock(&gStateMutex);
    const Boolean changed = scalar != gVolumeScalar;
    gVolumeScalar = scalar;
    pthread_mutex_unlock(&gStateMutex);
    if (changed) {
        const AudioObjectPropertyAddress addrs[] = {
            { kAudioLevelControlPropertyScalarValue,  kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
            { kAudioLevelControlPropertyDecibelValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
        };
        EQT_Notify(kEQTObjectVolumeOutput, 2, addrs);
        EQT_SchedulePersist();
    }
    return kAudioHardwareNoError;
}

static OSStatus EQT_SetMuteProperty(UInt32 inDataSize, const void *inData) {
    if (inDataSize != sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
    UInt32 v;
    memcpy(&v, inData, sizeof v);
    const UInt32 mute = v != 0 ? 1u : 0u;
    pthread_mutex_lock(&gStateMutex);
    const Boolean changed = mute != gMute;
    gMute = mute;
    pthread_mutex_unlock(&gStateMutex);
    if (changed) {
        const AudioObjectPropertyAddress addr = { kAudioBooleanControlPropertyValue, kAudioObjectPropertyScopeGlobal,
                                                  kAudioObjectPropertyElementMain };
        EQT_Notify(kEQTObjectMuteOutput, 1, &addr);
        EQT_SchedulePersist();
    }
    return kAudioHardwareNoError;
}

// ---------------------------------------------------------------- property entry points

static Boolean EQT_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                               const AudioObjectPropertyAddress *inAddress) {
    (void)inClientProcessID;
    if (inDriver != gDriverRef || inAddress == NULL) return false;
    EQTReply r = { NULL, 0, 0 };
    return EQT_GetProperty(inObjectID, inAddress, 0, NULL, &r) == kAudioHardwareNoError;
}

static OSStatus EQT_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                       const AudioObjectPropertyAddress *inAddress, Boolean *outIsSettable) {
    (void)inClientProcessID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inAddress == NULL || outIsSettable == NULL) return kAudioHardwareIllegalOperationError;
    EQTReply r = { NULL, 0, 0 };
    const OSStatus err = EQT_GetProperty(inObjectID, inAddress, 0, NULL, &r);
    if (err != kAudioHardwareNoError) return err;
    *outIsSettable = EQT_PropertyIsSettable(inObjectID, inAddress->mSelector);
    return kAudioHardwareNoError;
}

static OSStatus EQT_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                        const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize,
                                        const void *inQualifierData, UInt32 *outDataSize) {
    (void)inClientProcessID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inAddress == NULL || outDataSize == NULL) return kAudioHardwareIllegalOperationError;
    EQTReply r = { NULL, 0, 0 };
    const OSStatus err = EQT_GetProperty(inObjectID, inAddress, inQualifierDataSize, inQualifierData, &r);
    if (err == kAudioHardwareNoError) *outDataSize = r.size;
    return err;
}

static OSStatus EQT_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                    const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize,
                                    const void *inQualifierData, UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    (void)inClientProcessID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inAddress == NULL || outDataSize == NULL || outData == NULL) return kAudioHardwareIllegalOperationError;
    EQTReply r = { outData, inDataSize, 0 };
    const OSStatus err = EQT_GetProperty(inObjectID, inAddress, inQualifierDataSize, inQualifierData, &r);
    if (err == kAudioHardwareNoError) *outDataSize = r.size;
    return err;
}

static OSStatus EQT_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                    const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize,
                                    const void *inQualifierData, UInt32 inDataSize, const void *inData) {
    (void)inQualifierDataSize; (void)inQualifierData;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inAddress == NULL || inData == NULL) return kAudioHardwareIllegalOperationError;
    EQTReply r = { NULL, 0, 0 };
    const OSStatus exists = EQT_GetProperty(inObjectID, inAddress, 0, NULL, &r);
    if (exists != kAudioHardwareNoError) return exists;
    if (!EQT_PropertyIsSettable(inObjectID, inAddress->mSelector)) return kAudioHardwareUnsupportedOperationError;
    switch (inObjectID) {
        case kEQTObjectDevice:       return EQT_SetDeviceProperty(inClientProcessID, inAddress, inDataSize, inData);
        case kEQTObjectStreamOutput: return EQT_SetStreamProperty(inAddress, inDataSize, inData);
        case kEQTObjectVolumeOutput: return EQT_SetVolumeProperty(inAddress, inDataSize, inData);
        case kEQTObjectMuteOutput:   return EQT_SetMuteProperty(inDataSize, inData);
        default:                     return kAudioHardwareUnsupportedOperationError;
    }
}

// ================================================================ IO

static OSStatus EQT_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    (void)inClientID;
    if (inDriver != gDriverRef || inDeviceObjectID != kEQTObjectDevice) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    if (gIOClientCount == UINT32_MAX) {
        pthread_mutex_unlock(&gStateMutex);
        return kAudioHardwareIllegalOperationError;
    }
    if (gIOClientCount == 0) {
        // First client: sample time 0 is "now", and the ring starts a fresh
        // timeline whose frame indices are exactly the HAL's sample times.
        EQT_ClockResetLocked(gSampleRate, mach_absolute_time());
        if (gRing != NULL) {
            EQTDriverRingRestartTimeline(gRing);
            EQTRingStoreIORunning(gRing, 1u);
        }
    }
    ++gIOClientCount;
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareNoError;
}

static OSStatus EQT_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    (void)inClientID;
    if (inDriver != gDriverRef || inDeviceObjectID != kEQTObjectDevice) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    if (gIOClientCount == 0) {
        pthread_mutex_unlock(&gStateMutex);
        return kAudioHardwareIllegalOperationError;   // unbalanced StopIO: never underflow
    }
    --gIOClientCount;
    if (gIOClientCount == 0 && gRing != NULL) EQTRingStoreIORunning(gRing, 0u);
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareNoError;
}

static OSStatus EQT_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                     Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed) CA_REALTIME_API {
    (void)inClientID;
    if (inDriver != gDriverRef || inDeviceObjectID != kEQTObjectDevice) return kAudioHardwareBadObjectError;
    if (outSampleTime == NULL || outHostTime == NULL || outSeed == NULL) return kAudioHardwareIllegalOperationError;

    // A virtual device has no hardware clock, so — like NullAudio — the
    // device's timeline IS the host clock at the nominal rate: zero
    // timestamps fall every EQT_ZERO_TIMESTAMP_PERIOD frames after the anchor.
    const uint64_t now = EQTDriverHostTimeNow();
    const uint64_t anchor = __atomic_load_n(&gClockAnchorHostTime, __ATOMIC_RELAXED);
    const uint64_t bits = __atomic_load_n(&gClockTicksPerFrameBits, __ATOMIC_RELAXED);
    double ticksPerFrame;
    memcpy(&ticksPerFrame, &bits, sizeof ticksPerFrame);
    const double ticksPerPeriod = ticksPerFrame * (double)EQT_ZERO_TIMESTAMP_PERIOD;

    // Advance at most one period per call (the HAL polls far more often than
    // once a period), so successive timestamps are always exactly one period
    // apart. Only this (IO) thread advances the count.
    uint64_t count = __atomic_load_n(&gClockPeriodCount, __ATOMIC_RELAXED);
    const uint64_t nextHostTime = anchor + (uint64_t)((double)(count + 1) * ticksPerPeriod);
    if (nextHostTime <= now) {
        ++count;
        __atomic_store_n(&gClockPeriodCount, count, __ATOMIC_RELAXED);
    }

    *outSampleTime = (Float64)(count * EQT_ZERO_TIMESTAMP_PERIOD);
    *outHostTime = anchor + (uint64_t)((double)count * ticksPerPeriod);
    *outSeed = __atomic_load_n(&gClockSeed, __ATOMIC_ACQUIRE);
    return kAudioHardwareNoError;
}

static OSStatus EQT_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                      UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace) {
    (void)inClientID;
    if (inDriver != gDriverRef || inDeviceObjectID != kEQTObjectDevice) return kAudioHardwareBadObjectError;
    if (outWillDo == NULL || outWillDoInPlace == NULL) return kAudioHardwareIllegalOperationError;
    // WriteMix is the only operation we take part in: it is required for an
    // output stream, and it is where the finished mix is handed to the ring.
    *outWillDo = inOperationID == kAudioServerPlugInIOOperationWriteMix;
    *outWillDoInPlace = true;
    return kAudioHardwareNoError;
}

static OSStatus EQT_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                     UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                     const AudioServerPlugInIOCycleInfo *inIOCycleInfo) CA_REALTIME_API {
    (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    if (inDriver != gDriverRef || inDeviceObjectID != kEQTObjectDevice) return kAudioHardwareBadObjectError;
    return kAudioHardwareNoError;
}

static OSStatus EQT_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID,
                                  UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                  const AudioServerPlugInIOCycleInfo *inIOCycleInfo, void *ioMainBuffer,
                                  void *ioSecondaryBuffer) CA_REALTIME_API {
    (void)inClientID; (void)ioSecondaryBuffer;
    if (inDriver != gDriverRef || inDeviceObjectID != kEQTObjectDevice) return kAudioHardwareBadObjectError;
    if (inOperationID != kAudioServerPlugInIOOperationWriteMix) return kAudioHardwareNoError;
    if (inStreamObjectID != kEQTObjectStreamOutput) return kAudioHardwareBadObjectError;
    if (ioMainBuffer == NULL || inIOCycleInfo == NULL) return kAudioHardwareIllegalOperationError;

    EQTRingHeader *ring = gRing;
    if (ring == NULL) return kAudioHardwareNoError;   // no shm: behave as a silent sink

    // WriteMix's buffer starts at the cycle's OUTPUT sample time, which is an
    // absolute frame index in the timeline that StartIO anchored at 0 — the
    // same indexing the ring uses. Round (not truncate) so 1023.9999999 is 1024.
    const Float64 sampleTime = inIOCycleInfo->mOutputTime.mSampleTime;
    if (!(sampleTime > -kEQTMaxAbsSampleTime && sampleTime < kEQTMaxAbsSampleTime)) {
        return kAudioHardwareNoError;   // NaN / garbage timestamp: drop the cycle
    }
    const int64_t firstFrame = (int64_t)(sampleTime >= 0.0 ? sampleTime + 0.5 : sampleTime - 0.5);
    EQTDriverRingWriteMix(ring, firstFrame, (const float *)ioMainBuffer, inIOBufferFrameSize, EQTDriverHostTimeNow());
    return kAudioHardwareNoError;
}

static OSStatus EQT_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                   UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                   const AudioServerPlugInIOCycleInfo *inIOCycleInfo) CA_REALTIME_API {
    (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    if (inDriver != gDriverRef || inDeviceObjectID != kEQTObjectDevice) return kAudioHardwareBadObjectError;
    return kAudioHardwareNoError;
}
