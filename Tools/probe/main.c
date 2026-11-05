//
//  main.c — eqt-probe
//  EQtargets (macOS)
//
//  Field diagnostics for the EQtargets Audio driver, runnable by the user or
//  by scripts/install-driver.sh. Read-only by design: it never changes the
//  default output device or any other system setting.
//
//    eqt-probe --devices          every audio device (name, UID, in/out channels, nominal
//                                 rate, transport, default markers) and which devices are
//                                 RUNNING INPUT right now and for whom — the Bluetooth HFP
//                                 check: input on AirPods drops them to the headset profile.
//                                 Exit 0 if EQtargets Audio is present, 3 if not.
//    eqt-probe --ring [seconds]   map the driver's ring READ-ONLY (exactly like the app), dump
//                                 the header, watch writeHead (default 2 s) and report the
//                                 observed frames/s vs nominal as drift in ppm, plus the level
//                                 and frequency of the newest audio in the ring.
//    eqt-probe --selftest         play a 1 kHz, -20 dBFS tone for 2 s DIRECTLY into EQtargets
//                                 Audio (an IOProc on that device, not the default output)
//                                 and confirm through the ring that frames advance and carry
//                                 the tone (RMS -23.0 dBFS, 1000 Hz).
//
//  Exit codes: 0 ok · 1 check failed · 2 usage/system error · 3 driver not installed / ring absent.
//  $EQT_RING_NAME_OVERRIDE (test only) selects a different ring, e.g. one served by
//  `eqt-driver-harness --serve`.
//

#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <errno.h>
#include <fcntl.h>
#include <mach/mach_time.h>
#include <math.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include "EQTRingProtocol.h"

enum { kExitOK = 0, kExitFail = 1, kExitUsage = 2, kExitAbsent = 3 };

static double gTicksPerSecond;
static double TicksToSeconds(uint64_t ticks) { return (double)ticks / gTicksPerSecond; }

// ================================================================ HAL helpers (client side)

static OSStatus GetProp(AudioObjectID obj, AudioObjectPropertySelector sel, AudioObjectPropertyScope scope,
                        UInt32 size, void *out) {
    const AudioObjectPropertyAddress a = { sel, scope, kAudioObjectPropertyElementMain };
    return AudioObjectGetPropertyData(obj, &a, 0, NULL, &size, out);
}

static UInt32 GetU32(AudioObjectID obj, AudioObjectPropertySelector sel, AudioObjectPropertyScope scope, UInt32 fallback) {
    UInt32 v = fallback;
    return GetProp(obj, sel, scope, sizeof v, &v) == noErr ? v : fallback;
}

static void GetString(AudioObjectID obj, AudioObjectPropertySelector sel, char *buf, size_t bufSize) {
    CFStringRef s = NULL;
    buf[0] = '\0';
    if (GetProp(obj, sel, kAudioObjectPropertyScopeGlobal, sizeof s, &s) == noErr && s != NULL) {
        CFStringGetCString(s, buf, (CFIndex)bufSize, kCFStringEncodingUTF8);
        CFRelease(s);
    }
    if (buf[0] == '\0') snprintf(buf, bufSize, "?");
}

/// Copies an AudioObjectID list; returns the count (caller frees *out).
static UInt32 GetIDList(AudioObjectID obj, AudioObjectPropertySelector sel, AudioObjectPropertyScope scope, AudioObjectID **out) {
    const AudioObjectPropertyAddress a = { sel, scope, kAudioObjectPropertyElementMain };
    UInt32 size = 0;
    *out = NULL;
    if (AudioObjectGetPropertyDataSize(obj, &a, 0, NULL, &size) != noErr || size == 0) return 0;
    *out = malloc(size);
    if (*out == NULL || AudioObjectGetPropertyData(obj, &a, 0, NULL, &size, *out) != noErr) {
        free(*out);
        *out = NULL;
        return 0;
    }
    return size / (UInt32)sizeof(AudioObjectID);
}

static UInt32 ChannelCount(AudioObjectID dev, AudioObjectPropertyScope scope) {
    const AudioObjectPropertyAddress a = { kAudioDevicePropertyStreamConfiguration, scope, kAudioObjectPropertyElementMain };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(dev, &a, 0, NULL, &size) != noErr || size == 0) return 0;
    AudioBufferList *list = malloc(size);
    UInt32 channels = 0;
    if (list != NULL && AudioObjectGetPropertyData(dev, &a, 0, NULL, &size, list) == noErr) {
        for (UInt32 i = 0; i < list->mNumberBuffers; i++) channels += list->mBuffers[i].mNumberChannels;
    }
    free(list);
    return channels;
}

static const char *TransportName(UInt32 t) {
    switch (t) {
        case kAudioDeviceTransportTypeBuiltIn:           return "built-in";
        case kAudioDeviceTransportTypeAggregate:         return "aggregate";
        case kAudioDeviceTransportTypeVirtual:           return "virtual";
        case kAudioDeviceTransportTypePCI:               return "PCI";
        case kAudioDeviceTransportTypeUSB:               return "USB";
        case kAudioDeviceTransportTypeFireWire:          return "FireWire";
        case kAudioDeviceTransportTypeBluetooth:         return "Bluetooth";
        case kAudioDeviceTransportTypeBluetoothLE:       return "Bluetooth LE";
        case kAudioDeviceTransportTypeHDMI:              return "HDMI";
        case kAudioDeviceTransportTypeDisplayPort:       return "DisplayPort";
        case kAudioDeviceTransportTypeAirPlay:           return "AirPlay";
        case kAudioDeviceTransportTypeAVB:               return "AVB";
        case kAudioDeviceTransportTypeThunderbolt:       return "Thunderbolt";
        case kAudioDeviceTransportTypeContinuityCaptureWired:
        case kAudioDeviceTransportTypeContinuityCaptureWireless: return "Continuity";
        default:                                         return "other";
    }
}

static AudioObjectID FindEQTDevice(void) {
    CFStringRef uid = CFSTR(EQT_DEVICE_UID);
    AudioObjectID dev = kAudioObjectUnknown;
    UInt32 size = sizeof dev;
    const AudioObjectPropertyAddress a = { kAudioHardwarePropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal,
                                           kAudioObjectPropertyElementMain };
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, sizeof uid, &uid, &size, &dev) != noErr) return kAudioObjectUnknown;
    return dev;
}

// ================================================================ --devices

#define kMaxInputUsers 8
typedef struct { AudioObjectID device; int count; pid_t pids[kMaxInputUsers]; char bundle[kMaxInputUsers][96]; } InputUse;

static int RunDevices(void) {
    AudioObjectID *devices = NULL;
    const UInt32 count = GetIDList(kAudioObjectSystemObject, kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, &devices);
    if (count == 0) {
        fprintf(stderr, "eqt-probe: could not list audio devices (is coreaudiod running?)\n");
        return kExitUsage;
    }
    const AudioObjectID defOut = (AudioObjectID)GetU32(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, 0);
    const AudioObjectID defSys = (AudioObjectID)GetU32(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultSystemOutputDevice, kAudioObjectPropertyScopeGlobal, 0);
    const AudioObjectID defIn  = (AudioObjectID)GetU32(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal, 0);

    // Who is running INPUT, on which device (process objects, macOS 14+). No
    // permission is needed to read this; it is the same data the orange-dot
    // indicator is driven by.
    InputUse *uses = calloc(count, sizeof(InputUse));
    for (UInt32 i = 0; i < count && uses != NULL; i++) uses[i].device = devices[i];
    AudioObjectID *procs = NULL;
    const UInt32 procCount = GetIDList(kAudioObjectSystemObject, kAudioHardwarePropertyProcessObjectList, kAudioObjectPropertyScopeGlobal, &procs);
    bool processInfoOK = procs != NULL || procCount == 0;
    for (UInt32 p = 0; p < procCount && uses != NULL; p++) {
        if (GetU32(procs[p], kAudioProcessPropertyIsRunningInput, kAudioObjectPropertyScopeGlobal, 0) == 0) continue;
        pid_t pid = -1;
        GetProp(procs[p], kAudioProcessPropertyPID, kAudioObjectPropertyScopeGlobal, sizeof pid, &pid);
        char bundle[96];
        GetString(procs[p], kAudioProcessPropertyBundleID, bundle, sizeof bundle);
        AudioObjectID *inDevs = NULL;
        const UInt32 nIn = GetIDList(procs[p], kAudioProcessPropertyDevices, kAudioObjectPropertyScopeInput, &inDevs);
        for (UInt32 k = 0; k < nIn; k++) {
            for (UInt32 d = 0; d < count; d++) {
                if (uses[d].device == inDevs[k] && uses[d].count < kMaxInputUsers) {
                    uses[d].pids[uses[d].count] = pid;
                    snprintf(uses[d].bundle[uses[d].count], sizeof uses[d].bundle[0], "%s", bundle);
                    uses[d].count++;
                }
            }
        }
        free(inDevs);
    }
    free(procs);

    printf("%-4s %-34s %-36s %3s %3s %8s  %-12s %s\n", "ID", "Name", "UID", "In", "Out", "Rate", "Transport", "Flags");
    AudioObjectID eqt = kAudioObjectUnknown;
    UInt32 eqtIn = 0, eqtOut = 0;
    int hfpSuspects = 0;
    for (UInt32 i = 0; i < count; i++) {
        const AudioObjectID dev = devices[i];
        char name[128], uid[160];
        GetString(dev, kAudioObjectPropertyName, name, sizeof name);
        GetString(dev, kAudioDevicePropertyDeviceUID, uid, sizeof uid);
        const UInt32 in = ChannelCount(dev, kAudioObjectPropertyScopeInput);
        const UInt32 out = ChannelCount(dev, kAudioObjectPropertyScopeOutput);
        Float64 rate = 0;
        GetProp(dev, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, sizeof rate, &rate);
        const UInt32 transport = GetU32(dev, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, 0);
        const bool running = GetU32(dev, kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioObjectPropertyScopeGlobal, 0) != 0;
        const bool isBT = transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE;

        char flags[512] = "";
        if (dev == defOut) strlcat(flags, "[default out] ", sizeof flags);
        if (dev == defSys) strlcat(flags, "[system out] ", sizeof flags);
        if (dev == defIn)  strlcat(flags, "[default in] ", sizeof flags);
        if (running)       strlcat(flags, "[running] ", sizeof flags);
        if (uses != NULL && uses[i].count > 0) {
            strlcat(flags, "[INPUT RUNNING:", sizeof flags);
            for (int u = 0; u < uses[i].count; u++) {
                char who[128];
                snprintf(who, sizeof who, " %s(pid %d)", uses[i].bundle[u], (int)uses[i].pids[u]);
                strlcat(flags, who, sizeof flags);
            }
            strlcat(flags, "] ", sizeof flags);
            if (isBT) hfpSuspects++;
        }
        if (strcmp(uid, EQT_DEVICE_UID) == 0) { eqt = dev; eqtIn = in; eqtOut = out; strlcat(flags, "<- EQtargets Audio", sizeof flags); }
        printf("%-4u %-34.34s %-36.36s %3u %3u %8.0f  %-12s %s\n", (unsigned)dev, name, uid, (unsigned)in, (unsigned)out,
               rate, TransportName(transport), flags);
    }
    free(uses);
    free(devices);

    printf("\n");
    if (!processInfoOK) printf("note: process objects unavailable; input-use detection skipped\n");
    if (hfpSuspects > 0) {
        printf("WARNING: %d Bluetooth device(s) are running INPUT. Bluetooth headphones switch to the HFP\n"
               "         headset profile while their mic is open (low-quality, mono-ish playback).\n", hfpSuspects);
    } else {
        printf("Bluetooth HFP check: no Bluetooth device is running input.\n");
    }
    bool hidden = false;
    if (eqt == kAudioObjectUnknown) {
        // A current driver hides the device while no app reads the ring
        // ('eqta'); hidden devices are not in the list but resolve by UID.
        eqt = FindEQTDevice();
        if (eqt != kAudioObjectUnknown) {
            hidden = true;
            eqtIn = ChannelCount(eqt, kAudioObjectPropertyScopeInput);
            eqtOut = ChannelCount(eqt, kAudioObjectPropertyScopeOutput);
        }
    }
    if (eqt == kAudioObjectUnknown) {
        printf("EQtargets Audio: NOT INSTALLED (no device with UID %s).\n"
               "                 Install with scripts/install-driver.sh.\n", EQT_DEVICE_UID);
        return kExitAbsent;
    }
    printf("EQtargets Audio: present (device %u%s), %u output / %u input channels%s\n", (unsigned)eqt,
           hidden ? ", HIDDEN: no app is reading the ring (EQtargets off or not running)" : "", (unsigned)eqtOut,
           (unsigned)eqtIn, eqtIn == 0 ? " (output-only, as designed)" : "  !! INPUT EXPOSED — this would need mic permission");
    return eqtIn == 0 ? kExitOK : kExitFail;
}

// ================================================================ ring reading (the app's protocol)

typedef struct { const EQTRingHeader *h; char name[64]; } Ring;

/// Opens the ring read-only. Returns kExitOK, or an exit code after printing why.
static int OpenRing(Ring *ring) {
    const char *override = getenv("EQT_RING_NAME_OVERRIDE");
    snprintf(ring->name, sizeof ring->name, "%s", (override != NULL && override[0] != '\0') ? override : EQT_RING_SHM_NAME);
    const int fd = shm_open(ring->name, O_RDONLY);
    if (fd < 0) {
        if (errno == ENOENT) {
            printf("Ring %s does not exist: the EQtargets Audio driver is not installed, or coreaudiod has\n"
                   "not loaded it yet (it creates the ring when it initialises).\n", ring->name);
            return kExitAbsent;
        }
        printf("Cannot open ring %s read-only: %s\n", ring->name, strerror(errno));
        return kExitUsage;
    }
    // macOS reports shm sizes rounded up to the VM page (16 KB on Apple
    // silicon), so 266240 bytes fstat()s as 278528. Accept either.
    struct stat st;
    const off_t page = (off_t)sysconf(_SC_PAGESIZE);
    const off_t rounded = page > 0 ? ((off_t)EQT_RING_TOTAL_BYTES + page - 1) / page * page : (off_t)EQT_RING_TOTAL_BYTES;
    if (fstat(fd, &st) != 0 || (st.st_size != (off_t)EQT_RING_TOTAL_BYTES && st.st_size != rounded)) {
        printf("Ring %s has size %lld, expected %u: a driver from a different build owns it.\n",
               ring->name, (long long)st.st_size, (unsigned)EQT_RING_TOTAL_BYTES);
        close(fd);
        return kExitFail;
    }
    void *p = mmap(NULL, EQT_RING_TOTAL_BYTES, PROT_READ, MAP_SHARED, fd, 0);
    close(fd);
    if (p == MAP_FAILED) {
        printf("mmap(%s) failed: %s\n", ring->name, strerror(errno));
        return kExitUsage;
    }
    ring->h = p;
    return kExitOK;
}

/// Copies the newest `frames` frames into dst using the reader protocol
/// (generation + writeHead before and after; retry on a timeline restart or a
/// lapped read). Returns false if there are not enough frames yet.
static bool RingCopyNewest(const EQTRingHeader *h, float *dst, int64_t frames) {
    for (int attempt = 0; attempt < 8; attempt++) {
        const uint64_t g0 = EQTRingLoadGeneration(h);
        const int64_t head = EQTRingLoadWriteHead(h);
        if (head < frames) return false;
        const int64_t from = head - frames;
        const float *s = EQTRingSamplesConst(h);
        for (int64_t i = 0; i < frames; i++) {
            const int64_t slot = (from + i) & (int64_t)(EQT_RING_CAPACITY_FRAMES - 1);
            dst[2 * i] = s[2 * slot];
            dst[2 * i + 1] = s[2 * slot + 1];
        }
        const uint64_t g1 = EQTRingLoadGeneration(h);
        const int64_t h1 = EQTRingLoadWriteHead(h);
        if (g1 == g0 && h1 - from <= (int64_t)EQT_RING_CAPACITY_FRAMES) return true;
    }
    return false;
}

typedef struct { double rmsDB[2]; double peak; double freqHz; } SignalStats;

/// Level per channel and the frequency of channel 0 from interpolated upward
/// zero crossings (exact to a fraction of a Hz on a clean tone).
static SignalStats Analyze(const float *x, int64_t frames, double rate) {
    SignalStats s = { { -INFINITY, -INFINITY }, 0.0, 0.0 };
    for (int c = 0; c < 2; c++) {
        double sum = 0.0;
        for (int64_t i = 0; i < frames; i++) {
            const double v = x[2 * i + c];
            sum += v * v;
            if (fabs(v) > s.peak) s.peak = fabs(v);
        }
        const double rms = sqrt(sum / (double)frames);
        s.rmsDB[c] = rms > 0 ? 20.0 * log10(rms) : -INFINITY;
    }
    double first = -1.0, last = -1.0;
    int crossings = 0;
    for (int64_t i = 1; i < frames; i++) {
        const double a = x[2 * (i - 1)], b = x[2 * i];
        if (a < 0.0 && b >= 0.0) {
            const double t = (double)(i - 1) + (-a) / (b - a);
            if (first < 0) first = t;
            last = t;
            crossings++;
        }
    }
    if (crossings >= 2 && last > first) s.freqHz = (double)(crossings - 1) * rate / (last - first);
    return s;
}

static void PrintHeader(const Ring *ring) {
    const EQTRingHeader *h = ring->h;
    const uint64_t now = mach_absolute_time();
    const uint64_t lastWrite = EQTRingLoadLastWriteHostTime(h);
    const uint64_t loaded = __atomic_load_n(&h->driverLoadHostTime, __ATOMIC_RELAXED);
    printf("Ring %s (%u bytes, read-only mapping)\n", ring->name, (unsigned)EQT_RING_TOTAL_BYTES);
    printf("  magic        0x%08X %s\n", EQTRingLoadMagic(h), EQTRingLoadMagic(h) == EQT_RING_MAGIC ? "(ok)" : "(NOT PUBLISHED)");
    printf("  version      %u (this build: %u)\n", h->version, EQT_RING_VERSION);
    printf("  channels     %u   capacity %u frames   headerBytes %u\n", h->channels, h->capacityFrames, h->headerBytes);
    printf("  valid        %s\n", EQTRingHeaderIsValid(h) ? "yes" : "NO — the app would refuse this ring");
    printf("  sampleRate   %.0f Hz\n", EQTRingLoadSampleRate(h));
    printf("  generation   %llu\n", (unsigned long long)EQTRingLoadGeneration(h));
    printf("  ioRunning    %u\n", EQTRingLoadIORunning(h));
    printf("  writeHead    %lld\n", (long long)EQTRingLoadWriteHead(h));
    printf("  ioBuffer     %u frames\n", EQTRingLoadIOBufferFrames(h));
    if (lastWrite != 0 && lastWrite <= now) printf("  lastWrite    %.1f ms ago\n", TicksToSeconds(now - lastWrite) * 1000.0);
    else printf("  lastWrite    never\n");
    printf("  writeCycles  %llu   zeroFilled %llu frames\n", (unsigned long long)__atomic_load_n(&h->writeCycles, __ATOMIC_RELAXED),
           (unsigned long long)__atomic_load_n(&h->zeroFilledFrames, __ATOMIC_RELAXED));
    if (loaded != 0 && loaded <= now) printf("  driver up    %.1f s\n", TicksToSeconds(now - loaded));
}

typedef struct { double fps; double ppm; int samples; bool ok; } RateFit;

/// Watches writeHead for `seconds`, fitting writeHead against the driver's own
/// lastWriteHostTime stamp (least squares) — that removes this process's
/// polling jitter. Restarts the fit if the generation changes.
static RateFit MeasureRate(const EQTRingHeader *h, double seconds) {
    RateFit fit = { 0, 0, 0, false };
    enum { kMax = 4096 };
    static double ts[kMax], hs[kMax];
    int n = 0;
    uint64_t gen = EQTRingLoadGeneration(h);
    uint64_t lastStamp = 0;
    const uint64_t start = mach_absolute_time();
    while (TicksToSeconds(mach_absolute_time() - start) < seconds) {
        const uint64_t g = EQTRingLoadGeneration(h);
        const uint64_t t1 = EQTRingLoadLastWriteHostTime(h);
        const int64_t head = EQTRingLoadWriteHead(h);
        const uint64_t t2 = EQTRingLoadLastWriteHostTime(h);
        if (g != gen) { gen = g; n = 0; lastStamp = 0; }
        if (t1 == t2 && t1 != lastStamp && head > 0 && n < kMax) {
            // Signed: the first stamp usually predates `start`.
            ts[n] = (double)(int64_t)(t1 - start) / gTicksPerSecond;
            hs[n] = (double)head;
            n++;
            lastStamp = t1;
        }
        usleep(5000);
    }
    fit.samples = n;
    if (n < 10) return fit;
    double mt = 0, mh = 0;
    for (int i = 0; i < n; i++) { mt += ts[i]; mh += hs[i]; }
    mt /= n; mh /= n;
    double num = 0, den = 0;
    for (int i = 0; i < n; i++) { num += (ts[i] - mt) * (hs[i] - mh); den += (ts[i] - mt) * (ts[i] - mt); }
    if (den <= 0) return fit;
    fit.fps = num / den;
    const double nominal = EQTRingLoadSampleRate(h);
    fit.ppm = nominal > 0 ? (fit.fps / nominal - 1.0) * 1.0e6 : 0.0;
    fit.ok = true;
    return fit;
}

static int RunRing(double seconds) {
    Ring ring;
    const int open = OpenRing(&ring);
    if (open != kExitOK) return open;
    PrintHeader(&ring);
    if (!EQTRingHeaderIsValid(ring.h)) return kExitFail;

    const int64_t h0 = EQTRingLoadWriteHead(ring.h);
    const uint64_t z0 = __atomic_load_n(&ring.h->zeroFilledFrames, __ATOMIC_RELAXED);
    const uint64_t c0 = __atomic_load_n(&ring.h->writeCycles, __ATOMIC_RELAXED);
    printf("\nWatching writeHead for %.1f s ...\n", seconds);
    const RateFit fit = MeasureRate(ring.h, seconds);
    const int64_t h1 = EQTRingLoadWriteHead(ring.h);
    const uint64_t z1 = __atomic_load_n(&ring.h->zeroFilledFrames, __ATOMIC_RELAXED);
    const uint64_t c1 = __atomic_load_n(&ring.h->writeCycles, __ATOMIC_RELAXED);
    const double nominal = EQTRingLoadSampleRate(ring.h);

    if (!fit.ok || h1 == h0) {
        printf("IO idle: writeHead did not advance (ioRunning=%u). Nothing is playing to EQtargets Audio,\n"
               "or no app is using it. Play something (or run --selftest) and try again.\n", EQTRingLoadIORunning(ring.h));
        return kExitOK;
    }
    printf("  observed     %.2f frames/s over %d write stamps (nominal %.0f)\n", fit.fps, fit.samples, nominal);
    printf("  drift        %+.0f ppm  (%s)\n", fit.ppm,
           fabs(fit.ppm) < 1000 ? "fine for the app's PLL" : "large — check the clock / IO cycle timing");
    printf("  IO cycles    %llu  (%.1f per second)\n", (unsigned long long)(c1 - c0), (double)(c1 - c0) / seconds);
    printf("  gaps         %llu frames zero-filled during the watch%s\n", (unsigned long long)(z1 - z0),
           z1 == z0 ? "" : "  (missed IO cycles upstream)");

    const int64_t frames = (int64_t)fmin(nominal * 0.1, 8192.0);
    float *buf = malloc((size_t)frames * 2 * sizeof(float));
    if (buf != NULL && RingCopyNewest(ring.h, buf, frames)) {
        const SignalStats s = Analyze(buf, frames, nominal);
        printf("  newest %.0f ms: L %.1f dBFS RMS, R %.1f dBFS RMS, peak %.3f, L frequency %.1f Hz\n",
               (double)frames / nominal * 1000.0, s.rmsDB[0], s.rmsDB[1], s.peak, s.freqHz);
    }
    free(buf);
    return kExitOK;
}

// ================================================================ --selftest

typedef struct { double x, y, c, s; float amp; UInt32 calls; } Tone;

/// IOProc on EQtargets Audio. A complex rotator generates the sine (two
/// multiplies per sample, renormalised once per buffer) — no sin() per sample.
static OSStatus ToneIOProc(AudioObjectID dev, const AudioTimeStamp *now, const AudioBufferList *in, const AudioTimeStamp *inTime,
                           AudioBufferList *out, const AudioTimeStamp *outTime, void *ctx) {
    (void)dev; (void)now; (void)in; (void)inTime; (void)outTime;
    Tone *t = ctx;
    if (out == NULL || out->mNumberBuffers == 0) return noErr;
    const UInt32 chans0 = out->mBuffers[0].mNumberChannels ? out->mBuffers[0].mNumberChannels : 1;
    const UInt32 frames = out->mBuffers[0].mDataByteSize / (chans0 * (UInt32)sizeof(float));
    for (UInt32 f = 0; f < frames; f++) {
        const double nx = t->x * t->c - t->y * t->s;
        const double ny = t->x * t->s + t->y * t->c;
        t->x = nx; t->y = ny;
        const float v = (float)ny * t->amp;
        for (UInt32 b = 0; b < out->mNumberBuffers; b++) {
            float *p = out->mBuffers[b].mData;
            const UInt32 ch = out->mBuffers[b].mNumberChannels ? out->mBuffers[b].mNumberChannels : 1;
            if (p == NULL || (f + 1) * ch * sizeof(float) > out->mBuffers[b].mDataByteSize) continue;
            for (UInt32 c = 0; c < ch; c++) p[f * ch + c] = v;
        }
    }
    const double r = 1.0 / sqrt(t->x * t->x + t->y * t->y);
    t->x *= r; t->y *= r;
    t->calls++;
    return noErr;
}

static int RunSelfTest(void) {
    const AudioObjectID dev = FindEQTDevice();
    if (dev == kAudioObjectUnknown) {
        printf("EQtargets Audio is not installed (no device with UID %s) — nothing to self-test.\n"
               "Install it with scripts/install-driver.sh.\n", EQT_DEVICE_UID);
        return kExitAbsent;
    }
    Ring ring;
    const int open = OpenRing(&ring);
    if (open != kExitOK) {
        printf("EQtargets Audio is present but its ring is not readable — the driver could not create shared memory.\n"
               "Check: log show --last 5m --predicate 'subsystem == \"%s\"'\n", EQT_DRIVER_BUNDLE_ID);
        return open == kExitAbsent ? kExitFail : open;
    }
    if (!EQTRingHeaderIsValid(ring.h)) { PrintHeader(&ring); return kExitFail; }

    Float64 rate = 0;
    GetProp(dev, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, sizeof rate, &rate);
    const double kFreq = 1000.0, kAmp = 0.1;   // -20 dBFS peak -> -23.01 dBFS RMS
    Tone tone = { 1.0, 0.0, cos(2.0 * M_PI * kFreq / rate), sin(2.0 * M_PI * kFreq / rate), (float)kAmp, 0 };
    printf("Self-test: 1 kHz @ -20 dBFS for 2 s into EQtargets Audio (device %u, %.0f Hz) — default output untouched.\n"
           "Note: if EQtargets is on and routing, you will hear the tone through the EQ.\n", (unsigned)dev, rate);

    AudioDeviceIOProcID procID = NULL;
    OSStatus err = AudioDeviceCreateIOProcID(dev, ToneIOProc, &tone, &procID);
    if (err != noErr) { printf("FAIL  AudioDeviceCreateIOProcID: %d\n", (int)err); return kExitFail; }
    const uint64_t g0 = EQTRingLoadGeneration(ring.h);
    err = AudioDeviceStart(dev, procID);
    if (err != noErr) {
        printf("FAIL  AudioDeviceStart: %d\n", (int)err);
        AudioDeviceDestroyIOProcID(dev, procID);
        return kExitFail;
    }
    usleep(400 * 1000);   // let IO settle (StartIO may have started a new timeline)
    const uint64_t tA = mach_absolute_time();
    const int64_t hA = EQTRingLoadWriteHead(ring.h);
    const uint64_t gA = EQTRingLoadGeneration(ring.h);
    usleep(1600 * 1000);
    const uint64_t tB = mach_absolute_time();
    const int64_t hB = EQTRingLoadWriteHead(ring.h);
    const uint64_t gB = EQTRingLoadGeneration(ring.h);
    const int64_t frames = (int64_t)fmin(rate * 0.15, 16384.0);
    float *buf = malloc((size_t)frames * 2 * sizeof(float));
    const bool copied = buf != NULL && RingCopyNewest(ring.h, buf, frames);
    const UInt32 calls = tone.calls;
    AudioDeviceStop(dev, procID);
    AudioDeviceDestroyIOProcID(dev, procID);

    int failures = 0;
#define CHECK(ok, ...) do { const bool _ok = (ok); printf("%s  ", _ok ? "PASS" : "FAIL"); printf(__VA_ARGS__); printf("\n"); failures += !_ok; } while (0)
    CHECK(calls > 0, "IOProc ran (%u callbacks)", (unsigned)calls);
    CHECK(EQTRingLoadIORunning(ring.h) == 1 || gB != g0 || hB > 0, "driver IO ran (generation %llu -> %llu)",
          (unsigned long long)g0, (unsigned long long)gB);
    const double fps = gA == gB ? (double)(hB - hA) / TicksToSeconds(tB - tA) : 0.0;
    CHECK(gA == gB && fabs(fps / rate - 1.0) < 0.05, "ring frames advance at %.0f frames/s (nominal %.0f)", fps, rate);
    CHECK(copied, "read the newest %lld frames back through the reader protocol", (long long)frames);
    if (copied) {
        const SignalStats s = Analyze(buf, frames, rate);
        const double wantDB = 20.0 * log10(kAmp / sqrt(2.0));
        CHECK(fabs(s.rmsDB[0] - wantDB) < 0.5 && fabs(s.rmsDB[1] - wantDB) < 0.5,
              "tone level L %.2f / R %.2f dBFS RMS (expected %.2f; other audio playing to the device skews this)",
              s.rmsDB[0], s.rmsDB[1], wantDB);
        CHECK(fabs(s.freqHz - kFreq) < 5.0, "tone frequency %.2f Hz (expected %.0f)", s.freqHz, kFreq);
    }
    free(buf);
#undef CHECK
    printf("%s\n", failures == 0 ? "SELFTEST PASSED" : "SELFTEST FAILED");
    return failures == 0 ? kExitOK : kExitFail;
}

// ================================================================ main

static void Usage(void) {
    fprintf(stderr,
            "usage: eqt-probe --devices | --ring [seconds] | --selftest\n"
            "exit:  0 ok, 1 check failed, 2 usage/system error, 3 driver not installed / ring absent\n");
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    gTicksPerSecond = 1.0e9 * (double)tb.denom / (double)tb.numer;

    if (argc < 2) { Usage(); return kExitUsage; }
    if (strcmp(argv[1], "--devices") == 0 && argc == 2) return RunDevices();
    if (strcmp(argv[1], "--ring") == 0 && argc <= 3) {
        const double seconds = argc == 3 ? atof(argv[2]) : 2.0;
        return RunRing(seconds > 0.2 ? seconds : 2.0);
    }
    if (strcmp(argv[1], "--selftest") == 0 && argc == 2) return RunSelfTest();
    Usage();
    return kExitUsage;
}
