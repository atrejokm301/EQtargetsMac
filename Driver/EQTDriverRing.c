//
//  EQTDriverRing.c
//  EQtargets Audio — the writer side of the shared-memory ring.
//
//  The ring is the ONLY way audio leaves the driver: the device publishes no
//  input stream (that would cost the app Microphone permission and light the
//  orange indicator), so the system mix is handed to EQtargets.app through
//  POSIX shared memory instead. Shared/EQTRingProtocol.h is the contract;
//  this file implements its writer half and nothing else.
//

#include "EQTDriver.h"

#include <dispatch/dispatch.h>
#include <errno.h>
#include <fcntl.h>
#include <mach/mach_time.h>
#include <os/log.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

static os_log_t EQTRingLog(void) {
    static os_log_t sLog;
    static dispatch_once_t sOnce;
    dispatch_once(&sOnce, ^{ sLog = os_log_create(EQT_DRIVER_BUNDLE_ID, "ring"); });
    return sLog;
}

uint64_t EQTDriverHostTimeNow(void) CA_REALTIME_API {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wfunction-effects"
    return mach_absolute_time();
#pragma clang diagnostic pop
}

// ---------------------------------------------------------------- open / attach

/// True if an existing shm object's fstat() size is the size we create.
/// macOS reports a POSIX shm object's size ROUNDED UP TO THE VM PAGE: on Apple
/// silicon (16 KB pages) a ring sized with ftruncate(EQT_RING_TOTAL_BYTES =
/// 266240) fstat()s as 278528. Comparing against the exact byte count would
/// make every re-attach (each coreaudiod restart) look like "wrong size" and
/// needlessly recreate the ring, orphaning any reader. Measured 2026-11-04.
static int EQTRingSizeIsOurs(off_t size) {
    const off_t total = (off_t)EQT_RING_TOTAL_BYTES;
    const long page = sysconf(_SC_PAGESIZE);
    const off_t rounded = page > 0 ? ((total + (off_t)page - 1) / (off_t)page) * (off_t)page : total;
    return size == total || size == rounded;
}

/// shm_open + fchmod + fstat. Returns the fd (>= 0) and the object's current
/// size, or -1 with errno set.
static int EQTRingShmOpen(const char *name, off_t *outSize) {
    int fd = shm_open(name, O_CREAT | O_RDWR, 0644);
    if (fd < 0) return -1;
    // shm_open's mode is filtered through the host process's umask; the app
    // (a different user than coreaudiod's _coreaudiod) needs read access, so
    // set the mode explicitly. Failure is not fatal: if we did not create the
    // object we may not own it, and its existing mode is whatever it was.
    if (fchmod(fd, 0644) != 0) {
        os_log_error(EQTRingLog(), "fchmod(%{public}s, 0644) failed: errno %d", name, errno);
    }
    struct stat st;
    if (fstat(fd, &st) != 0) {
        int saved = errno;
        close(fd);
        errno = saved;
        return -1;
    }
    *outSize = st.st_size;
    return fd;
}

EQTRingHeader *EQTDriverRingOpen(const char *name, double sampleRate, uint64_t nowHostTime) {
    if (name == NULL || name[0] != '/') {
        os_log_error(EQTRingLog(), "invalid ring name; ring disabled");
        return NULL;
    }

    off_t size = 0;
    int fd = EQTRingShmOpen(name, &size);
    if (fd < 0 && errno == EACCES) {
        // A stale object we cannot write (e.g. left by a different user with
        // a different build). Try to replace it once.
        os_log_error(EQTRingLog(), "shm_open(%{public}s) EACCES; unlinking stale ring", name);
        shm_unlink(name);
        fd = EQTRingShmOpen(name, &size);
    }
    if (fd < 0) {
        os_log_error(EQTRingLog(), "shm_open(%{public}s) failed: errno %d; ring disabled", name, errno);
        return NULL;
    }

    if (size != 0 && !EQTRingSizeIsOurs(size)) {
        // An object from an incompatible build. macOS lets ftruncate size a
        // POSIX shm object exactly once (while it is still 0 bytes), so the
        // only way to change its size is to unlink and recreate it. A reader
        // still mapping the old object keeps a dead mapping; it notices because
        // the header never advances again and re-opens by name.
        os_log_error(EQTRingLog(), "ring %{public}s has size %lld, expected %u; recreating",
                     name, (long long)size, (unsigned)EQT_RING_TOTAL_BYTES);
        close(fd);
        shm_unlink(name);
        fd = EQTRingShmOpen(name, &size);
        if (fd < 0) {
            os_log_error(EQTRingLog(), "shm_open(%{public}s) after unlink failed: errno %d; ring disabled", name, errno);
            return NULL;
        }
    }

    if (size == 0) {
        if (ftruncate(fd, (off_t)EQT_RING_TOTAL_BYTES) != 0) {
            os_log_error(EQTRingLog(), "ftruncate(%{public}s, %u) failed: errno %d; ring disabled",
                         name, (unsigned)EQT_RING_TOTAL_BYTES, errno);
            close(fd);
            return NULL;
        }
    } else if (!EQTRingSizeIsOurs(size)) {
        os_log_error(EQTRingLog(), "ring %{public}s still has size %lld; ring disabled", name, (long long)size);
        close(fd);
        return NULL;
    }

    void *mem = mmap(NULL, EQT_RING_TOTAL_BYTES, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    int mapErr = errno;
    close(fd);   // the mapping keeps the object alive
    if (mem == MAP_FAILED) {
        os_log_error(EQTRingLog(), "mmap(%{public}s) failed: errno %d; ring disabled", name, mapErr);
        return NULL;
    }

    EQTRingHeader *h = (EQTRingHeader *)mem;

    // Hide the header while it is rewritten (a re-attach after a coreaudiod
    // restart may find a reader already mapped), then publish magic LAST with
    // release ordering so a reader that sees the magic sees every field.
    EQTRingStoreMagic(h, 0u);
    __atomic_store_n(&h->version,        EQT_RING_VERSION,         __ATOMIC_RELAXED);
    __atomic_store_n(&h->channels,       EQT_RING_CHANNELS,        __ATOMIC_RELAXED);
    __atomic_store_n(&h->capacityFrames, EQT_RING_CAPACITY_FRAMES, __ATOMIC_RELAXED);
    __atomic_store_n(&h->headerBytes,    EQT_RING_HEADER_BYTES,    __ATOMIC_RELAXED);
    __atomic_store_n(&h->reserved0,      0u,                       __ATOMIC_RELAXED);

    EQTRingStoreSampleRate(h, sampleRate);
    EQTRingStoreIORunning(h, 0u);
    EQTRingStoreIOBufferFrames(h, 0u);
    EQTRingStoreLastWriteHostTime(h, 0u);
    __atomic_store_n(&h->writeCycles,        (uint64_t)0, __ATOMIC_RELAXED);
    __atomic_store_n(&h->zeroFilledFrames,   (uint64_t)0, __ATOMIC_RELAXED);
    __atomic_store_n(&h->driverLoadHostTime, nowHostTime, __ATOMIC_RELAXED);
    // Generation keeps counting from whatever an earlier driver instance left,
    // so a reader that survived a coreaudiod restart sees a change and resyncs.
    EQTDriverRingRestartTimeline(h);

    EQTRingStoreMagic(h, EQT_RING_MAGIC);
    return h;
}

void EQTDriverRingRestartTimeline(EQTRingHeader *ring) {
    // The protocol says "generation += 1, then writeHead = 0". We ALSO zero
    // writeHead *before* the bump: the bump is an acq_rel RMW, so any reader
    // that observes the new generation is then guaranteed to observe
    // writeHead == 0 — never the previous timeline's large head paired with
    // the new generation (which would make a reader resync to a position the
    // new timeline only reaches minutes later). The trailing store keeps the
    // literal protocol order. Only called while IO is stopped, so this thread
    // is the sole writer.
    EQTRingStoreWriteHead(ring, 0);
    EQTRingBumpGeneration(ring);
    EQTRingStoreWriteHead(ring, 0);
}

// ---------------------------------------------------------------- real-time writer

#define EQT_RING_MASK ((int64_t)EQT_RING_CAPACITY_FRAMES - 1)

/// Copies `count` frames into the ring starting at absolute frame `frame`,
/// wrapping at the end of the sample area. `src == NULL` writes silence.
static inline void EQTRingStoreFrames(float *samples, int64_t frame, const float *src, int64_t count) CA_REALTIME_API {
    while (count > 0) {
        const int64_t slot = frame & EQT_RING_MASK;
        int64_t run = (int64_t)EQT_RING_CAPACITY_FRAMES - slot;
        if (run > count) run = count;
        const size_t bytes = (size_t)run * EQT_RING_CHANNELS * sizeof(float);
        float *dst = samples + slot * (int64_t)EQT_RING_CHANNELS;
        if (src != NULL) {
            memcpy(dst, src, bytes);
            src += run * (int64_t)EQT_RING_CHANNELS;
        } else {
            memset(dst, 0, bytes);
        }
        frame += run;
        count -= run;
    }
}

void EQTDriverRingWriteMix(EQTRingHeader *ring,
                           int64_t firstFrame,
                           const float *src,
                           uint32_t frames,
                           uint64_t hostTime) CA_REALTIME_API {
    // We are the only writer, so a relaxed load returns our own last store.
    const int64_t head = __atomic_load_n(&ring->writeHead, __ATOMIC_RELAXED);
    const int64_t end = firstFrame + (int64_t)frames;   // exclusive
    uint64_t zeroed = 0;

    if (frames > 0 && end > 0) {
        float *samples = EQTRingSamples(ring);
        const int64_t newHead = end > head ? end : head;
        // After this write the reader may look at most `capacity` frames below
        // newHead. Frames older than that share ring slots with newer frames,
        // so writing them would corrupt live audio: never touch them.
        const int64_t oldestKept = newHead - (int64_t)EQT_RING_CAPACITY_FRAMES;

        // 1. A sample-time gap (a skipped IO cycle, or the first cycle after
        //    StartIO) must read as silence, never as stale audio from an older
        //    lap. Only the part still inside the window needs clearing — that
        //    caps the work at `capacity` frames however large the gap is.
        if (firstFrame > head) {
            const int64_t zeroStart = head > oldestKept ? head : oldestKept;
            if (zeroStart < firstFrame) {
                EQTRingStoreFrames(samples, zeroStart, NULL, firstFrame - zeroStart);
                zeroed = (uint64_t)(firstFrame - zeroStart);
            }
        }

        // 2. Copy the mix. Frames below 0 do not exist in the timeline and
        //    frames below oldestKept would overwrite newer audio (see above).
        int64_t copyStart = firstFrame;
        if (copyStart < oldestKept) copyStart = oldestKept;
        if (copyStart < 0) copyStart = 0;
        if (copyStart < end) {
            EQTRingStoreFrames(samples, copyStart,
                               src + (copyStart - firstFrame) * (int64_t)EQT_RING_CHANNELS,
                               end - copyStart);
        }

        // 3. Publish. RELEASE makes the sample bytes above visible to a reader
        //    that ACQUIREs writeHead. max() means a rewrite of an older range
        //    never moves the head backwards.
        EQTRingStoreWriteHead(ring, newHead);
    }

    // Diagnostics (relaxed: informational only, read by the app's stats/PLL
    // sizing and by `eqt-probe --ring`).
    EQTRingStoreIOBufferFrames(ring, frames);
    EQTRingStoreLastWriteHostTime(ring, hostTime);
    __atomic_store_n(&ring->writeCycles,
                     __atomic_load_n(&ring->writeCycles, __ATOMIC_RELAXED) + 1u, __ATOMIC_RELAXED);
    if (zeroed != 0) {
        __atomic_store_n(&ring->zeroFilledFrames,
                         __atomic_load_n(&ring->zeroFilledFrames, __ATOMIC_RELAXED) + zeroed, __ATOMIC_RELAXED);
    }
}
