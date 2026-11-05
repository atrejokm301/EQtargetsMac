//
//  EQTRingProtocol.h
//  EQtargets (macOS)
//
//  The ONE contract between the EQtargets Audio driver (C, runs inside
//  coreaudiod) and the EQtargets app (Swift). Both sides include this file.
//  Change it only by bumping EQT_RING_VERSION — the app refuses a ring whose
//  magic/version/geometry it does not recognise.
//
//  WHY SHARED MEMORY AND NOT AN INPUT STREAM
//  ------------------------------------------------------------------
//  The driver publishes an OUTPUT-ONLY device. A loopback "cable" (BlackHole /
//  eqMac style) would publish an input stream, and any input stream costs the
//  app Microphone permission and lights the orange recording indicator. We
//  hand the mix to the app through this ring instead, so the app needs no
//  privacy permission of any kind. Never "simplify" this into an input stream,
//  and never replace it with a Core Audio process tap (CATap): both are
//  permission-gated capture paths.
//
//  LAYOUT
//  ------------------------------------------------------------------
//  [ EQTRingHeader, padded to EQT_RING_HEADER_BYTES ]
//  [ float32 samples, interleaved, EQT_RING_CHANNELS per frame,
//    EQT_RING_CAPACITY_FRAMES frames ]
//
//  Frame f (an absolute frame index in the current generation's timeline)
//  lives at samples[(f & (capacity-1)) * channels + ch].
//
//  CONCURRENCY — single producer, single consumer, lock-free
//  ------------------------------------------------------------------
//  Producer: the driver's IO thread (WriteMix). Consumer: the app's output
//  render thread. Neither side ever blocks or takes a lock.
//
//  Writer, per WriteMix of N frames starting at absolute frame T:
//    1. if T > writeHead: zero-fill [writeHead, T) (at most capacity frames)
//       so a skipped IO cycle reads as silence, never as stale audio.
//    2. copy the N frames into the ring.
//    3. store writeHead = max(writeHead, T + N) with RELEASE ordering.
//  Writer, on StartIO (first client) and on every sample-rate change:
//    generation += 1 (RELEASE), then writeHead = 0 (RELEASE), ioRunning = 1.
//  Writer, on StopIO (last client): ioRunning = 0 (RELEASE).
//
//  Reader:
//    1. g0 = generation (ACQUIRE); h = writeHead (ACQUIRE).
//    2. read frames strictly below h, never more than capacity behind h.
//    3. g1 = generation (ACQUIRE); h1 = writeHead (ACQUIRE).
//       If g1 != g0 → the timeline restarted: discard what was read, resync.
//       If h1 - (oldest frame read) > capacity → the writer lapped the reader
//       mid-copy (torn read): discard, resync.
//
//  The sample data itself is plain memory; the acquire/release pair on
//  writeHead is what makes the frames below it visible to the reader.
//

#ifndef EQT_RING_PROTOCOL_H
#define EQT_RING_PROTOCOL_H

#include <stdint.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

#define EQT_RING_SHM_NAME         "/eqtargets.audio.ring"
#define EQT_RING_MAGIC            0x52545145u   /* bytes 'E','Q','T','R' in memory (little-endian) */
#define EQT_RING_VERSION          1u
#define EQT_RING_CHANNELS         2u
#define EQT_RING_CAPACITY_FRAMES  32768u        /* power of two: ~0.68 s @ 48 kHz, ~0.17 s @ 192 kHz */
#define EQT_RING_HEADER_BYTES     4096u
#define EQT_RING_SAMPLE_BYTES     (EQT_RING_CAPACITY_FRAMES * EQT_RING_CHANNELS * 4u)
#define EQT_RING_TOTAL_BYTES      (EQT_RING_HEADER_BYTES + EQT_RING_SAMPLE_BYTES)

/// Identity of the virtual device the driver publishes. The app finds the
/// device by this UID; never match on the display name.
#define EQT_DEVICE_UID            "com.eqtargets.audio.device"
#define EQT_DEVICE_MODEL_UID      "com.eqtargets.audio.model"
#define EQT_DEVICE_NAME           "EQtargets Audio"
#define EQT_DEVICE_MANUFACTURER   "EQtargets"

/// Bundle identifier of the driver (.driver bundle in /Library/Audio/Plug-Ins/HAL).
#define EQT_DRIVER_BUNDLE_ID      "com.eqtargets.app.driver"
#define EQT_DRIVER_BUNDLE_NAME    "EQtargetsAudio.driver"

/// Optional custom device property (CFNumber, frames) the app may SET on the
/// virtual device to report the extra latency its pipeline adds (ring target
/// + output device latency). The driver adds it to kAudioDevicePropertyLatency
/// so video players can keep lip sync. Declared via
/// kAudioObjectPropertyCustomPropertyInfoList with
/// kAudioServerPlugInCustomPropertyDataTypeCFPropertyList.
#define EQT_PROPERTY_CLIENT_LATENCY  0x6571746Cu   /* 'eqtl' */

typedef struct EQTRingHeader {
    /* ---- immutable after creation (written before `magic` is published) ---- */
    uint32_t magic;              /* EQT_RING_MAGIC, stored LAST during init (release) */
    uint32_t version;            /* EQT_RING_VERSION */
    uint32_t channels;           /* EQT_RING_CHANNELS */
    uint32_t capacityFrames;     /* EQT_RING_CAPACITY_FRAMES */
    uint32_t headerBytes;        /* EQT_RING_HEADER_BYTES — sample data offset */
    uint32_t reserved0;

    /* ---- driver-owned runtime state: access ONLY through the helpers below ---- */
    uint64_t sampleRateBits;     /* IEEE-754 bits of the device's nominal rate (double) */
    int64_t  writeHead;          /* exclusive end of the newest written frame, current generation */
    uint64_t generation;         /* +1 on StartIO and on every sample-rate change */
    uint32_t ioRunning;          /* 1 while the device's IO is running */
    uint32_t ioBufferFrames;     /* frames in the most recent WriteMix (diagnostics / PLL sizing) */
    uint64_t lastWriteHostTime;  /* mach_absolute_time() at the most recent WriteMix */
    uint64_t writeCycles;        /* WriteMix count since the driver loaded (diagnostics) */
    uint64_t zeroFilledFrames;   /* frames zero-filled for sample-time gaps (diagnostics) */
    uint64_t driverLoadHostTime; /* mach_absolute_time() when the driver created/attached the ring */
    /* No padding array on purpose: Swift imports C arrays as tuples, and a
       4 KB tuple makes the type checker crawl. Sample data starts at the
       fixed EQT_RING_HEADER_BYTES offset regardless of sizeof(EQTRingHeader). */
} EQTRingHeader;

_Static_assert(sizeof(EQTRingHeader) <= EQT_RING_HEADER_BYTES, "EQTRingHeader must fit in the header page");
_Static_assert((EQT_RING_CAPACITY_FRAMES & (EQT_RING_CAPACITY_FRAMES - 1u)) == 0u, "capacity must be a power of two");

/* ---- atomic helpers: the ONLY way either side touches runtime fields ---- */

static inline uint32_t EQTRingLoadMagic(const EQTRingHeader *h)       { return __atomic_load_n(&h->magic, __ATOMIC_ACQUIRE); }
static inline void     EQTRingStoreMagic(EQTRingHeader *h, uint32_t v) { __atomic_store_n(&h->magic, v, __ATOMIC_RELEASE); }

static inline int64_t  EQTRingLoadWriteHead(const EQTRingHeader *h)        { return __atomic_load_n(&h->writeHead, __ATOMIC_ACQUIRE); }
static inline void     EQTRingStoreWriteHead(EQTRingHeader *h, int64_t v)  { __atomic_store_n(&h->writeHead, v, __ATOMIC_RELEASE); }

static inline uint64_t EQTRingLoadGeneration(const EQTRingHeader *h)       { return __atomic_load_n(&h->generation, __ATOMIC_ACQUIRE); }
static inline void     EQTRingBumpGeneration(EQTRingHeader *h)             { __atomic_add_fetch(&h->generation, 1, __ATOMIC_ACQ_REL); }

static inline uint32_t EQTRingLoadIORunning(const EQTRingHeader *h)        { return __atomic_load_n(&h->ioRunning, __ATOMIC_ACQUIRE); }
static inline void     EQTRingStoreIORunning(EQTRingHeader *h, uint32_t v) { __atomic_store_n(&h->ioRunning, v, __ATOMIC_RELEASE); }

static inline uint32_t EQTRingLoadIOBufferFrames(const EQTRingHeader *h)        { return __atomic_load_n(&h->ioBufferFrames, __ATOMIC_RELAXED); }
static inline void     EQTRingStoreIOBufferFrames(EQTRingHeader *h, uint32_t v) { __atomic_store_n(&h->ioBufferFrames, v, __ATOMIC_RELAXED); }

static inline uint64_t EQTRingLoadLastWriteHostTime(const EQTRingHeader *h)        { return __atomic_load_n(&h->lastWriteHostTime, __ATOMIC_RELAXED); }
static inline void     EQTRingStoreLastWriteHostTime(EQTRingHeader *h, uint64_t v) { __atomic_store_n(&h->lastWriteHostTime, v, __ATOMIC_RELAXED); }

static inline double EQTRingLoadSampleRate(const EQTRingHeader *h) {
    uint64_t bits = __atomic_load_n(&h->sampleRateBits, __ATOMIC_ACQUIRE);
    double d; memcpy(&d, &bits, sizeof d); return d;
}
static inline void EQTRingStoreSampleRate(EQTRingHeader *h, double rate) {
    uint64_t bits; memcpy(&bits, &rate, sizeof bits);
    __atomic_store_n(&h->sampleRateBits, bits, __ATOMIC_RELEASE);
}

/// Derived sizes as functions: Swift cannot import computed macros.
static inline uint32_t EQTRingSampleBytes(void) { return EQT_RING_SAMPLE_BYTES; }
static inline uint32_t EQTRingTotalBytes(void)  { return EQT_RING_TOTAL_BYTES; }

/// Pointer to the interleaved sample area that follows the header.
static inline float *EQTRingSamples(EQTRingHeader *h) {
    return (float *)((uint8_t *)h + EQT_RING_HEADER_BYTES);
}
static inline const float *EQTRingSamplesConst(const EQTRingHeader *h) {
    return (const float *)((const uint8_t *)h + EQT_RING_HEADER_BYTES);
}

/// 1 if the mapped header describes a ring this build understands.
static inline int EQTRingHeaderIsValid(const EQTRingHeader *h) {
    return EQTRingLoadMagic(h) == EQT_RING_MAGIC
        && h->version == EQT_RING_VERSION
        && h->channels == EQT_RING_CHANNELS
        && h->capacityFrames == EQT_RING_CAPACITY_FRAMES
        && h->headerBytes == EQT_RING_HEADER_BYTES;
}

#ifdef __cplusplus
}
#endif

#endif /* EQT_RING_PROTOCOL_H */
