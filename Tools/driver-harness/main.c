//
//  main.c — eqt-driver-harness
//  EQtargets (macOS)
//
//  Tests the BUILT EQtargets Audio driver without installing it: dlopen()s the
//  driver executable, creates the plug-in through its CFPlugIn factory, and
//  plays coreaudiod's part with a fake AudioServerPlugInHostInterface. It
//  then drives the real IO entry points and reads the shared-memory ring back
//  exactly the way EQtargets.app does (O_RDONLY + PROT_READ), so a passing run
//  means the binary we would install behaves to contract.
//
//  The driver is pointed at a private ring (EQT_RING_NAME_OVERRIDE) so the
//  harness can never touch a real installed driver's ring; it is unlinked at
//  the end.
//
//  Usage:
//    eqt-driver-harness [driver]          full test suite; exit 0 only if every check passes
//    eqt-driver-harness --serve <sec> [--ppm <p>] [driver]
//                                         real-time 1 kHz / -20 dBFS tone into the ring named by
//                                         $EQT_RING_NAME_OVERRIDE, paced by the host clock and
//                                         deliberately (1 + p·1e-6) fast — a known source for
//                                         verifying `eqt-probe --ring`
//  [driver] is the .driver bundle or its executable; default: next to this tool
//  (<products>/EQtargetsAudio.driver/Contents/MacOS/EQtargetsAudio).
//
//  Expected values below come from the CONTRACT (task spec, ARCHITECTURE.md,
//  EQTRingProtocol.h), never from the driver's own headers, so a drifting
//  driver fails here instead of silently agreeing with itself.
//

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <libgen.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <mach/mach_time.h>
#include <math.h>
#include <pthread.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#include "EQTRingProtocol.h"

extern char **environ;

// ================================================================ contract constants

static const Float64 kContractRates[] = { 44100.0, 48000.0, 88200.0, 96000.0, 176400.0, 192000.0 };
#define kContractRateCount 6u
#define kContractPeriod    16384u
#define kContractBoxUID    "com.eqtargets.audio.box"
#define kContractMaxLatency 192000u
#define kRingCap   ((int64_t)EQT_RING_CAPACITY_FRAMES)
#define kRingMask  (kRingCap - 1)
#define kCh        ((int64_t)EQT_RING_CHANNELS)

static const AudioObjectPropertyScope kGlobal = kAudioObjectPropertyScopeGlobal;
static const AudioObjectPropertyScope kOut    = kAudioObjectPropertyScopeOutput;
static const AudioObjectPropertyScope kIn     = kAudioObjectPropertyScopeInput;

/// Documented taper (EQtargetsAudioDriver.c header): g(s) = 60·log10(F + (1−F)s), F = 10^(−64/60).
static double RefTaperDB(double s) {
    const double F = pow(10.0, -64.0 / 60.0);
    return 60.0 * log10(F + (1.0 - F) * s);
}

// ================================================================ reporting

static int gPass, gFail;
static const char *gPrefix = "";
/// A NULL the compiler can't see through, for deliberately passing NULL to
/// _Nonnull driver parameters (the driver must reject it, not crash).
static void *volatile gNull = NULL;

static void check(bool ok, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
static void check(bool ok, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    printf("%s%s  ", gPrefix, ok ? "PASS" : "FAIL");
    vprintf(fmt, ap);
    printf("\n");
    va_end(ap);
    if (ok) gPass++; else gFail++;
}

static void section(const char *name) { printf("\n%s== %s\n", gPrefix, name); }

static double gTicksPerSecond;
static double SecondsSince(uint64_t t0) { return (double)(mach_absolute_time() - t0) / gTicksPerSecond; }
static void SleepMs(unsigned ms) { usleep(ms * 1000u); }

// ================================================================ fake host

typedef struct { AudioObjectID object; AudioObjectPropertySelector selector; AudioObjectPropertyScope scope; } Note;
#define kMaxNotes 4096

static AudioServerPlugInDriverRef gDrv;
static pthread_mutex_t gHostMutex = PTHREAD_MUTEX_INITIALIZER;
static Note gNotes[kMaxNotes];
static int gNoteCount;
static CFMutableDictionaryRef gStorage;
static int gPerformCount;
/// When set, the fake host QUEUES configuration-change requests instead of
/// performing them inside Request (coreaudiod may defer Perform to another
/// thread; the driver also dispatches its own Request, so requests can arrive
/// late and out of order). The test performs the queue explicitly.
static bool gDeferPerform;
#define kMaxDeferred 16
static UInt64 gDeferred[kMaxDeferred];
static int gDeferredCount;

static OSStatus Host_PropertiesChanged(AudioServerPlugInHostRef host, AudioObjectID object, UInt32 count,
                                       const AudioObjectPropertyAddress *addresses) {
    (void)host;
    pthread_mutex_lock(&gHostMutex);
    for (UInt32 i = 0; i < count && gNoteCount < kMaxNotes; i++) {
        gNotes[gNoteCount++] = (Note){ object, addresses[i].mSelector, addresses[i].mScope };
    }
    pthread_mutex_unlock(&gHostMutex);
    return kAudioHardwareNoError;
}

static OSStatus Host_CopyFromStorage(AudioServerPlugInHostRef host, CFStringRef key, CFPropertyListRef *outData) {
    (void)host;
    pthread_mutex_lock(&gHostMutex);
    CFPropertyListRef v = CFDictionaryGetValue(gStorage, key);
    if (v != NULL) CFRetain(v);
    pthread_mutex_unlock(&gHostMutex);
    *outData = v;
    return v != NULL ? kAudioHardwareNoError : kAudioHardwareUnknownPropertyError;
}

static OSStatus Host_WriteToStorage(AudioServerPlugInHostRef host, CFStringRef key, CFPropertyListRef data) {
    (void)host;
    pthread_mutex_lock(&gHostMutex);
    CFDictionarySetValue(gStorage, key, data);
    pthread_mutex_unlock(&gHostMutex);
    return kAudioHardwareNoError;
}

static OSStatus Host_DeleteFromStorage(AudioServerPlugInHostRef host, CFStringRef key) {
    (void)host;
    pthread_mutex_lock(&gHostMutex);
    CFDictionaryRemoveValue(gStorage, key);
    pthread_mutex_unlock(&gHostMutex);
    return kAudioHardwareNoError;
}

/// coreaudiod would stop IO, call Perform, then restart IO; we just Perform synchronously.
static OSStatus Host_RequestDeviceConfigurationChange(AudioServerPlugInHostRef host, AudioObjectID device,
                                                      UInt64 action, void *info) {
    (void)host;
    pthread_mutex_lock(&gHostMutex);
    const bool defer = gDeferPerform;
    if (defer && gDeferredCount < kMaxDeferred) gDeferred[gDeferredCount++] = action;
    pthread_mutex_unlock(&gHostMutex);
    if (defer) return kAudioHardwareNoError;
    const OSStatus err = (*gDrv)->PerformDeviceConfigurationChange(gDrv, device, action, info);
    pthread_mutex_lock(&gHostMutex);
    gPerformCount++;
    pthread_mutex_unlock(&gHostMutex);
    return err;
}

static const AudioServerPlugInHostInterface gHostInterface = {
    .PropertiesChanged                = Host_PropertiesChanged,
    .CopyFromStorage                  = Host_CopyFromStorage,
    .WriteToStorage                   = Host_WriteToStorage,
    .DeleteFromStorage                = Host_DeleteFromStorage,
    .RequestDeviceConfigurationChange = Host_RequestDeviceConfigurationChange,
};

static int NoteMark(void) {
    pthread_mutex_lock(&gHostMutex);
    const int n = gNoteCount;
    pthread_mutex_unlock(&gHostMutex);
    return n;
}

static bool SawNote(int since, AudioObjectID object, AudioObjectPropertySelector selector, AudioObjectPropertyScope scope) {
    bool seen = false;
    pthread_mutex_lock(&gHostMutex);
    for (int i = since; i < gNoteCount && !seen; i++) {
        seen = gNotes[i].object == object && gNotes[i].selector == selector && gNotes[i].scope == scope;
    }
    pthread_mutex_unlock(&gHostMutex);
    return seen;
}

static bool WaitNote(int since, AudioObjectID object, AudioObjectPropertySelector selector,
                     AudioObjectPropertyScope scope, double timeout) {
    const uint64_t t0 = mach_absolute_time();
    while (!SawNote(since, object, selector, scope)) {
        if (SecondsSince(t0) > timeout) return false;
        SleepMs(5);
    }
    return true;
}

static int PerformCount(void) {
    pthread_mutex_lock(&gHostMutex);
    const int n = gPerformCount;
    pthread_mutex_unlock(&gHostMutex);
    return n;
}

static bool WaitPerform(int before, double timeout) {
    const uint64_t t0 = mach_absolute_time();
    while (PerformCount() == before) {
        if (SecondsSince(t0) > timeout) return false;
        SleepMs(5);
    }
    return true;
}

/// Takes the queued requests (in arrival order) and empties the queue.
static int TakeDeferred(UInt64 *out) {
    pthread_mutex_lock(&gHostMutex);
    const int n = gDeferredCount;
    for (int i = 0; i < n; i++) out[i] = gDeferred[i];
    gDeferredCount = 0;
    pthread_mutex_unlock(&gHostMutex);
    return n;
}

static bool StorageDouble(CFStringRef key, double *out) {
    bool ok = false;
    pthread_mutex_lock(&gHostMutex);
    CFPropertyListRef v = CFDictionaryGetValue(gStorage, key);
    if (v != NULL && CFGetTypeID(v) == CFNumberGetTypeID()) ok = CFNumberGetValue((CFNumberRef)v, kCFNumberFloat64Type, out);
    pthread_mutex_unlock(&gHostMutex);
    return ok;
}

static void ResetHostStorage(void) {
    if (gStorage != NULL) CFRelease(gStorage);
    gStorage = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
}

// ================================================================ driver property helpers

static OSStatus GetData(AudioObjectID obj, AudioObjectPropertySelector sel, AudioObjectPropertyScope scope,
                        UInt32 qualifierSize, const void *qualifier, UInt32 capacity, void *out, UInt32 *outSize) {
    const AudioObjectPropertyAddress a = { sel, scope, kAudioObjectPropertyElementMain };
    UInt32 size = 0;
    const OSStatus err = (*gDrv)->GetPropertyData(gDrv, obj, getpid(), &a, qualifierSize, qualifier, capacity, &size, out);
    if (outSize != NULL) *outSize = size;
    return err;
}

static OSStatus GetSize(AudioObjectID obj, AudioObjectPropertySelector sel, AudioObjectPropertyScope scope, UInt32 *outSize) {
    const AudioObjectPropertyAddress a = { sel, scope, kAudioObjectPropertyElementMain };
    *outSize = 0;
    return (*gDrv)->GetPropertyDataSize(gDrv, obj, getpid(), &a, 0, NULL, outSize);
}

static bool Has(AudioObjectID obj, AudioObjectPropertySelector sel, AudioObjectPropertyScope scope) {
    const AudioObjectPropertyAddress a = { sel, scope, kAudioObjectPropertyElementMain };
    return (*gDrv)->HasProperty(gDrv, obj, getpid(), &a);
}

static bool Settable(AudioObjectID obj, AudioObjectPropertySelector sel) {
    const AudioObjectPropertyAddress a = { sel, kGlobal, kAudioObjectPropertyElementMain };
    Boolean s = false;
    return (*gDrv)->IsPropertySettable(gDrv, obj, getpid(), &a, &s) == kAudioHardwareNoError && s;
}

static UInt32 U32(AudioObjectID obj, AudioObjectPropertySelector sel, AudioObjectPropertyScope scope) {
    UInt32 v = 0xDEADBEEF, size = 0;
    if (GetData(obj, sel, scope, 0, NULL, sizeof v, &v, &size) != kAudioHardwareNoError || size != sizeof v) return 0xDEADBEEF;
    return v;
}

static Float64 F64(AudioObjectID obj, AudioObjectPropertySelector sel, AudioObjectPropertyScope scope) {
    Float64 v = NAN;
    UInt32 size = 0;
    if (GetData(obj, sel, scope, 0, NULL, sizeof v, &v, &size) != kAudioHardwareNoError || size != sizeof v) return NAN;
    return v;
}

static Float32 F32(AudioObjectID obj, AudioObjectPropertySelector sel) {
    Float32 v = NAN;
    UInt32 size = 0;
    if (GetData(obj, sel, kGlobal, 0, NULL, sizeof v, &v, &size) != kAudioHardwareNoError || size != sizeof v) return NAN;
    return v;
}

/// Uses an in/out conversion property (value in, converted value out).
static Float32 Convert(AudioObjectID obj, AudioObjectPropertySelector sel, Float32 in) {
    Float32 v = in;
    UInt32 size = 0;
    if (GetData(obj, sel, kGlobal, 0, NULL, sizeof v, &v, &size) != kAudioHardwareNoError) return NAN;
    return v;
}

static bool StringIs(AudioObjectID obj, AudioObjectPropertySelector sel, const char *expected) {
    CFStringRef s = NULL;
    UInt32 size = 0;
    if (GetData(obj, sel, kGlobal, 0, NULL, sizeof s, &s, &size) != kAudioHardwareNoError || s == NULL) return false;
    CFStringRef want = CFStringCreateWithCString(NULL, expected, kCFStringEncodingUTF8);
    const bool eq = CFGetTypeID(s) == CFStringGetTypeID() && CFStringCompare(s, want, 0) == kCFCompareEqualTo;
    CFRelease(want);
    CFRelease(s);
    return eq;
}

/// Reads an AudioObjectID list; returns the count (or -1 on error).
static int IDs(AudioObjectID obj, AudioObjectPropertySelector sel, AudioObjectPropertyScope scope,
               UInt32 qualifierSize, const void *qualifier, AudioObjectID *out, int max) {
    UInt32 size = 0;
    if (GetData(obj, sel, scope, qualifierSize, qualifier, (UInt32)max * sizeof(AudioObjectID), out, &size) != kAudioHardwareNoError) return -1;
    return (int)(size / sizeof(AudioObjectID));
}

static OSStatus SetData(AudioObjectID obj, AudioObjectPropertySelector sel, AudioObjectPropertyScope scope,
                        UInt32 size, const void *data) {
    const AudioObjectPropertyAddress a = { sel, scope, kAudioObjectPropertyElementMain };
    return (*gDrv)->SetPropertyData(gDrv, obj, getpid(), &a, 0, NULL, size, data);
}
static OSStatus SetU32(AudioObjectID obj, AudioObjectPropertySelector sel, UInt32 v) { return SetData(obj, sel, kGlobal, sizeof v, &v); }
static OSStatus SetF32(AudioObjectID obj, AudioObjectPropertySelector sel, Float32 v) { return SetData(obj, sel, kGlobal, sizeof v, &v); }
static OSStatus SetF64(AudioObjectID obj, AudioObjectPropertySelector sel, Float64 v) { return SetData(obj, sel, kGlobal, sizeof v, &v); }

static OSStatus SetLatencyPlist(AudioObjectID dev, CFPropertyListRef value) {
    return SetData(dev, EQT_PROPERTY_CLIENT_LATENCY, kGlobal, sizeof value, &value);
}
static OSStatus SetLatencyNumber(AudioObjectID dev, CFNumberType type, const void *value) {
    CFNumberRef n = CFNumberCreate(NULL, type, value);
    const OSStatus err = SetLatencyPlist(dev, n);
    CFRelease(n);
    return err;
}
/// Sets 'eqta' (a CFNumber) on behalf of process `pid`.
static OSStatus SetReadersAs(AudioObjectID dev, pid_t pid, double value) {
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberFloat64Type, &value);
    const AudioObjectPropertyAddress a = { EQT_PROPERTY_READER_ATTACHED, kGlobal, kAudioObjectPropertyElementMain };
    CFPropertyListRef plist = n;
    const OSStatus err = (*gDrv)->SetPropertyData(gDrv, dev, pid, &a, 0, NULL, sizeof plist, &plist);
    CFRelease(n);
    return err;
}

/// Reads 'eqta' (attached reader processes), or -1 if the property is broken.
static long GetReaders(AudioObjectID dev) {
    CFPropertyListRef v = NULL;
    UInt32 size = 0;
    if (GetData(dev, EQT_PROPERTY_READER_ATTACHED, kGlobal, 0, NULL, sizeof v, &v, &size) != kAudioHardwareNoError
        || size != sizeof v || v == NULL) return -1;
    long n = -1;
    if (CFGetTypeID(v) == CFNumberGetTypeID()) {
        SInt64 x = 0;
        if (CFNumberGetValue((CFNumberRef)v, kCFNumberSInt64Type, &x)) n = (long)x;
    }
    CFRelease(v);
    return n;
}

static bool WaitReaders(AudioObjectID dev, long want, double timeout) {
    const uint64_t t0 = mach_absolute_time();
    while (GetReaders(dev) != want) {
        if (SecondsSince(t0) > timeout) return false;
        SleepMs(5);
    }
    return true;
}

static pid_t SpawnChild(const char *path, char *const argv[]) {
    pid_t pid = 0;
    return posix_spawn(&pid, path, NULL, NULL, argv, environ) == 0 ? pid : -1;
}

/// Returns the 'eqtl' value in frames, or -1 if the property is broken.
static long GetLatencyPlist(AudioObjectID dev) {
    CFPropertyListRef v = NULL;
    UInt32 size = 0;
    if (GetData(dev, EQT_PROPERTY_CLIENT_LATENCY, kGlobal, 0, NULL, sizeof v, &v, &size) != kAudioHardwareNoError
        || size != sizeof v || v == NULL) return -1;
    long frames = -1;
    if (CFGetTypeID(v) == CFNumberGetTypeID()) {
        SInt64 x = 0;
        if (CFNumberGetValue((CFNumberRef)v, kCFNumberSInt64Type, &x)) frames = (long)x;
    }
    CFRelease(v);
    return frames;
}

// ================================================================ driver loading

typedef void *(*FactoryFn)(CFAllocatorRef, CFUUIDRef);

static bool ResolveDriverPath(const char *arg, char *out, size_t outSize) {
    char candidate[PATH_MAX];
    if (arg != NULL) {
        struct stat st;
        if (stat(arg, &st) == 0 && S_ISDIR(st.st_mode)) {
            snprintf(candidate, sizeof candidate, "%s/Contents/MacOS/EQtargetsAudio", arg);
        } else {
            snprintf(candidate, sizeof candidate, "%s", arg);
        }
    } else {
        char exe[PATH_MAX];
        uint32_t size = sizeof exe;
        char real[PATH_MAX];
        if (_NSGetExecutablePath(exe, &size) != 0 || realpath(exe, real) == NULL) return false;
        snprintf(candidate, sizeof candidate, "%s/EQtargetsAudio.driver/Contents/MacOS/EQtargetsAudio", dirname(real));
    }
    if (realpath(candidate, out) == NULL) {
        snprintf(out, outSize, "%s", candidate);
        return false;
    }
    return true;
}

/// dlopen + factory + QueryInterface. Sets gDrv. Returns false (after FAILs) if unusable.
static bool LoadDriver(const char *path, bool verbose) {
    void *handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    check(handle != NULL, "dlopen built driver %s%s%s", path, handle ? "" : ": ", handle ? "" : dlerror());
    if (handle == NULL) return false;
    FactoryFn factory = (FactoryFn)dlsym(handle, "EQTargets_Create");
    check(factory != NULL, "factory EQTargets_Create is exported (name from Info.plist CFPlugInFactories)");
    if (factory == NULL) return false;

    if (verbose) {
        CFUUIDRef bogus = CFUUIDCreateFromString(NULL, CFSTR("01234567-89AB-CDEF-0123-456789ABCDEF"));
        check(factory(NULL, bogus) == NULL, "factory refuses a non-AudioServerPlugIn type UUID");
        CFRelease(bogus);
    }
    void *obj = factory(NULL, kAudioServerPlugInTypeUUID);
    check(obj != NULL, "factory returns an object for kAudioServerPlugInTypeUUID");
    if (obj == NULL) return false;

    AudioServerPlugInDriverInterface **iunknown = (AudioServerPlugInDriverInterface **)obj;
    void *iface = NULL;
    HRESULT hr = (*iunknown)->QueryInterface(iunknown, CFUUIDGetUUIDBytes(kAudioServerPlugInDriverInterfaceUUID), &iface);
    check(hr == S_OK && iface != NULL, "QueryInterface(kAudioServerPlugInDriverInterfaceUUID) -> S_OK");
    if (hr != S_OK || iface == NULL) return false;
    gDrv = (AudioServerPlugInDriverRef)iface;

    if (verbose) {
        void *viaUnknown = NULL;
        hr = (*gDrv)->QueryInterface(gDrv, CFUUIDGetUUIDBytes(IUnknownUUID), &viaUnknown);
        check(hr == S_OK && viaUnknown == iface, "QueryInterface(IUnknownUUID) -> same object");
        CFUUIDRef bogus = CFUUIDCreateFromString(NULL, CFSTR("01234567-89AB-CDEF-0123-456789ABCDEF"));
        void *none = (void *)1;
        hr = (*gDrv)->QueryInterface(gDrv, CFUUIDGetUUIDBytes(bogus), &none);
        CFRelease(bogus);
        check(hr == E_NOINTERFACE && none == NULL, "QueryInterface(unknown UUID) -> E_NOINTERFACE, NULL out");
        const ULONG afterAdd = (*gDrv)->AddRef(gDrv);
        const ULONG afterRelease = (*gDrv)->Release(gDrv);
        check(afterAdd == afterRelease + 1, "AddRef/Release balance (%lu -> %lu)", (unsigned long)afterAdd, (unsigned long)afterRelease);
        (*gDrv)->Release(gDrv);   // drop the IUnknown reference taken above
    }
    return true;
}

// ================================================================ ring (read side, exactly like the app)

static const EQTRingHeader *gRO;

static const EQTRingHeader *MapRingReadOnly(const char *name, struct stat *outStat) {
    const int fd = shm_open(name, O_RDONLY);
    if (fd < 0) return NULL;
    if (outStat != NULL && fstat(fd, outStat) != 0) memset(outStat, 0, sizeof *outStat);
    void *p = mmap(NULL, EQT_RING_TOTAL_BYTES, PROT_READ, MAP_SHARED, fd, 0);
    close(fd);
    return p == MAP_FAILED ? NULL : (const EQTRingHeader *)p;
}

static uint64_t RingCycles(void)   { return __atomic_load_n(&gRO->writeCycles, __ATOMIC_RELAXED); }
static uint64_t RingZeroed(void)   { return __atomic_load_n(&gRO->zeroFilledFrames, __ATOMIC_RELAXED); }

/// Copies frames [from, from+count) out of the ring. False if any of them is
/// not readable under the protocol (at/above writeHead or > capacity behind it).
static bool RingRead(int64_t from, int64_t count, float *dst) {
    const int64_t head = EQTRingLoadWriteHead(gRO);
    if (from < 0 || from < head - kRingCap || from + count > head) return false;
    const float *s = EQTRingSamplesConst(gRO);
    for (int64_t i = 0; i < count; i++) {
        const int64_t slot = (from + i) & kRingMask;
        dst[i * kCh] = s[slot * kCh];
        dst[i * kCh + 1] = s[slot * kCh + 1];
    }
    return true;
}

// ================================================================ test signal

/// Deterministic, bit-exactly reproducible test frame for absolute frame `f`.
/// seed 0 = digital silence. L is full-scale pseudo-noise with a −0.0f and a
/// denormal sprinkled in (any float conversion or arithmetic on the path would
/// change those bits); R is a 1 kHz tone.
static void ExpectedFrame(int64_t f, uint32_t seed, float out[2]) {
    if (seed == 0) { out[0] = 0.0f; out[1] = 0.0f; return; }
    uint64_t x = (uint64_t)f * 0x9E3779B97F4A7C15ull + (uint64_t)seed * 0xD1B54A32D192ED03ull;
    x ^= x >> 29; x *= 0xBF58476D1CE4E5B9ull; x ^= x >> 32;
    float left = (float)((int32_t)(x & 0xFFFFFFu) - 0x800000) / 8388608.0f;
    if (f % 997 == 0) left = -0.0f;
    if (f % 991 == 0) left = 1.0e-40f;   // subnormal
    out[0] = left;
    out[1] = (float)(0.5 * sin(2.0 * M_PI * (double)((f % 48 + 48) % 48) / 48.0)) * (seed == 1 ? 1.0f : -1.0f);
}

/// Number of frames in [from, from+count) that differ (memcmp, i.e. bit-exact)
/// from ExpectedFrame(seed); -1 if the range is not readable.
static int64_t Mismatches(int64_t from, int64_t count, uint32_t seed) {
    float *got = malloc((size_t)(count * kCh) * sizeof(float));
    if (got == NULL || !RingRead(from, count, got)) { free(got); return -1; }
    int64_t bad = 0;
    for (int64_t i = 0; i < count; i++) {
        float want[2];
        ExpectedFrame(from + i, seed, want);
        if (memcmp(want, &got[i * kCh], sizeof want) != 0) bad++;
    }
    free(got);
    return bad;
}

// ================================================================ IO simulation

static float gIOBuffer[2 * 8192];
static uint64_t gCycleCounter;

/// One HAL IO cycle that writes `frames` frames of ExpectedFrame(seed) whose
/// first frame is absolute frame `firstFrame`, announced to the driver with
/// output sample time `sampleTime`.
static OSStatus IOCycle(AudioObjectID dev, AudioObjectID stream, double sampleTime, int64_t firstFrame,
                        uint32_t frames, uint32_t seed) {
    for (uint32_t i = 0; i < frames; i++) ExpectedFrame(firstFrame + (int64_t)i, seed, &gIOBuffer[i * 2]);
    AudioServerPlugInIOCycleInfo info;
    memset(&info, 0, sizeof info);
    info.mIOCycleCounter = ++gCycleCounter;
    info.mNominalIOBufferFrameSize = frames;
    info.mOutputTime.mSampleTime = sampleTime;
    info.mOutputTime.mHostTime = mach_absolute_time();
    info.mOutputTime.mFlags = kAudioTimeStampSampleHostTimeValid;
    info.mCurrentTime = info.mOutputTime;
    const UInt32 client = 1;
    (*gDrv)->BeginIOOperation(gDrv, dev, client, kAudioServerPlugInIOOperationCycle, frames, &info);
    (*gDrv)->BeginIOOperation(gDrv, dev, client, kAudioServerPlugInIOOperationWriteMix, frames, &info);
    const OSStatus err = (*gDrv)->DoIOOperation(gDrv, dev, stream, client, kAudioServerPlugInIOOperationWriteMix,
                                                frames, &info, gIOBuffer, NULL);
    (*gDrv)->EndIOOperation(gDrv, dev, client, kAudioServerPlugInIOOperationWriteMix, frames, &info);
    (*gDrv)->EndIOOperation(gDrv, dev, client, kAudioServerPlugInIOOperationCycle, frames, &info);
    return err;
}

/// Polls GetZeroTimeStamp for `seconds` and checks the anchors are monotonic,
/// exactly one period apart in sample time and period·ticksPerFrame apart in
/// host time, never in the future, and never stale by more than a period.
static void CheckZeroTimeStamps(AudioObjectID dev, double rate, double seconds, uint64_t seedBeforeStart) {
    const double ticksPerFrame = gTicksPerSecond / rate;
    const double periodTicks = ticksPerFrame * kContractPeriod;
    enum { kMax = 64 };
    Float64 st[kMax]; UInt64 ht[kMax]; UInt64 seed[kMax]; uint64_t seenAt[kMax];
    int n = 0;
    bool allOK = true, inFuture = false, stale = false;
    const uint64_t t0 = mach_absolute_time();
    while (SecondsSince(t0) < seconds) {
        Float64 s = 0; UInt64 h = 0, sd = 0;
        if ((*gDrv)->GetZeroTimeStamp(gDrv, dev, 1, &s, &h, &sd) != kAudioHardwareNoError) { allOK = false; break; }
        const uint64_t now = mach_absolute_time();
        if (h > now) inFuture = true;
        if ((double)(now - h) > periodTicks + 0.020 * gTicksPerSecond) stale = true;
        if ((n == 0 || s != st[n - 1]) && n < kMax) { st[n] = s; ht[n] = h; seed[n] = sd; seenAt[n] = now; n++; }
        SleepMs(2);
    }
    (void)seenAt;
    check(allOK, "GetZeroTimeStamp returns noErr @ %.0f Hz", rate);
    const int expectAtLeast = (int)(seconds * rate / kContractPeriod);
    check(n >= expectAtLeast && n >= 3, "zero timestamps advance with time: %d anchors in %.2f s (expected >= %d)", n, seconds, expectAtLeast);
    bool periodOK = n > 0 && fmod(st[0], kContractPeriod) == 0.0, hostOK = true, seedOK = true, monoOK = true;
    double worstTickErr = 0.0;
    for (int i = 1; i < n; i++) {
        if (st[i] - st[i - 1] != (double)kContractPeriod) periodOK = false;
        if (ht[i] <= ht[i - 1]) monoOK = false;
        const double err = fabs((double)(ht[i] - ht[i - 1]) - periodTicks);
        if (err > worstTickErr) worstTickErr = err;
        if (err > 1.0) hostOK = false;
        if (seed[i] != seed[0]) seedOK = false;
    }
    check(monoOK, "zero timestamps strictly monotonic (sample and host time)");
    check(periodOK, "successive sample times exactly %u frames apart", kContractPeriod);
    check(hostOK, "successive host times %u x %.4f ticks/frame apart (worst error %.2f ticks)",
          kContractPeriod, ticksPerFrame, worstTickErr);
    check(!inFuture, "no zero timestamp lies in the future");
    check(!stale, "no zero timestamp older than one period (+20 ms poll slack)");
    check(seedOK && n > 0 && seed[0] != seedBeforeStart, "seed constant while running and changed by the re-anchor (%llu -> %llu)",
          (unsigned long long)seedBeforeStart, n > 0 ? (unsigned long long)seed[0] : 0ull);
}

static uint64_t CurrentSeed(AudioObjectID dev) {
    Float64 s; UInt64 h, sd = 0;
    (*gDrv)->GetZeroTimeStamp(gDrv, dev, 1, &s, &h, &sd);
    return sd;
}

// ================================================================ reattach child (simulated coreaudiod restart)

static int RunReattachChild(const char *driverPath, const char *ringName, uint64_t minGeneration, uint64_t parentLoadTime) {
    gPrefix = "  [reattach] ";
    setenv("EQT_RING_NAME_OVERRIDE", ringName, 1);
    ResetHostStorage();
    if (!LoadDriver(driverPath, false)) return 1;
    check((*gDrv)->Initialize(gDrv, &gHostInterface) == kAudioHardwareNoError, "Initialize against the existing ring");
    gRO = MapRingReadOnly(ringName, NULL);
    check(gRO != NULL, "ring still mappable read-only");
    if (gRO == NULL) return 1;
    check(EQTRingHeaderIsValid(gRO), "header valid after re-attach");
    const uint64_t gen = EQTRingLoadGeneration(gRO);
    check(gen > minGeneration, "generation keeps counting across a restart (%llu > %llu) so readers resync",
          (unsigned long long)gen, (unsigned long long)minGeneration);
    check(EQTRingLoadWriteHead(gRO) == 0 && EQTRingLoadIORunning(gRO) == 0, "writeHead 0, ioRunning 0 after re-attach");
    check(RingCycles() == 0 && RingZeroed() == 0, "diagnostic counters reset for the new driver instance");
    check(__atomic_load_n(&gRO->driverLoadHostTime, __ATOMIC_RELAXED) > parentLoadTime, "driverLoadHostTime advanced");
    check(EQTRingLoadSampleRate(gRO) == 48000.0, "fresh instance publishes its default rate 48000");
    AudioObjectID ids[4];
    const AudioObjectID dev = IDs(kAudioObjectPlugInObject, kAudioPlugInPropertyDeviceList, kGlobal, 0, NULL, ids, 4) == 1 ? ids[0] : 0;
    check(dev != 0 && U32(dev, kAudioDevicePropertyIsHidden, kGlobal) == 0 && GetReaders(dev) == 0,
          "fresh instance (coreaudiod restart): no readers, visible until an app manages it again");
    return gFail == 0 ? 0 : 1;
}

// ================================================================ serve mode (known source for eqt-probe --ring)

static int RunServe(const char *driverPath, double seconds, double ppm) {
    const char *ring = getenv("EQT_RING_NAME_OVERRIDE");
    if (ring == NULL || ring[0] == '\0') {
        fprintf(stderr, "--serve needs EQT_RING_NAME_OVERRIDE (it never writes the production ring)\n");
        return 2;
    }
    ResetHostStorage();
    if (!LoadDriver(driverPath, false)) return 1;
    if ((*gDrv)->Initialize(gDrv, &gHostInterface) != kAudioHardwareNoError) return 1;
    AudioObjectID dev = 0, stream = 0;
    IDs(kAudioObjectPlugInObject, kAudioPlugInPropertyDeviceList, kGlobal, 0, NULL, &dev, 1);
    IDs(dev, kAudioDevicePropertyStreams, kOut, 0, NULL, &stream, 1);
    if ((*gDrv)->StartIO(gDrv, dev, 1) != kAudioHardwareNoError) return 1;

    const double rate = 48000.0;
    // A writer that is `ppm` fast spends fewer host ticks per frame.
    const double ticksPerFrame = gTicksPerSecond / rate / (1.0 + ppm * 1.0e-6);
    const uint32_t N = 512;
    const int64_t lead = 512;   // HAL output time runs ahead of "now"
    const uint64_t start = mach_absolute_time();
    uint64_t cycles = 0;
    printf("serving 1 kHz @ -20 dBFS into %s for %.1f s (writer %+.0f ppm vs nominal 48000)\n", ring, seconds, ppm);
    fflush(stdout);
    for (uint64_t k = 0;; k++) {
        const uint64_t due = start + (uint64_t)((double)((k + 1) * N) * ticksPerFrame);
        if ((double)(due - start) / gTicksPerSecond > seconds) break;
        mach_wait_until(due);
        const int64_t first = (int64_t)(k * N) + lead;
        for (uint32_t i = 0; i < N; i++) {
            const float v = (float)(0.1 * sin(2.0 * M_PI * 1000.0 * (double)(first + (int64_t)i) / rate));
            gIOBuffer[2 * i] = v;
            gIOBuffer[2 * i + 1] = v;
        }
        AudioServerPlugInIOCycleInfo info;
        memset(&info, 0, sizeof info);
        info.mIOCycleCounter = k + 1;
        info.mNominalIOBufferFrameSize = N;
        info.mOutputTime.mSampleTime = (Float64)first;
        info.mOutputTime.mFlags = kAudioTimeStampSampleHostTimeValid;
        (*gDrv)->DoIOOperation(gDrv, dev, stream, 1, kAudioServerPlugInIOOperationWriteMix, N, &info, gIOBuffer, NULL);
        cycles++;
    }
    (*gDrv)->StopIO(gDrv, dev, 1);
    shm_unlink(ring);
    printf("served %llu cycles (%llu frames); ring unlinked\n", (unsigned long long)cycles, (unsigned long long)(cycles * N));
    return 0;
}

// ================================================================ the suite

static int RunSuite(const char *driverPath) {
    char ringName[32];
    snprintf(ringName, sizeof ringName, "/eqt.harness.%d", (int)getpid());   // < PSHMNAMLEN (31)
    shm_unlink(ringName);

    section("load");
    printf("driver: %s\nring:   %s (private override)\n", driverPath, ringName);
    if (!LoadDriver(driverPath, true)) return 1;

    // A stale object of the WRONG size must be replaced (ftruncate can't resize on macOS).
    {
        const int fd = shm_open(ringName, O_CREAT | O_RDWR, 0600);
        const bool made = fd >= 0 && ftruncate(fd, 4096) == 0;
        if (fd >= 0) close(fd);
        check(made, "pre-created a stale 4096-byte ring object to exercise the recreate path");
    }
    setenv("EQT_RING_NAME_OVERRIDE", ringName, 1);

    // Persisted state from a "previous coreaudiod session".
    ResetHostStorage();
    {
        const double v = 0.3;
        CFNumberRef n = CFNumberCreate(NULL, kCFNumberFloat64Type, &v);
        CFDictionarySetValue(gStorage, CFSTR("output.volume.scalar"), n);
        CFRelease(n);
        CFDictionarySetValue(gStorage, CFSTR("output.mute"), kCFBooleanTrue);
    }

    section("initialize + shared memory");
    const uint64_t beforeInit = mach_absolute_time();
    check((*gDrv)->Initialize(gDrv, &gHostInterface) == kAudioHardwareNoError, "Initialize with fake host");
    check((*gDrv)->Initialize(gDrv, &gHostInterface) == kAudioHardwareIllegalOperationError, "second Initialize refused");

    struct stat st;
    gRO = MapRingReadOnly(ringName, &st);
    check(gRO != NULL, "app-style open: shm_open(O_RDONLY) + mmap(PROT_READ, MAP_SHARED)");
    if (gRO == NULL) { shm_unlink(ringName); return 1; }
    // macOS reports shm sizes rounded up to the VM page (16 KB on Apple silicon).
    const off_t page = (off_t)sysconf(_SC_PAGESIZE);
    const off_t roundedTotal = ((off_t)EQT_RING_TOTAL_BYTES + page - 1) / page * page;
    check(st.st_size == (off_t)EQT_RING_TOTAL_BYTES || st.st_size == roundedTotal,
          "stale ring replaced: size %lld = EQT_RING_TOTAL_BYTES %u rounded to the %lld-byte page",
          (long long)st.st_size, (unsigned)EQT_RING_TOTAL_BYTES, (long long)page);
    check((st.st_mode & 0777) == 0644, "ring mode is 0644 (fchmod defeats umask): %o", (unsigned)(st.st_mode & 0777));
    check(EQTRingHeaderIsValid(gRO), "EQTRingHeaderIsValid: magic/version/channels/capacity/headerBytes");
    check(EQTRingLoadSampleRate(gRO) == 48000.0, "header rate 48000");
    check(EQTRingLoadWriteHead(gRO) == 0 && EQTRingLoadIORunning(gRO) == 0, "idle: writeHead 0, ioRunning 0");
    const uint64_t load = __atomic_load_n(&gRO->driverLoadHostTime, __ATOMIC_RELAXED);
    check(load >= beforeInit && load <= mach_absolute_time(), "driverLoadHostTime stamped during Initialize");
    const uint64_t genAtInit = EQTRingLoadGeneration(gRO);
    check(genAtInit >= 1, "generation bumped on attach (%llu)", (unsigned long long)genAtInit);

    // ------------------------------------------------------------------ object tree
    section("object tree + class IDs");
    AudioObjectID ids[16];
    const AudioObjectID plugin = kAudioObjectPlugInObject;
    check(U32(plugin, kAudioObjectPropertyClass, kGlobal) == kAudioPlugInClassID, "plug-in class kAudioPlugInClassID");
    check(U32(plugin, kAudioObjectPropertyBaseClass, kGlobal) == kAudioObjectClassID, "plug-in base class kAudioObjectClassID");
    check(U32(plugin, kAudioObjectPropertyOwner, kGlobal) == kAudioObjectUnknown, "plug-in owner unknown");
    check(StringIs(plugin, kAudioObjectPropertyManufacturer, EQT_DEVICE_MANUFACTURER), "plug-in manufacturer");
    check(StringIs(plugin, kAudioPlugInPropertyResourceBundle, ""), "plug-in resource bundle \"\" (own bundle)");
    int n = IDs(plugin, kAudioPlugInPropertyDeviceList, kGlobal, 0, NULL, ids, 16);
    check(n == 1, "plug-in DeviceList has exactly one device");
    const AudioObjectID dev = n == 1 ? ids[0] : 0;
    n = IDs(plugin, kAudioPlugInPropertyBoxList, kGlobal, 0, NULL, ids, 16);
    check(n == 1, "plug-in BoxList has exactly one box");
    const AudioObjectID box = n == 1 ? ids[0] : 0;
    n = IDs(plugin, kAudioObjectPropertyOwnedObjects, kGlobal, 0, NULL, ids, 16);
    check(n == 2 && ((ids[0] == box && ids[1] == dev) || (ids[0] == dev && ids[1] == box)), "plug-in owns {box, device}");
    {
        const AudioClassID devClass = kAudioDeviceClassID;
        n = IDs(plugin, kAudioObjectPropertyOwnedObjects, kGlobal, sizeof devClass, &devClass, ids, 16);
        check(n == 1 && ids[0] == dev, "OwnedObjects qualifier {kAudioDeviceClassID} filters to the device");
        CFStringRef uid = CFSTR(EQT_DEVICE_UID);
        AudioObjectID found = 0;
        UInt32 size = 0;
        GetData(plugin, kAudioPlugInPropertyTranslateUIDToDevice, kGlobal, sizeof uid, &uid, sizeof found, &found, &size);
        check(found == dev, "TranslateUIDToDevice(\"%s\") -> device", EQT_DEVICE_UID);
        uid = CFSTR("com.example.nope");
        GetData(plugin, kAudioPlugInPropertyTranslateUIDToDevice, kGlobal, sizeof uid, &uid, sizeof found, &found, &size);
        check(found == kAudioObjectUnknown, "TranslateUIDToDevice(unknown) -> kAudioObjectUnknown");
        CFNumberRef notAString = CFNumberCreate(NULL, kCFNumberSInt32Type, &(int){ 7 });
        found = 99;
        GetData(plugin, kAudioPlugInPropertyTranslateUIDToDevice, kGlobal, sizeof notAString, &notAString, sizeof found, &found, &size);
        CFRelease(notAString);
        check(found == kAudioObjectUnknown, "TranslateUIDToDevice(non-string qualifier) -> unknown, no crash");
        check(GetData(plugin, kAudioPlugInPropertyTranslateUIDToDevice, kGlobal, 2, &uid, sizeof found, &found, &size)
                  == kAudioHardwareBadPropertySizeError, "TranslateUIDToDevice(bad qualifier size) -> BadPropertySize");
        uid = CFSTR(kContractBoxUID);
        GetData(plugin, kAudioPlugInPropertyTranslateUIDToBox, kGlobal, sizeof uid, &uid, sizeof found, &found, &size);
        check(found == box, "TranslateUIDToBox -> box");
    }
    check(U32(box, kAudioObjectPropertyClass, kGlobal) == kAudioBoxClassID, "box class kAudioBoxClassID");
    check(U32(box, kAudioObjectPropertyOwner, kGlobal) == plugin, "box owner = plug-in");
    check(StringIs(box, kAudioBoxPropertyBoxUID, kContractBoxUID), "box UID");
    check(U32(box, kAudioBoxPropertyAcquired, kGlobal) == 1, "box acquired");
    n = IDs(box, kAudioBoxPropertyDeviceList, kGlobal, 0, NULL, ids, 16);
    check(n == 1 && ids[0] == dev, "box DeviceList = {device}");
    check(U32(dev, kAudioObjectPropertyClass, kGlobal) == kAudioDeviceClassID, "device class kAudioDeviceClassID");
    check(U32(dev, kAudioObjectPropertyBaseClass, kGlobal) == kAudioObjectClassID, "device base class kAudioObjectClassID");
    check(U32(dev, kAudioObjectPropertyOwner, kGlobal) == plugin, "device owner = plug-in");

    n = IDs(dev, kAudioDevicePropertyStreams, kOut, 0, NULL, ids, 16);
    check(n == 1, "device has exactly one OUTPUT stream");
    const AudioObjectID stream = n == 1 ? ids[0] : 0;
    check(U32(stream, kAudioObjectPropertyClass, kGlobal) == kAudioStreamClassID, "stream class kAudioStreamClassID");
    check(U32(stream, kAudioObjectPropertyOwner, kGlobal) == dev, "stream owner = device");

    n = IDs(dev, kAudioObjectPropertyControlList, kGlobal, 0, NULL, ids, 16);
    check(n == 2, "device has exactly two controls");
    AudioObjectID volume = 0, mute = 0;
    for (int i = 0; i < n; i++) {
        const UInt32 cls = U32(ids[i], kAudioObjectPropertyClass, kGlobal);
        if (cls == kAudioVolumeControlClassID) volume = ids[i];
        if (cls == kAudioMuteControlClassID) mute = ids[i];
    }
    check(volume != 0 && U32(volume, kAudioObjectPropertyBaseClass, kGlobal) == kAudioLevelControlClassID,
          "volume control: class kAudioVolumeControlClassID, base kAudioLevelControlClassID");
    check(mute != 0 && U32(mute, kAudioObjectPropertyBaseClass, kGlobal) == kAudioBooleanControlClassID,
          "mute control: class kAudioMuteControlClassID, base kAudioBooleanControlClassID");
    check(U32(volume, kAudioObjectPropertyOwner, kGlobal) == dev && U32(mute, kAudioObjectPropertyOwner, kGlobal) == dev,
          "controls owned by the device");
    check(U32(volume, kAudioControlPropertyElement, kGlobal) == kAudioObjectPropertyElementMain
              && U32(mute, kAudioControlPropertyElement, kGlobal) == kAudioObjectPropertyElementMain,
          "controls are on the main element (master)");
    {
        const AudioClassID ctl = kAudioControlClassID;
        n = IDs(dev, kAudioObjectPropertyOwnedObjects, kGlobal, sizeof ctl, &ctl, ids, 16);
        check(n == 2, "device OwnedObjects qualifier {kAudioControlClassID} -> both controls");
        const AudioClassID vol = kAudioVolumeControlClassID;
        n = IDs(dev, kAudioObjectPropertyOwnedObjects, kGlobal, sizeof vol, &vol, ids, 16);
        check(n == 1 && ids[0] == volume, "device OwnedObjects qualifier {kAudioVolumeControlClassID} -> volume only");
        n = IDs(dev, kAudioObjectPropertyOwnedObjects, kGlobal, 0, NULL, ids, 1);
        check(n == 1, "partial list fetch (room for 1 of 3) returns 1 whole item");
    }

    // ------------------------------------------------------------------ device identity
    section("device identity + clock");
    check(StringIs(dev, kAudioObjectPropertyName, EQT_DEVICE_NAME), "name \"%s\"", EQT_DEVICE_NAME);
    check(StringIs(dev, kAudioObjectPropertyManufacturer, EQT_DEVICE_MANUFACTURER), "manufacturer \"%s\"", EQT_DEVICE_MANUFACTURER);
    check(StringIs(dev, kAudioDevicePropertyDeviceUID, EQT_DEVICE_UID), "UID \"%s\"", EQT_DEVICE_UID);
    check(StringIs(dev, kAudioDevicePropertyModelUID, EQT_DEVICE_MODEL_UID), "model UID \"%s\"", EQT_DEVICE_MODEL_UID);
    check(U32(dev, kAudioDevicePropertyTransportType, kGlobal) == kAudioDeviceTransportTypeVirtual, "transport virtual");
    check(U32(dev, kAudioDevicePropertyDeviceCanBeDefaultDevice, kOut) == 1, "can be default OUTPUT device");
    check(U32(dev, kAudioDevicePropertyDeviceCanBeDefaultSystemDevice, kOut) == 0, "cannot be default SYSTEM (alert) device");
    check(U32(dev, kAudioDevicePropertyIsHidden, kGlobal) == 0, "not hidden");
    check(U32(dev, kAudioDevicePropertyDeviceIsAlive, kGlobal) == 1, "alive");
    check(U32(dev, kAudioDevicePropertyDeviceIsRunning, kGlobal) == 0, "not running before StartIO");
    check(U32(dev, kAudioDevicePropertyClockDomain, kGlobal) == 0, "clock domain 0 (unspecified)");
    check(U32(dev, kAudioDevicePropertyZeroTimeStampPeriod, kGlobal) == kContractPeriod, "ZeroTimeStampPeriod %u", kContractPeriod);
    check(U32(dev, kAudioDevicePropertySafetyOffset, kOut) == 0, "safety offset 0");
    n = IDs(dev, kAudioDevicePropertyRelatedDevices, kGlobal, 0, NULL, ids, 16);
    check(n == 1 && ids[0] == dev, "related devices = {self}");
    check(!Has(dev, kAudioDevicePropertyIcon, kGlobal), "no icon property (icon: none)");
    check(Has(dev, kAudioDevicePropertyPreferredChannelsForStereo, kOut), "preferred stereo channels present (output)");
    {
        UInt32 pair[2] = { 0, 0 }, size = 0;
        GetData(dev, kAudioDevicePropertyPreferredChannelsForStereo, kOut, 0, NULL, sizeof pair, pair, &size);
        check(size == sizeof pair && pair[0] == 1 && pair[1] == 2, "preferred stereo channels = 1, 2");
        UInt32 buf[32];
        GetData(dev, kAudioDevicePropertyPreferredChannelLayout, kOut, 0, NULL, sizeof buf, buf, &size);
        const AudioChannelLayout *layout = (const AudioChannelLayout *)(const void *)buf;
        check(size >= sizeof(AudioChannelLayout) && layout->mNumberChannelDescriptions == 2
                  && layout->mChannelDescriptions[0].mChannelLabel == kAudioChannelLabel_Left
                  && layout->mChannelDescriptions[1].mChannelLabel == kAudioChannelLabel_Right,
              "preferred channel layout = L, R");
    }

    // ------------------------------------------------------------------ no input, anywhere
    section("NO INPUT (no mic permission, no orange dot)");
    {
        UInt32 size = 99;
        check(GetSize(dev, kAudioDevicePropertyStreams, kIn, &size) == kAudioHardwareNoError && size == 0,
              "Streams(input scope) size = 0");
        n = IDs(dev, kAudioDevicePropertyStreams, kIn, 0, NULL, ids, 16);
        check(n == 0, "Streams(input scope) returns zero streams");
        n = IDs(dev, kAudioDevicePropertyStreams, kAudioObjectPropertyScopePlayThrough, 0, NULL, ids, 16);
        check(n == 0, "Streams(play-through scope) returns zero streams");
        n = IDs(dev, kAudioDevicePropertyStreams, kGlobal, 0, NULL, ids, 16);
        check(n == 1 && ids[0] == stream, "Streams(global scope) = the single output stream");
        n = IDs(dev, kAudioObjectPropertyOwnedObjects, kIn, 0, NULL, ids, 16);
        check(n == 0, "OwnedObjects(input scope) is empty: no input streams, no input controls");
        bool allOutput = true;
        n = IDs(dev, kAudioObjectPropertyControlList, kGlobal, 0, NULL, ids, 16);
        for (int i = 0; i < n; i++) allOutput = allOutput && U32(ids[i], kAudioControlPropertyScope, kGlobal) == kOut;
        check(n == 2 && allOutput, "every control is output-scoped");
        n = IDs(dev, kAudioObjectPropertyOwnedObjects, kGlobal, 0, NULL, ids, 16);
        bool noInputStream = n == 3;
        for (int i = 0; i < n; i++) {
            if (U32(ids[i], kAudioObjectPropertyClass, kGlobal) == kAudioStreamClassID) {
                noInputStream = noInputStream && U32(ids[i], kAudioStreamPropertyDirection, kGlobal) == 0;
            }
        }
        check(noInputStream, "no owned stream has direction = input");
        check(U32(stream, kAudioStreamPropertyDirection, kGlobal) == 0, "stream direction 0 (output)");
        check(U32(dev, kAudioDevicePropertyDeviceCanBeDefaultDevice, kIn) == 0, "cannot be default INPUT device");
        check(!Has(dev, kAudioDevicePropertyPreferredChannelsForStereo, kIn), "no input stereo-channel pair advertised");
        check(!Has(dev, kAudioDevicePropertyPreferredChannelLayout, kIn), "no input channel layout advertised");
        check(U32(dev, kAudioDevicePropertyLatency, kIn) == 0, "input latency 0");
    }

    // ------------------------------------------------------------------ stream format
    section("output stream format");
    {
        AudioStreamBasicDescription f;
        UInt32 size = 0;
        bool ok = true;
        for (int which = 0; which < 2; which++) {
            memset(&f, 0, sizeof f);
            GetData(stream, which == 0 ? kAudioStreamPropertyVirtualFormat : kAudioStreamPropertyPhysicalFormat, kGlobal,
                    0, NULL, sizeof f, &f, &size);
            ok = ok && size == sizeof f && f.mSampleRate == 48000.0 && f.mFormatID == kAudioFormatLinearPCM
                 && f.mFormatFlags == kAudioFormatFlagsNativeFloatPacked && f.mChannelsPerFrame == 2
                 && f.mBitsPerChannel == 32 && f.mBytesPerFrame == 8 && f.mBytesPerPacket == 8 && f.mFramesPerPacket == 1;
        }
        check(ok, "virtual == physical == 48 kHz float32 native packed interleaved, 2 ch");
        AudioStreamRangedDescription formats[16];
        bool listOK = true;
        for (int which = 0; which < 2; which++) {
            GetData(stream, which == 0 ? kAudioStreamPropertyAvailableVirtualFormats : kAudioStreamPropertyAvailablePhysicalFormats,
                    kGlobal, 0, NULL, sizeof formats, formats, &size);
            listOK = listOK && size == kContractRateCount * sizeof(AudioStreamRangedDescription);
            for (UInt32 i = 0; listOK && i < kContractRateCount; i++) {
                listOK = formats[i].mFormat.mSampleRate == kContractRates[i]
                         && formats[i].mSampleRateRange.mMinimum == kContractRates[i]
                         && formats[i].mSampleRateRange.mMaximum == kContractRates[i]
                         && formats[i].mFormat.mChannelsPerFrame == 2
                         && formats[i].mFormat.mFormatFlags == kAudioFormatFlagsNativeFloatPacked;
            }
        }
        check(listOK, "available virtual/physical formats: one per supported rate");
        check(U32(stream, kAudioStreamPropertyStartingChannel, kGlobal) == 1, "starting channel 1");
        check(U32(stream, kAudioStreamPropertyTerminalType, kGlobal) == kAudioStreamTerminalTypeSpeaker, "terminal type speaker");
        check(U32(stream, kAudioStreamPropertyIsActive, kGlobal) == 1, "stream active");
        check(Settable(stream, kAudioStreamPropertyIsActive), "IsActive settable");
        const int mark = NoteMark();
        check(SetU32(stream, kAudioStreamPropertyIsActive, 0) == kAudioHardwareNoError
                  && U32(stream, kAudioStreamPropertyIsActive, kGlobal) == 0
                  && SawNote(mark, stream, kAudioStreamPropertyIsActive, kGlobal),
              "IsActive set 0 -> reads 0, PropertiesChanged sent");
        SetU32(stream, kAudioStreamPropertyIsActive, 1);
        check(U32(stream, kAudioStreamPropertyIsActive, kGlobal) == 1, "IsActive restored to 1");
    }

    // ------------------------------------------------------------------ rates
    section("sample rates");
    {
        AudioValueRange ranges[16];
        UInt32 size = 0;
        GetData(dev, kAudioDevicePropertyAvailableNominalSampleRates, kGlobal, 0, NULL, sizeof ranges, ranges, &size);
        bool ok = size == kContractRateCount * sizeof(AudioValueRange);
        for (UInt32 i = 0; ok && i < kContractRateCount; i++) {
            ok = ranges[i].mMinimum == kContractRates[i] && ranges[i].mMaximum == kContractRates[i];
        }
        check(ok, "available nominal rates = 44100 48000 88200 96000 176400 192000");
        check(F64(dev, kAudioDevicePropertyNominalSampleRate, kGlobal) == 48000.0, "default nominal rate 48000");
        check(Settable(dev, kAudioDevicePropertyNominalSampleRate), "nominal rate settable");
    }

    // ------------------------------------------------------------------ volume / mute
    section("volume + mute");
    {
        check(fabsf(F32(volume, kAudioLevelControlPropertyScalarValue) - 0.3f) < 1e-6f, "volume restored from host storage (0.3)");
        check(U32(mute, kAudioBooleanControlPropertyValue, kGlobal) == 1, "mute restored from host storage (on)");
        AudioValueRange range = { 0, 0 };
        UInt32 size = 0;
        GetData(volume, kAudioLevelControlPropertyDecibelRange, kGlobal, 0, NULL, sizeof range, &range, &size);
        check(range.mMinimum == -64.0 && range.mMaximum == 0.0, "dB range -64 .. 0");
        check(Settable(volume, kAudioLevelControlPropertyScalarValue) && Settable(volume, kAudioLevelControlPropertyDecibelValue)
                  && !Settable(volume, kAudioLevelControlPropertyDecibelRange) && Settable(mute, kAudioBooleanControlPropertyValue),
              "settable: scalar, dB, mute; not settable: dB range");

        int mark = NoteMark();
        check(SetF32(volume, kAudioLevelControlPropertyScalarValue, 0.5f) == kAudioHardwareNoError, "set scalar 0.5");
        const double dB = F32(volume, kAudioLevelControlPropertyDecibelValue);
        check(fabs(dB - RefTaperDB(0.5)) < 1e-3, "scalar 0.5 -> %.4f dB (documented cubic taper: %.4f)", dB, RefTaperDB(0.5));
        check(SawNote(mark, volume, kAudioLevelControlPropertyScalarValue, kGlobal)
                  && SawNote(mark, volume, kAudioLevelControlPropertyDecibelValue, kGlobal),
              "PropertiesChanged(scalar, dB) on change");
        mark = NoteMark();
        SetF32(volume, kAudioLevelControlPropertyScalarValue, 0.5f);
        check(NoteMark() == mark, "setting the same value sends no notification");

        SetF32(volume, kAudioLevelControlPropertyDecibelValue, -64.0f);
        check(F32(volume, kAudioLevelControlPropertyScalarValue) == 0.0f, "set -64 dB -> scalar 0");
        SetF32(volume, kAudioLevelControlPropertyDecibelValue, 0.0f);
        check(F32(volume, kAudioLevelControlPropertyScalarValue) == 1.0f, "set 0 dB -> scalar 1");
        SetF32(volume, kAudioLevelControlPropertyDecibelValue, 12.0f);
        check(F32(volume, kAudioLevelControlPropertyDecibelValue) == 0.0f, "set +12 dB clamps to 0 dB");
        SetF32(volume, kAudioLevelControlPropertyScalarValue, -1.0f);
        check(F32(volume, kAudioLevelControlPropertyScalarValue) == 0.0f, "set scalar -1 clamps to 0");
        SetF32(volume, kAudioLevelControlPropertyScalarValue, 7.0f);
        check(F32(volume, kAudioLevelControlPropertyScalarValue) == 1.0f, "set scalar 7 clamps to 1");
        check(SetF32(volume, kAudioLevelControlPropertyScalarValue, NAN) == kAudioHardwareIllegalOperationError,
              "set scalar NaN -> IllegalOperation");
        check(SetData(volume, kAudioLevelControlPropertyScalarValue, kGlobal, 2, &(UInt16){ 1 }) == kAudioHardwareBadPropertySizeError,
              "set scalar with wrong size -> BadPropertySize");
        // -inf dB is how dB-based clients (20*log10(0)) ask for silence: clamp, never refuse.
        SetF32(volume, kAudioLevelControlPropertyScalarValue, 0.5f);
        check(SetF32(volume, kAudioLevelControlPropertyDecibelValue, -INFINITY) == kAudioHardwareNoError
                  && F32(volume, kAudioLevelControlPropertyScalarValue) == 0.0f,
              "set -inf dB -> clamps to silence (scalar 0), not refused");
        check(SetF32(volume, kAudioLevelControlPropertyDecibelValue, INFINITY) == kAudioHardwareNoError
                  && F32(volume, kAudioLevelControlPropertyScalarValue) == 1.0f,
              "set +inf dB -> clamps to scalar 1");
        check(SetF32(volume, kAudioLevelControlPropertyScalarValue, -INFINITY) == kAudioHardwareNoError
                  && F32(volume, kAudioLevelControlPropertyScalarValue) == 0.0f,
              "set scalar -inf -> clamps to 0");
        check(SetF32(volume, kAudioLevelControlPropertyDecibelValue, NAN) == kAudioHardwareIllegalOperationError
                  && F32(volume, kAudioLevelControlPropertyScalarValue) == 0.0f,
              "set dB NaN -> IllegalOperation, volume unchanged");
        check(Convert(volume, kAudioLevelControlPropertyConvertDecibelsToScalar, -INFINITY) == 0.0f
                  && Convert(volume, kAudioLevelControlPropertyConvertDecibelsToScalar, INFINITY) == 1.0f,
              "convert dB->scalar: -inf -> 0, +inf -> 1");
        check(Convert(volume, kAudioLevelControlPropertyConvertScalarToDecibels, -INFINITY) == -64.0f
                  && Convert(volume, kAudioLevelControlPropertyConvertScalarToDecibels, INFINITY) == 0.0f,
              "convert scalar->dB: -inf -> -64 dB, +inf -> 0 dB");
        check(isnan(Convert(volume, kAudioLevelControlPropertyConvertDecibelsToScalar, NAN))
                  && isnan(Convert(volume, kAudioLevelControlPropertyConvertScalarToDecibels, NAN)),
              "convert NaN -> IllegalOperation (both directions)");

        // Taper: strictly monotonic, exact endpoints, matches the documented
        // formula everywhere, and the inverse round-trips.
        bool mono = true, matches = true, roundTrip = true;
        double prev = -1e9, worstFormula = 0.0, worstRT = 0.0;
        for (int i = 0; i <= 1000; i++) {
            const Float32 s = (Float32)i / 1000.0f;
            const double g = Convert(volume, kAudioLevelControlPropertyConvertScalarToDecibels, s);
            if (!(g > prev)) mono = false;
            prev = g;
            const double fe = fabs(g - RefTaperDB(s));
            if (fe > worstFormula) worstFormula = fe;
            if (fe > 1e-3) matches = false;
            const double back = Convert(volume, kAudioLevelControlPropertyConvertDecibelsToScalar, (Float32)g);
            const double re = fabs(back - s);
            if (re > worstRT) worstRT = re;
            if (re > 1e-4) roundTrip = false;
        }
        check(mono, "taper strictly increasing over 1001 scalar steps");
        check(Convert(volume, kAudioLevelControlPropertyConvertScalarToDecibels, 0.0f) == -64.0f
                  && Convert(volume, kAudioLevelControlPropertyConvertScalarToDecibels, 1.0f) == 0.0f,
              "taper endpoints exactly -64 dB / 0 dB");
        check(matches, "taper matches 60*log10(F+(1-F)s) everywhere (worst %.2e dB)", worstFormula);
        check(roundTrip, "dB->scalar inverts scalar->dB (worst %.2e)", worstRT);
        check(fabs(RefTaperDB(0.25) + 30.157) < 1e-3 && fabs(RefTaperDB(0.75) + 6.762) < 1e-3,
              "reference points: 0.25 -> -30.16 dB, 0.75 -> -6.76 dB");

        mark = NoteMark();
        check(SetU32(mute, kAudioBooleanControlPropertyValue, 0) == kAudioHardwareNoError
                  && U32(mute, kAudioBooleanControlPropertyValue, kGlobal) == 0
                  && SawNote(mark, mute, kAudioBooleanControlPropertyValue, kGlobal),
              "mute off -> reads 0, PropertiesChanged sent");
        SetU32(mute, kAudioBooleanControlPropertyValue, 7);
        check(U32(mute, kAudioBooleanControlPropertyValue, kGlobal) == 1, "mute set 7 -> normalised to 1");
        SetU32(mute, kAudioBooleanControlPropertyValue, 0);
        check(SetData(mute, kAudioBooleanControlPropertyValue, kGlobal, 1, &(UInt8){ 1 }) == kAudioHardwareBadPropertySizeError,
              "mute with wrong size -> BadPropertySize");

        SetF32(volume, kAudioLevelControlPropertyScalarValue, 0.42f);
        const uint64_t t0 = mach_absolute_time();
        double stored = -1.0;
        while (SecondsSince(t0) < 2.0 && !(StorageDouble(CFSTR("output.volume.scalar"), &stored) && fabs(stored - 0.42) < 1e-6)) SleepMs(10);
        check(fabs(stored - 0.42) < 1e-6, "volume persisted to host storage after %.0f ms (survives coreaudiod restart)",
              SecondsSince(t0) * 1000.0);
        pthread_mutex_lock(&gHostMutex);
        const CFPropertyListRef storedMute = CFDictionaryGetValue(gStorage, CFSTR("output.mute"));
        const bool muteStored = storedMute == kCFBooleanFalse;
        pthread_mutex_unlock(&gHostMutex);
        check(muteStored, "mute (off) persisted to host storage");
    }

    // ------------------------------------------------------------------ 'eqtl'
    section("'eqtl' client latency");
    {
        AudioServerPlugInCustomPropertyInfo info[4];
        UInt32 size = 0;
        GetData(dev, kAudioObjectPropertyCustomPropertyInfoList, kGlobal, 0, NULL, sizeof info, info, &size);
        check(size == 2 * sizeof(AudioServerPlugInCustomPropertyInfo) && info[0].mSelector == EQT_PROPERTY_CLIENT_LATENCY
                  && info[0].mPropertyDataType == kAudioServerPlugInCustomPropertyDataTypeCFPropertyList
                  && info[0].mQualifierDataType == kAudioServerPlugInCustomPropertyDataTypeNone
                  && info[1].mSelector == EQT_PROPERTY_READER_ATTACHED
                  && info[1].mPropertyDataType == kAudioServerPlugInCustomPropertyDataTypeCFPropertyList
                  && info[1].mQualifierDataType == kAudioServerPlugInCustomPropertyDataTypeNone,
              "CustomPropertyInfoList declares 'eqtl' and 'eqta' as CFPropertyList, no qualifier");
        check(Has(dev, EQT_PROPERTY_CLIENT_LATENCY, kGlobal) && Settable(dev, EQT_PROPERTY_CLIENT_LATENCY), "'eqtl' present and settable");
        check(GetLatencyPlist(dev) == 0 && U32(dev, kAudioDevicePropertyLatency, kOut) == 0, "initially 0 frames, latency 0");

        int mark = NoteMark();
        check(SetLatencyNumber(dev, kCFNumberSInt32Type, &(SInt32){ 1234 }) == kAudioHardwareNoError, "set 'eqtl' = 1234");
        check(GetLatencyPlist(dev) == 1234, "'eqtl' reads back 1234");
        check(U32(dev, kAudioDevicePropertyLatency, kOut) == 1234, "output latency includes it (0 + 1234)");
        check(U32(dev, kAudioDevicePropertyLatency, kIn) == 0, "input latency unaffected (0)");
        check(SawNote(mark, dev, kAudioDevicePropertyLatency, kOut) && SawNote(mark, dev, EQT_PROPERTY_CLIENT_LATENCY, kGlobal),
              "PropertiesChanged(latency output, 'eqtl')");
        mark = NoteMark();
        SetLatencyNumber(dev, kCFNumberSInt32Type, &(SInt32){ 1234 });
        check(NoteMark() == mark, "same value -> no notification");
        SetLatencyNumber(dev, kCFNumberFloat64Type, &(Float64){ 100.6 });
        check(GetLatencyPlist(dev) == 101, "fractional 100.6 rounds to 101");
        SetLatencyNumber(dev, kCFNumberFloat64Type, &(Float64){ 1.0e9 });
        check(GetLatencyPlist(dev) == kContractMaxLatency, "1e9 clamps to %u (1 s @ 192 kHz)", kContractMaxLatency);
        SetLatencyNumber(dev, kCFNumberSInt32Type, &(SInt32){ -50 });
        check(GetLatencyPlist(dev) == 0, "negative clamps to 0");
        check(SetLatencyPlist(dev, CFSTR("480")) == kAudioHardwareIllegalOperationError, "CFString value rejected");
        check(SetLatencyPlist(dev, NULL) == kAudioHardwareIllegalOperationError, "NULL value rejected");
        check(SetLatencyNumber(dev, kCFNumberFloat64Type, &(Float64){ NAN }) == kAudioHardwareIllegalOperationError, "NaN rejected");
        check(SetData(dev, EQT_PROPERTY_CLIENT_LATENCY, kGlobal, 4, &(UInt32){ 480 }) == kAudioHardwareBadPropertySizeError,
              "raw UInt32 (wrong size) rejected");
        SetLatencyNumber(dev, kCFNumberSInt32Type, &(SInt32){ 480 });
        check(U32(dev, kAudioDevicePropertyLatency, kOut) == 480, "left at 480 frames");
    }

    // ------------------------------------------------------------------ 'eqta'
    section("'eqta' ring readers: hidden while nobody plays what reaches the device");
    {
        const pid_t me = getpid();
        check(Has(dev, EQT_PROPERTY_READER_ATTACHED, kGlobal) && Settable(dev, EQT_PROPERTY_READER_ATTACHED),
              "'eqta' present and settable");
        check(GetReaders(dev) == 0 && U32(dev, kAudioDevicePropertyIsHidden, kGlobal) == 0
                  && U32(dev, kAudioDevicePropertyDeviceCanBeDefaultDevice, kOut) == 1,
              "nobody manages it yet: 0 readers, visible, can be default (old apps keep working)");

        int mark = NoteMark();
        check(SetReadersAs(dev, me, 0) == kAudioHardwareNoError, "app Off: 'eqta' = 0");
        check(U32(dev, kAudioDevicePropertyIsHidden, kGlobal) == 1 && U32(dev, kAudioDevicePropertyDeviceCanBeDefaultDevice, kOut) == 0
                  && U32(dev, kAudioDevicePropertyDeviceCanBeDefaultSystemDevice, kOut) == 0,
              "no reader -> hidden, cannot be the default output (no Sound-menu pick, no coreaudiod fallback)");
        check(SawNote(mark, dev, kAudioDevicePropertyIsHidden, kGlobal)
                  && SawNote(mark, dev, kAudioDevicePropertyDeviceCanBeDefaultDevice, kOut),
              "PropertiesChanged(IsHidden, CanBeDefaultDevice)");
        check(U32(dev, kAudioDevicePropertyDeviceCanBeDefaultDevice, kIn) == 0, "still never the default input");

        mark = NoteMark();
        check(SetReadersAs(dev, me, 1) == kAudioHardwareNoError && GetReaders(dev) == 1
                  && U32(dev, kAudioDevicePropertyIsHidden, kGlobal) == 0
                  && U32(dev, kAudioDevicePropertyDeviceCanBeDefaultDevice, kOut) == 1,
              "app routes: 'eqta' = 1 -> 1 reader, visible, can be default");
        check(SawNote(mark, dev, kAudioDevicePropertyIsHidden, kGlobal) && SawNote(mark, dev, EQT_PROPERTY_READER_ATTACHED, kGlobal),
              "PropertiesChanged(IsHidden, 'eqta')");
        mark = NoteMark();
        check(SetReadersAs(dev, me, 1) == kAudioHardwareNoError && GetReaders(dev) == 1 && NoteMark() == mark,
              "attaching twice from one process: still 1 reader, no notification");

        // A second app instance (or the CLI) that is Off must not hide the
        // device under one that is routed.
        char *sleepArgv[] = { "/bin/sleep", "30", NULL };
        const pid_t other = SpawnChild("/bin/sleep", sleepArgv);
        check(other > 0, "spawned a second reader process (pid %d)", (int)other);
        check(SetReadersAs(dev, other, 1) == kAudioHardwareNoError && GetReaders(dev) == 2, "second process attaches -> 2 readers");
        check(SetReadersAs(dev, me, 0) == kAudioHardwareNoError && GetReaders(dev) == 1
                  && U32(dev, kAudioDevicePropertyIsHidden, kGlobal) == 0,
              "first process detaches -> 1 reader left, still visible");
        check(SetReadersAs(dev, me, 0) == kAudioHardwareNoError && GetReaders(dev) == 1,
              "detaching a process that is not attached changes nothing");

        // A reader that dies (crash, kill -9) is dropped by the driver itself.
        mark = NoteMark();
        if (other > 0) { kill(other, SIGKILL); waitpid(other, NULL, 0); }
        const uint64_t t0 = mach_absolute_time();
        const bool dropped = WaitReaders(dev, 0, 3.0);
        check(dropped && U32(dev, kAudioDevicePropertyIsHidden, kGlobal) == 1 && SawNote(mark, dev, kAudioDevicePropertyIsHidden, kGlobal),
              "reader process killed -> dropped after %.0f ms, device hidden again", SecondsSince(t0) * 1000.0);

        // A pid that is already gone when it attaches is dropped at once.
        char *trueArgv[] = { "/usr/bin/true", NULL };
        const pid_t gone = SpawnChild("/usr/bin/true", trueArgv);
        if (gone > 0) waitpid(gone, NULL, 0);
        check(gone > 0 && SetReadersAs(dev, gone, 1) == kAudioHardwareNoError && WaitReaders(dev, 0, 2.0),
              "attach from a process that already exited -> dropped");

        check(SetData(dev, EQT_PROPERTY_READER_ATTACHED, kGlobal, 4, &(UInt32){ 1 }) == kAudioHardwareBadPropertySizeError,
              "raw UInt32 (wrong size) rejected");
        CFPropertyListRef str = CFSTR("1");
        check(SetData(dev, EQT_PROPERTY_READER_ATTACHED, kGlobal, sizeof str, &str) == kAudioHardwareIllegalOperationError,
              "CFString value rejected");
        check(SetReadersAs(dev, me, NAN) == kAudioHardwareIllegalOperationError && GetReaders(dev) == 0, "NaN rejected");

        // Table bound: kEQTMaxReaders (8) distinct processes, the 9th refused.
        pid_t fake[9];
        OSStatus last = kAudioHardwareNoError;
        int accepted = 0;
        for (int i = 0; i < 9; i++) {
            fake[i] = SpawnChild("/bin/sleep", sleepArgv);
            last = SetReadersAs(dev, fake[i], 1);
            if (last == kAudioHardwareNoError) accepted++;
        }
        check(accepted == 8 && last == kAudioHardwareIllegalOperationError && GetReaders(dev) == 8,
              "8 reader processes accepted, the 9th refused (fixed table, no growth)");
        for (int i = 0; i < 9; i++) if (fake[i] > 0) { kill(fake[i], SIGKILL); waitpid(fake[i], NULL, 0); }
        check(WaitReaders(dev, 0, 3.0), "all 8 dropped when their processes exit");

        // Leave it as a routed app would: attached, visible.
        SetReadersAs(dev, me, 1);
        check(U32(dev, kAudioDevicePropertyIsHidden, kGlobal) == 0, "re-attached for the IO checks");
    }

    // ------------------------------------------------------------------ error paths
    section("error handling (never crash coreaudiod)");
    {
        UInt32 size = 0, v = 0;
        check(GetData(99, kAudioObjectPropertyClass, kGlobal, 0, NULL, sizeof v, &v, &size) == kAudioHardwareBadObjectError,
              "unknown object -> BadObject");
        check(!Has(99, kAudioObjectPropertyClass, kGlobal), "HasProperty(unknown object) false");
        check(GetData(dev, 'zzzz', kGlobal, 0, NULL, sizeof v, &v, &size) == kAudioHardwareUnknownPropertyError,
              "unknown selector -> UnknownProperty");
        check(!Has(dev, 'zzzz', kGlobal), "HasProperty(unknown selector) false");
        Float32 tooSmall = 0;
        check(GetData(dev, kAudioDevicePropertyNominalSampleRate, kGlobal, 0, NULL, sizeof tooSmall, &tooSmall, &size)
                  == kAudioHardwareBadPropertySizeError, "too-small buffer -> BadPropertySize");
        const AudioObjectPropertyAddress a = { kAudioObjectPropertyClass, kGlobal, kAudioObjectPropertyElementMain };
        check((*gDrv)->GetPropertyData(gDrv, dev, 0, &a, 0, NULL, 4, &size, gNull) == kAudioHardwareIllegalOperationError,
              "NULL outData -> IllegalOperation");
        check((*gDrv)->GetPropertyData(gDrv, dev, 0, gNull, 0, NULL, 4, &size, &v) == kAudioHardwareIllegalOperationError,
              "NULL address -> IllegalOperation");
        check(SetData(dev, kAudioObjectPropertyName, kGlobal, sizeof(CFStringRef), &(CFStringRef){ CFSTR("x") })
                  == kAudioHardwareUnsupportedOperationError, "set read-only property -> UnsupportedOperation");
        check((*gDrv)->SetPropertyData(gDrv, volume, 0, &a, 0, NULL, 4, gNull) == kAudioHardwareIllegalOperationError,
              "set with NULL data -> IllegalOperation");
        AudioObjectID created = 0;
        check((*gDrv)->CreateDevice(gDrv, gNull, gNull, &created) == kAudioHardwareUnsupportedOperationError, "CreateDevice unsupported");
        check((*gDrv)->DestroyDevice(gDrv, dev) == kAudioHardwareUnsupportedOperationError, "DestroyDevice unsupported");
        AudioServerPlugInClientInfo client = { 1, getpid(), true, CFSTR("com.eqtargets.harness") };
        check((*gDrv)->AddDeviceClient(gDrv, dev, &client) == kAudioHardwareNoError
                  && (*gDrv)->RemoveDeviceClient(gDrv, dev, &client) == kAudioHardwareNoError, "Add/RemoveDeviceClient");
        check((*gDrv)->AddDeviceClient(gDrv, stream, &client) == kAudioHardwareBadObjectError, "AddDeviceClient(non-device) -> BadObject");
        check((*gDrv)->StartIO(gDrv, stream, 1) == kAudioHardwareBadObjectError, "StartIO(non-device) -> BadObject");
        check((*gDrv)->StopIO(gDrv, dev, 1) == kAudioHardwareIllegalOperationError, "StopIO with no clients -> IllegalOperation (no underflow)");
        check((*gDrv)->AbortDeviceConfigurationChange(gDrv, dev, 96000, NULL) == kAudioHardwareNoError, "AbortDeviceConfigurationChange ok");
        check((*gDrv)->PerformDeviceConfigurationChange(gDrv, dev, 12345, NULL) == kAudioHardwareIllegalOperationError,
              "Perform with a non-rate action rejected");
        AudioServerPlugInDriverInterface *fake = *gDrv;
        AudioServerPlugInDriverRef wrongRef = &fake;
        check((*gDrv)->HasProperty(wrongRef, dev, 0, &a) == false, "foreign driver ref rejected");
    }

    // ------------------------------------------------------------------ IO
    section("IO: StartIO + WriteMix -> ring (read back like the app)");
    {
        Boolean willDo = false, inPlace = false;
        check((*gDrv)->WillDoIOOperation(gDrv, dev, 1, kAudioServerPlugInIOOperationWriteMix, &willDo, &inPlace) == kAudioHardwareNoError
                  && willDo && inPlace, "WillDoIOOperation(WriteMix) -> will do, in place");
        bool othersOff = true;
        const UInt32 others[] = { kAudioServerPlugInIOOperationReadInput, kAudioServerPlugInIOOperationConvertInput,
                                  kAudioServerPlugInIOOperationProcessInput, kAudioServerPlugInIOOperationProcessOutput,
                                  kAudioServerPlugInIOOperationMixOutput, kAudioServerPlugInIOOperationProcessMix,
                                  kAudioServerPlugInIOOperationConvertMix, kAudioServerPlugInIOOperationThread,
                                  kAudioServerPlugInIOOperationCycle };
        for (size_t i = 0; i < sizeof others / sizeof others[0]; i++) {
            (*gDrv)->WillDoIOOperation(gDrv, dev, 1, others[i], &willDo, &inPlace);
            othersOff = othersOff && !willDo;
        }
        check(othersOff, "every other operation (incl. ReadInput) -> will NOT do");

        const uint64_t seedBefore = CurrentSeed(dev);
        const uint64_t g0 = EQTRingLoadGeneration(gRO);
        check((*gDrv)->StartIO(gDrv, dev, 1) == kAudioHardwareNoError, "StartIO(client 1)");
        check(EQTRingLoadIORunning(gRO) == 1 && EQTRingLoadWriteHead(gRO) == 0 && EQTRingLoadGeneration(gRO) == g0 + 1,
              "ring: ioRunning 1, writeHead 0, generation +1");
        check(U32(dev, kAudioDevicePropertyDeviceIsRunning, kGlobal) == 1, "device reports running");

        // 100 contiguous 512-frame cycles starting at the HAL-like output offset 1000.
        const uint32_t N = 512;
        const int64_t T0 = 1000;
        const uint64_t cycles0 = RingCycles(), zero0 = RingZeroed();
        const uint64_t tBefore = mach_absolute_time();
        IOCycle(dev, stream, (double)T0, T0, N, 1);
        check(EQTRingLoadWriteHead(gRO) == T0 + N, "first WriteMix: writeHead = T+N = %lld", (long long)(T0 + N));
        check(Mismatches(0, T0, 0) == 0, "initial gap [0, T) reads as silence");
        check(Mismatches(T0, N, 1) == 0, "first cycle bit-exact");
        check(RingZeroed() - zero0 == (uint64_t)T0, "zeroFilledFrames += %lld for the initial gap", (long long)T0);
        int64_t T = T0 + N;
        for (int k = 1; k < 100; k++, T += N) IOCycle(dev, stream, (double)T, T, N, 1);
        const uint64_t tAfter = mach_absolute_time();
        const int64_t head = EQTRingLoadWriteHead(gRO);
        check(head == T0 + 100 * (int64_t)N, "after 100 cycles writeHead = %lld (wrapped the %lld-frame ring)", (long long)head, (long long)kRingCap);
        check(Mismatches(head - kRingCap, kRingCap, 1) == 0, "entire readable window (%lld frames) bit-exact after wrap", (long long)kRingCap);
        check(RingCycles() - cycles0 == 100, "writeCycles counts 100 WriteMix calls");
        check(EQTRingLoadIOBufferFrames(gRO) == N, "ioBufferFrames = %u", N);
        const uint64_t lw = EQTRingLoadLastWriteHostTime(gRO);
        check(lw >= tBefore && lw <= tAfter, "lastWriteHostTime stamped during the last WriteMix");
        check(Mismatches(head, 1, 1) == -1 && Mismatches(head - kRingCap - 1, 1, 1) == -1,
              "reader can't read at/after writeHead or > capacity behind it");

        // Sample-time gap: the slots hold audio from the previous lap, so this
        // fails loudly if the zero-fill is missing.
        uint64_t z = RingZeroed();
        const int64_t gapStart = head;
        IOCycle(dev, stream, (double)(gapStart + 3000), gapStart + 3000, N, 1);
        check(EQTRingLoadWriteHead(gRO) == gapStart + 3000 + N, "gap of 3000 frames: writeHead jumps to T+N");
        check(Mismatches(gapStart, 3000, 0) == 0, "skipped frames read as zeros, not stale audio");
        check(Mismatches(gapStart + 3000, N, 1) == 0 && Mismatches(gapStart - 1000, 1000, 1) == 0, "frames around the gap intact");
        check(RingZeroed() - z == 3000, "zeroFilledFrames += 3000");

        // A gap bigger than the ring: clear only what is still visible.
        z = RingZeroed();
        const int64_t hugeT = EQTRingLoadWriteHead(gRO) + 100000;
        IOCycle(dev, stream, (double)hugeT, hugeT, N, 1);
        const int64_t h2 = EQTRingLoadWriteHead(gRO);
        check(h2 == hugeT + N, "gap of 100000 frames: writeHead = T+N");
        check(Mismatches(h2 - kRingCap, kRingCap - N, 0) == 0 && Mismatches(hugeT, N, 1) == 0,
              "whole window below T is silence, new cycle exact");
        check(RingZeroed() - z == (uint64_t)(kRingCap - N), "zero-fill capped at capacity - N = %lld frames", (long long)(kRingCap - N));

        // Rewrite of an older range: data replaced, head never moves back.
        IOCycle(dev, stream, (double)(h2 - 1024), h2 - 1024, N, 2);
        check(EQTRingLoadWriteHead(gRO) == h2, "rewrite of an older range leaves writeHead at %lld", (long long)h2);
        check(Mismatches(h2 - 1024, N, 2) == 0 && Mismatches(h2 - 512, 512, 1) == 0, "rewritten range replaced; newer frames untouched");

        // A write entirely older than the window must not corrupt live frames
        // (it would land in the same slots as the newest audio).
        void *snapshot = malloc(EQT_RING_SAMPLE_BYTES);
        memcpy(snapshot, EQTRingSamplesConst(gRO), EQT_RING_SAMPLE_BYTES);
        const int64_t ancient = h2 - kRingCap - 600;
        IOCycle(dev, stream, (double)ancient, ancient, N, 3);
        check(EQTRingLoadWriteHead(gRO) == h2 && memcmp(snapshot, EQTRingSamplesConst(gRO), EQT_RING_SAMPLE_BYTES) == 0,
              "write older than capacity behind head: ring bytes unchanged");
        // Straddling the window edge: only the in-window part is written.
        const int64_t straddle = h2 - kRingCap - 256;
        IOCycle(dev, stream, (double)straddle, straddle, N, 3);
        check(Mismatches(h2 - kRingCap, 256, 3) == 0, "straddling write: in-window 256 frames written");
        const float *now = EQTRingSamplesConst(gRO);
        const float *was = snapshot;
        size_t changed = 0;
        for (int64_t i = 0; i < kRingCap * kCh; i++) changed += memcmp(&now[i], &was[i], sizeof(float)) != 0;
        check(changed <= 256 * 2, "...and nothing else (%zu samples changed)", changed);
        free(snapshot);

        // Contiguous resume.
        IOCycle(dev, stream, (double)h2, h2, N, 1);
        check(EQTRingLoadWriteHead(gRO) == h2 + N && Mismatches(h2, N, 1) == 0, "contiguous resume exact");

        // Garbage timestamps and bad arguments are dropped, never crash.
        const uint64_t c = RingCycles();
        IOCycle(dev, stream, NAN, h2 + N, N, 1);
        check(EQTRingLoadWriteHead(gRO) == h2 + N && RingCycles() == c, "NaN sample time: cycle dropped");
        AudioServerPlugInIOCycleInfo info;
        memset(&info, 0, sizeof info);
        info.mOutputTime.mSampleTime = (double)(h2 + N);
        check((*gDrv)->DoIOOperation(gDrv, dev, stream, 1, kAudioServerPlugInIOOperationWriteMix, N, &info, NULL, NULL)
                  == kAudioHardwareIllegalOperationError, "NULL buffer -> IllegalOperation");
        check((*gDrv)->DoIOOperation(gDrv, dev, volume, 1, kAudioServerPlugInIOOperationWriteMix, N, &info, gIOBuffer, NULL)
                  == kAudioHardwareBadObjectError, "WriteMix to a non-stream object -> BadObject");
        check(RingCycles() == c, "rejected calls wrote nothing");

        section("IO: zero timestamps @ 48 kHz");
        CheckZeroTimeStamps(dev, 48000.0, 1.15, seedBefore);

        section("IO: client counting");
        const uint64_t g1 = EQTRingLoadGeneration(gRO);
        const int64_t hBefore = EQTRingLoadWriteHead(gRO);
        check((*gDrv)->StartIO(gDrv, dev, 2) == kAudioHardwareNoError, "StartIO(client 2) while running");
        check(EQTRingLoadGeneration(gRO) == g1 && EQTRingLoadWriteHead(gRO) == hBefore, "second client: no new timeline");
        check((*gDrv)->StopIO(gDrv, dev, 2) == kAudioHardwareNoError && EQTRingLoadIORunning(gRO) == 1,
              "StopIO(client 2): still running for client 1");
        check((*gDrv)->StopIO(gDrv, dev, 1) == kAudioHardwareNoError && EQTRingLoadIORunning(gRO) == 0,
              "StopIO(last client) -> ioRunning 0");
        check(U32(dev, kAudioDevicePropertyDeviceIsRunning, kGlobal) == 0, "device reports not running");
        check((*gDrv)->StopIO(gDrv, dev, 1) == kAudioHardwareIllegalOperationError, "extra StopIO refused");
    }

    // ------------------------------------------------------------------ sample-rate change
    section("sample-rate change (Request -> Perform)");
    {
        uint64_t g = EQTRingLoadGeneration(gRO);
        int performs = PerformCount();
        int mark = NoteMark();
        check(SetF64(dev, kAudioDevicePropertyNominalSampleRate, 96000.0) == kAudioHardwareNoError, "set nominal 96000");
        check(WaitPerform(performs, 2.0), "driver asked the host for a configuration change -> Perform ran");
        check(F64(dev, kAudioDevicePropertyNominalSampleRate, kGlobal) == 96000.0, "nominal rate now 96000");
        check(EQTRingLoadSampleRate(gRO) == 96000.0, "ring header rate 96000");
        check(EQTRingLoadGeneration(gRO) == g + 1 && EQTRingLoadWriteHead(gRO) == 0, "generation +1, writeHead 0");
        AudioStreamBasicDescription f;
        UInt32 size = 0;
        GetData(stream, kAudioStreamPropertyVirtualFormat, kGlobal, 0, NULL, sizeof f, &f, &size);
        check(f.mSampleRate == 96000.0, "stream virtual format follows (96000)");
        check(WaitNote(mark, dev, kAudioDevicePropertyNominalSampleRate, kGlobal, 2.0), "PropertiesChanged(nominal rate)");
        check(WaitNote(mark, stream, kAudioStreamPropertyVirtualFormat, kGlobal, 2.0)
                  && WaitNote(mark, stream, kAudioStreamPropertyPhysicalFormat, kGlobal, 2.0),
              "PropertiesChanged(stream virtual + physical format)");

        performs = PerformCount();
        SetF64(dev, kAudioDevicePropertyNominalSampleRate, 96000.0);
        SleepMs(300);
        check(PerformCount() == performs, "setting the current rate requests nothing");
        check(SetF64(dev, kAudioDevicePropertyNominalSampleRate, 12345.0) == kAudioHardwareIllegalOperationError,
              "unsupported rate 12345 rejected");
        check(SetData(dev, kAudioDevicePropertyNominalSampleRate, kGlobal, 4, &(Float32){ 44100.0f }) == kAudioHardwareBadPropertySizeError,
              "Float32 rate (wrong size) rejected");

        // Via the stream format, as the HAL does when a client sets a format.
        AudioStreamBasicDescription want = f;
        want.mSampleRate = 44100.0;
        performs = PerformCount();
        g = EQTRingLoadGeneration(gRO);
        check(SetData(stream, kAudioStreamPropertyPhysicalFormat, kGlobal, sizeof want, &want) == kAudioHardwareNoError
                  && WaitPerform(performs, 2.0) && F64(dev, kAudioDevicePropertyNominalSampleRate, kGlobal) == 44100.0
                  && EQTRingLoadSampleRate(gRO) == 44100.0 && EQTRingLoadGeneration(gRO) == g + 1,
              "set physical format @ 44100 -> rate change through Perform");
        want.mChannelsPerFrame = 1;
        want.mBytesPerFrame = want.mBytesPerPacket = 4;
        check(SetData(stream, kAudioStreamPropertyVirtualFormat, kGlobal, sizeof want, &want) == kAudioDeviceUnsupportedFormatError,
              "mono format rejected (UnsupportedFormat)");

        performs = PerformCount();
        SetF64(dev, kAudioDevicePropertyNominalSampleRate, 96000.0);
        check(WaitPerform(performs, 2.0) && EQTRingLoadSampleRate(gRO) == 96000.0, "back to 96000 for the IO checks");

        section("IO @ 96 kHz: timestamps, rounding, negative start");
        const uint64_t seedBefore = CurrentSeed(dev);
        check((*gDrv)->StartIO(gDrv, dev, 1) == kAudioHardwareNoError && EQTRingLoadIORunning(gRO) == 1, "StartIO at 96 kHz");
        // A cycle that starts before frame 0 keeps only the frames >= 0.
        IOCycle(dev, stream, -100.0, -100, 512, 1);
        check(EQTRingLoadWriteHead(gRO) == 412 && Mismatches(0, 412, 1) == 0, "sample time -100: frames [0, 412) written exactly");
        // 411.9999999 is frame 412 (round, don't truncate — truncation would overlap by one frame every cycle).
        IOCycle(dev, stream, 411.9999999, 412, 512, 1);
        check(EQTRingLoadWriteHead(gRO) == 924 && Mismatches(0, 924, 1) == 0, "sample time 411.9999999 rounds to 412: contiguous");
        CheckZeroTimeStamps(dev, 96000.0, 0.62, seedBefore);
        check((*gDrv)->StopIO(gDrv, dev, 1) == kAudioHardwareNoError && EQTRingLoadIORunning(gRO) == 0, "StopIO -> ioRunning 0");

        section("sample-rate change: a host that defers Perform (latest request wins)");
        UInt64 queued[kMaxDeferred];
        pthread_mutex_lock(&gHostMutex);
        gDeferPerform = true;
        gDeferredCount = 0;
        pthread_mutex_unlock(&gHostMutex);

        // Switch to 44.1 kHz and straight back before the host performs.
        g = EQTRingLoadGeneration(gRO);
        SetF64(dev, kAudioDevicePropertyNominalSampleRate, 44100.0);
        SetF64(dev, kAudioDevicePropertyNominalSampleRate, 96000.0);
        SleepMs(300);
        int n = TakeDeferred(queued);
        for (int i = 0; i < n; i++) (*gDrv)->PerformDeviceConfigurationChange(gDrv, dev, queued[i], NULL);
        check(F64(dev, kAudioDevicePropertyNominalSampleRate, kGlobal) == 96000.0 && EQTRingLoadSampleRate(gRO) == 96000.0,
              "44.1 kHz then back to 96 kHz before Perform: ends at 96 kHz (%d request(s) performed in order)", n);
        check(EQTRingLoadGeneration(gRO) == g, "...and no timeline restart: the stale Perform was a no-op");

        // Two new rates, delivered to Perform in REVERSE order (concurrent queue).
        g = EQTRingLoadGeneration(gRO);
        SetF64(dev, kAudioDevicePropertyNominalSampleRate, 48000.0);
        SetF64(dev, kAudioDevicePropertyNominalSampleRate, 88200.0);
        SleepMs(300);
        n = TakeDeferred(queued);
        for (int i = n - 1; i >= 0; i--) (*gDrv)->PerformDeviceConfigurationChange(gDrv, dev, queued[i], NULL);
        check(F64(dev, kAudioDevicePropertyNominalSampleRate, kGlobal) == 88200.0 && EQTRingLoadSampleRate(gRO) == 88200.0,
              "48 then 88.2 kHz, performed in reverse order: ends at 88.2 kHz (the last set)");
        check(EQTRingLoadGeneration(gRO) == g + 1, "exactly one timeline restart for the two requests (generation +%llu)",
              (unsigned long long)(EQTRingLoadGeneration(gRO) - g));

        // The same new rate set twice (stream format, then nominal rate): ONE request.
        AudioStreamBasicDescription fmt;
        UInt32 fmtSize = 0;
        GetData(stream, kAudioStreamPropertyVirtualFormat, kGlobal, 0, NULL, sizeof fmt, &fmt, &fmtSize);
        fmt.mSampleRate = 96000.0;
        SetData(stream, kAudioStreamPropertyPhysicalFormat, kGlobal, sizeof fmt, &fmt);
        SetF64(dev, kAudioDevicePropertyNominalSampleRate, 96000.0);
        SleepMs(300);
        n = TakeDeferred(queued);
        check(n == 1, "format @ 96 kHz then nominal 96 kHz -> %d configuration request(s) (want 1: one IO restart)", n);
        g = EQTRingLoadGeneration(gRO);
        for (int i = 0; i < n; i++) (*gDrv)->PerformDeviceConfigurationChange(gDrv, dev, queued[i], NULL);
        check(F64(dev, kAudioDevicePropertyNominalSampleRate, kGlobal) == 96000.0 && EQTRingLoadGeneration(gRO) == g + 1,
              "...performed: 96 kHz, one new timeline");

        // The host aborts a request: setting that rate again must ask again.
        SetF64(dev, kAudioDevicePropertyNominalSampleRate, 44100.0);
        SleepMs(300);
        n = TakeDeferred(queued);
        check(n == 1 && (*gDrv)->AbortDeviceConfigurationChange(gDrv, dev, queued[0], NULL) == kAudioHardwareNoError,
              "request for 44.1 kHz aborted by the host");
        check(F64(dev, kAudioDevicePropertyNominalSampleRate, kGlobal) == 96000.0, "...rate unchanged (96 kHz)");
        SetF64(dev, kAudioDevicePropertyNominalSampleRate, 44100.0);
        SleepMs(300);
        n = TakeDeferred(queued);
        for (int i = 0; i < n; i++) (*gDrv)->PerformDeviceConfigurationChange(gDrv, dev, queued[i], NULL);
        check(n == 1 && F64(dev, kAudioDevicePropertyNominalSampleRate, kGlobal) == 44100.0,
              "setting 44.1 kHz again after the abort asks again and applies (%d request)", n);

        pthread_mutex_lock(&gHostMutex);
        gDeferPerform = false;
        pthread_mutex_unlock(&gHostMutex);
        performs = PerformCount();
        SetF64(dev, kAudioDevicePropertyNominalSampleRate, 96000.0);
        check(WaitPerform(performs, 2.0) && F64(dev, kAudioDevicePropertyNominalSampleRate, kGlobal) == 96000.0,
              "synchronous host again: back to 96 kHz");
    }

    // ------------------------------------------------------------------ reattach (coreaudiod restart)
    section("re-attach in a fresh process (simulated coreaudiod restart)");
    {
        char genArg[32], loadArg[32];
        snprintf(genArg, sizeof genArg, "%llu", (unsigned long long)EQTRingLoadGeneration(gRO));
        snprintf(loadArg, sizeof loadArg, "%llu", (unsigned long long)load);
        char self[PATH_MAX];
        uint32_t sz = sizeof self;
        _NSGetExecutablePath(self, &sz);
        char *argv[] = { self, "--reattach-check", (char *)driverPath, ringName, genArg, loadArg, NULL };
        fflush(stdout);
        pid_t pid = 0;
        int status = -1;
        const bool spawned = posix_spawn(&pid, self, NULL, NULL, argv, environ) == 0 && waitpid(pid, &status, 0) == pid;
        check(spawned && WIFEXITED(status) && WEXITSTATUS(status) == 0, "child re-attached to the existing ring and passed");
    }

    section("cleanup");
    munmap((void *)gRO, EQT_RING_TOTAL_BYTES);
    check(shm_unlink(ringName) == 0, "shm_unlink(%s)", ringName);
    const int fd = shm_open(ringName, O_RDONLY);
    check(fd < 0 && errno == ENOENT, "ring gone");
    if (fd >= 0) close(fd);

    printf("\nSUMMARY: %d passed, %d failed\n", gPass, gFail);
    return gFail == 0 ? 0 : 1;
}

// ================================================================ main

static void Usage(void) {
    fprintf(stderr,
            "usage: eqt-driver-harness [driver]\n"
            "       eqt-driver-harness --serve <seconds> [--ppm <ppm>] [driver]   (needs EQT_RING_NAME_OVERRIDE)\n"
            "  driver: EQtargetsAudio.driver bundle or its executable (default: next to this tool)\n");
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    gTicksPerSecond = 1.0e9 * (double)tb.denom / (double)tb.numer;

    char driverPath[PATH_MAX];
    if (argc >= 2 && strcmp(argv[1], "--reattach-check") == 0) {
        if (argc != 6) return 2;
        return RunReattachChild(argv[2], argv[3], strtoull(argv[4], NULL, 10), strtoull(argv[5], NULL, 10));
    }
    if (argc >= 2 && (strcmp(argv[1], "-h") == 0 || strcmp(argv[1], "--help") == 0)) { Usage(); return 0; }
    if (argc >= 2 && strcmp(argv[1], "--serve") == 0) {
        if (argc < 3) { Usage(); return 2; }
        const double seconds = atof(argv[2]);
        double ppm = 0.0;
        const char *path = NULL;
        for (int i = 3; i < argc; i++) {
            if (strcmp(argv[i], "--ppm") == 0 && i + 1 < argc) ppm = atof(argv[++i]);
            else path = argv[i];
        }
        if (!ResolveDriverPath(path, driverPath, sizeof driverPath)) {
            fprintf(stderr, "driver not found at %s (build the EQtargetsAudioDriver target)\n", driverPath);
            return 2;
        }
        return RunServe(driverPath, seconds > 0 ? seconds : 3.0, ppm);
    }
    if (argc > 2) { Usage(); return 2; }
    if (!ResolveDriverPath(argc == 2 ? argv[1] : NULL, driverPath, sizeof driverPath)) {
        fprintf(stderr, "FAIL  driver not found at %s (build the EQtargetsAudioDriver target)\n", driverPath);
        return 1;
    }
    return RunSuite(driverPath);
}
