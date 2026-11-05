//
//  EQTDriver.h
//  EQtargets Audio — HAL driver (AudioServerPlugIn), internal declarations.
//
//  Shared between EQtargetsAudioDriver.c (plug-in object model, clock, IO
//  entry points) and EQTDriverRing.c (the shared-memory ring writer). Nothing
//  here is exported from the bundle: the target builds with
//  GCC_SYMBOLS_PRIVATE_EXTERN=YES, so the only public symbol is the CFPlugIn
//  factory EQTargets_Create (marked visibility("default") below).
//

#ifndef EQT_DRIVER_H
#define EQT_DRIVER_H

#include <CoreAudio/AudioServerPlugIn.h>
#include <stdint.h>
#include "EQTRingProtocol.h"

// Enable Clang's compile-time real-time checker for every driver file. The SDK
// marks the IO entry points (GetZeroTimeStamp, Begin/Do/EndIOOperation) as
// CA_REALTIME_API == __attribute__((nonblocking)); with this warning on, the
// compiler rejects any lock, allocation or unannotated call reachable from
// them. It is off by default in Xcode, hence the pragma.
#pragma clang diagnostic warning "-Wfunction-effects"

#ifdef __cplusplus
extern "C" {
#endif

/// Cross-file driver internals are hidden EXPLICITLY. The target sets
/// GCC_SYMBOLS_PRIVATE_EXTERN=YES, but Xcode 27.2 resolves it to NO in Debug
/// (seen with -showBuildSettings, 2026-11-04), which exported these from the
/// bundle. Only the factory may be visible to coreaudiod.
#define EQT_INTERNAL __attribute__((visibility("hidden")))

// ---------------------------------------------------------------- object IDs
// The plug-in object must be kAudioObjectPlugInObject (1); the rest are ours.
// They are fixed for the life of the process: the device is never destroyed.
enum {
    kEQTObjectPlugIn       = kAudioObjectPlugInObject,
    kEQTObjectBox          = 2,
    kEQTObjectDevice       = 3,
    kEQTObjectStreamOutput = 4,
    kEQTObjectVolumeOutput = 5,
    kEQTObjectMuteOutput   = 6
};

#define EQT_BOX_UID                 "com.eqtargets.audio.box"
#define EQT_DEFAULT_SAMPLE_RATE     48000.0
/// Frames between successive GetZeroTimeStamp() anchors. The HAL requires at
/// least 10923; 16384 matches Apple's NullAudio sample (341 ms @ 48 kHz).
#define EQT_ZERO_TIMESTAMP_PERIOD   16384u
/// Upper clamp for the app-reported 'eqtl' latency: one second at the highest
/// supported rate. Anything larger is a bug on the caller's side, and an
/// absurd latency would make video players drop sync entirely.
#define EQT_MAX_CLIENT_LATENCY      192000u

// ---------------------------------------------------------------- factory
/// CFPlugIn factory named in Driver/Info.plist (CFPlugInFactories). The ONLY
/// exported symbol of the bundle.
__attribute__((visibility("default")))
void *EQTargets_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID);

// ---------------------------------------------------------------- ring (EQTDriverRing.c)
/// Creates or re-attaches the shared-memory ring `name` exactly as
/// docs/ARCHITECTURE.md §5 prescribes, writes the immutable header fields,
/// resets the runtime state (new generation, writeHead 0, ioRunning 0) and
/// publishes `magic` last. Returns NULL (after logging) on any failure; the
/// driver then keeps publishing the device and WriteMix becomes a no-op.
/// NOT real-time safe (syscalls + logging): call from Initialize only.
EQT_INTERNAL EQTRingHeader *EQTDriverRingOpen(const char *name, double sampleRate, uint64_t nowHostTime);

/// Starts a new timeline: writeHead = 0, generation += 1, writeHead = 0.
/// Called on the first StartIO and on every sample-rate change, while no IO
/// is running (the HAL guarantees that), so this thread is the only writer.
EQT_INTERNAL void EQTDriverRingRestartTimeline(EQTRingHeader *ring);

/// The writer protocol from EQTRingProtocol.h for one WriteMix of `frames`
/// interleaved stereo float32 frames whose first frame is absolute frame
/// `firstFrame` of the current timeline. Real-time safe: no locks, no
/// allocation, no syscalls, no logging.
EQT_INTERNAL void EQTDriverRingWriteMix(EQTRingHeader *ring,
                           int64_t firstFrame,
                           const float *src,
                           uint32_t frames,
                           uint64_t hostTime) CA_REALTIME_API;

/// mach_absolute_time() for real-time code. It is a lock-free read of the
/// hardware counter / commpage, so it is safe on the IO thread, but the SDK
/// does not annotate it `nonblocking`, so -Wfunction-effects would flag every
/// call. This wrapper is the one audited exception.
EQT_INTERNAL uint64_t EQTDriverHostTimeNow(void) CA_REALTIME_API;

#ifdef __cplusplus
}
#endif

#endif /* EQT_DRIVER_H */
