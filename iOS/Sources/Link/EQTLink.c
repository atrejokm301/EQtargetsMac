//
//  EQTLink.c
//  EQtargets (iOS)
//
//  See EQTLink.h. Plain C on BSD sockets, so the same code runs in the
//  extension, the app and the logic tests, and a sandbox denial names the
//  system call that was refused.
//

#include "EQTLink.h"
#include "EQTIdentity.h"

#include <CommonCrypto/CommonHMAC.h>
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/semaphore.h>
#include <math.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <os/log.h>
#include <poll.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

static os_log_t LinkLog(void) {
    static _Atomic(os_log_t) cached = NULL;
    os_log_t l = atomic_load_explicit(&cached, memory_order_acquire);
    if (!l) {
        l = os_log_create(EQT_LOG_SUBSYSTEM, "link");
        atomic_store_explicit(&cached, l, memory_order_release);
    }
    return l;
}

static uint64_t MonotonicNs(void) { return clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW); }

static void SetNonBlocking(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) (void)fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

static void SetCommonSocketOptions(int fd) {
    int one = 1;
    // A write to a closed peer must return EPIPE, not kill the process.
    (void)setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
    (void)setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
}

static struct sockaddr_in LoopbackAddress(uint16_t port) {
    struct sockaddr_in a;
    memset(&a, 0, sizeof a);
    a.sin_len = sizeof a;
    a.sin_family = AF_INET;
    a.sin_port = htons(port);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    return a;
}

// MARK: - Handshake

// Both proofs cover both nonces, so a recorded answer can't be replayed. Their
// labels differ, so one side's proof can't be reflected back as the other's. And
// they cover this connection's addresses, so they can't be relayed through another.

#define AUTH_NONCE_BYTES  32u
#define AUTH_PROOF_BYTES  32u
#define AUTH_CHANNEL_BYTES 12u    /* client address + port, server address + port */
#define AUTH_HELLO_BYTES  (4u + AUTH_NONCE_BYTES)
#define AUTH_SERVER_BYTES (4u + AUTH_NONCE_BYTES + AUTH_PROOF_BYTES)
#define AUTH_CLIENT_BYTES (4u + AUTH_PROOF_BYTES)
_Static_assert(AUTH_PROOF_BYTES == CC_SHA256_DIGEST_LENGTH, "proofs are HMAC-SHA256");
_Static_assert(AUTH_HELLO_BYTES == AUTH_CLIENT_BYTES, "the app reads both messages with one buffer");

static const uint8_t kAuthHello[4]  = { 'E', 'Q', 'A', '1' };
static const uint8_t kAuthServer[4] = { 'E', 'Q', 'A', '2' };
static const uint8_t kAuthClient[4] = { 'E', 'Q', 'A', '3' };
static const char kAuthServerLabel[] = "EQtargets link server v1";
static const char kAuthClientLabel[] = "EQtargets link client v1";

/// The same twelve bytes at both ends of one TCP connection, and at no other.
static bool AuthChannelOf(int fd, bool isClient, uint8_t *out) {
    struct sockaddr_in local, remote;
    socklen_t localLength = sizeof local, remoteLength = sizeof remote;
    if (getsockname(fd, (struct sockaddr *)&local, &localLength) != 0
        || getpeername(fd, (struct sockaddr *)&remote, &remoteLength) != 0
        || local.sin_family != AF_INET || remote.sin_family != AF_INET) {
        return false;
    }
    const struct sockaddr_in *client = isClient ? &local : &remote;
    const struct sockaddr_in *server = isClient ? &remote : &local;
    memcpy(out, &client->sin_addr, 4);
    memcpy(out + 4, &client->sin_port, 2);
    memcpy(out + 6, &server->sin_addr, 4);
    memcpy(out + 10, &server->sin_port, 2);
    return true;
}

static void AuthProof(const uint8_t *key, const char *label, const uint8_t *channel,
                      const uint8_t *clientNonce, const uint8_t *serverNonce, uint8_t *out) {
    CCHmacContext c;
    CCHmacInit(&c, kCCHmacAlgSHA256, key, EQT_LINK_KEY_BYTES);
    CCHmacUpdate(&c, label, strlen(label));
    CCHmacUpdate(&c, channel, AUTH_CHANNEL_BYTES);
    CCHmacUpdate(&c, clientNonce, AUTH_NONCE_BYTES);
    CCHmacUpdate(&c, serverNonce, AUTH_NONCE_BYTES);
    CCHmacFinal(&c, out);
}

// MARK: - Codec

size_t EQTLinkChunkBytes(uint32_t frames) {
    return sizeof(EQTLinkChunkHeader) + (size_t)frames * EQT_LINK_CHANNELS * sizeof(float);
}

int EQTLinkHeaderIsValid(const EQTLinkChunkHeader *h) {
    if (h->magic != EQT_LINK_MAGIC || h->version != EQT_LINK_VERSION || h->channels != EQT_LINK_CHANNELS
        || h->startFrame < 0 || h->startFrame > ((int64_t)1 << 50)) {
        return 0;
    }
    if (h->frames == 0) return h->flags == EQT_LINK_FLAG_END_OF_STREAM;
    return h->flags == 0 && h->frames <= EQT_LINK_MAX_CHUNK_FRAMES;
}

size_t EQTLinkConsume(uint8_t *buffer, size_t *length, EQTLinkChunkFn fn, void *context) {
    const size_t n = *length;
    size_t off = 0, skipped = 0;
    while (n - off >= sizeof(EQTLinkChunkHeader)) {
        EQTLinkChunkHeader h;
        memcpy(&h, buffer + off, sizeof h);     // may be unaligned
        if (!EQTLinkHeaderIsValid(&h)) {
            off += 1;
            skipped += 1;
            continue;
        }
        const size_t total = EQTLinkChunkBytes(h.frames);
        if (n - off < total) break;             // payload still in flight
        fn(context, &h, buffer + off + sizeof h);
        off += total;
    }
    if (off > 0) {
        memmove(buffer, buffer + off, n - off);
        *length = n - off;
    }
    return skipped;
}

// MARK: - Ring writer

void EQTLinkRingFormat(EQTRingHeader *ring) {
    memset(ring, 0, EQT_RING_TOTAL_BYTES);
    ring->version = EQT_RING_VERSION;
    ring->channels = EQT_RING_CHANNELS;
    ring->capacityFrames = EQT_RING_CAPACITY_FRAMES;
    ring->headerBytes = EQT_RING_HEADER_BYTES;
    EQTRingStoreSampleRate(ring, EQT_LINK_SAMPLE_RATE);
    EQTRingStoreIOBufferFrames(ring, EQT_LINK_DEFAULT_RESERVE);
    EQTRingBumpGeneration(ring);
    EQTRingStoreMagic(ring, EQT_RING_MAGIC);    // published last
}

void EQTLinkRingWriterInit(EQTLinkRingWriter *w, EQTRingHeader *ring) {
    memset(w, 0, sizeof *w);
    w->ring = ring;
    w->reserveFrames = EQT_LINK_DEFAULT_RESERVE;
}

void EQTLinkRingWriterWrite(EQTLinkRingWriter *w, const EQTLinkChunkHeader *h, const uint8_t *payload) {
    EQTRingHeader *ring = w->ring;
    const int64_t mask = (int64_t)EQT_RING_CAPACITY_FRAMES - 1;
    float *samples = EQTRingSamples(ring);

    int64_t t = h->startFrame - w->base;
    // Moving backwards, or a gap too long to bridge with silence, is a new timeline.
    if (!w->open || t < w->head || t - w->head > (int64_t)EQT_LINK_MAX_GAP_FRAMES) {
        if (w->open && t > w->head) w->gapFrames += (uint64_t)(t - w->head);
        // Ring contract: generation first, then head = 0, then running.
        EQTRingBumpGeneration(ring);
        EQTRingStoreWriteHead(ring, 0);
        EQTRingStoreIORunning(ring, 1);
        w->base = h->startFrame;
        w->head = 0;
        w->open = 1;
        w->restarts += 1;
        t = 0;
    }

    if (t > w->head) {
        // A skipped stretch must read as silence, never as stale audio.
        const int64_t gap = t - w->head;
        for (int64_t f = w->head; f < t; f++) {
            const int64_t slot = f & mask;
            samples[slot * 2] = 0;
            samples[slot * 2 + 1] = 0;
        }
        w->gapFrames += (uint64_t)gap;
    }

    const uint32_t frames = h->frames;
    for (uint32_t i = 0; i < frames; i++) {
        const int64_t slot = (t + (int64_t)i) & mask;
        for (uint32_t c = 0; c < EQT_LINK_CHANNELS; c++) {
            float v;
            memcpy(&v, payload + ((size_t)i * EQT_LINK_CHANNELS + c) * sizeof(float), sizeof v);
            // One NaN would poison the IIR state until the next reset.
            if (!isfinite(v)) { v = 0; w->badSamples += 1; }
            else if (v > EQT_LINK_MAX_SAMPLE) v = EQT_LINK_MAX_SAMPLE;
            else if (v < -EQT_LINK_MAX_SAMPLE) v = -EQT_LINK_MAX_SAMPLE;
            samples[slot * 2 + c] = v;
        }
    }

    EQTRingStoreIOBufferFrames(ring, w->reserveFrames);
    EQTRingStoreLastWriteHostTime(ring, h->endHostTime);
    w->head = t + (int64_t)frames;
    EQTRingStoreWriteHead(ring, w->head);       // release: publishes the samples
}

void EQTLinkRingWriterClose(EQTLinkRingWriter *w) {
    if (!w->open) return;
    w->open = 0;
    EQTRingStoreIORunning(w->ring, 0);
}

// MARK: - Sender

#define SEND_RING_FRAMES 65536u     /* power of two, about 1.4 s at 48 kHz */
#define SEND_RING_MASK   (SEND_RING_FRAMES - 1u)
#define SEND_WAIT_NS     100000000u /* reconnect interval while audio is waiting */
/* Retry interval while nothing is playing. It backs off so a failed handshake can't
   keep an idle phone waking, but stays short enough that opening the app finds the
   link within seconds: until then the app says EQtargets isn't selected. The next
   push wakes the sender at once. */
#define SEND_IDLE_WAIT_MIN_S 2u
#define SEND_IDLE_WAIT_MAX_S 8u
#define SEND_AUDIO_RECENT_NS 1000000000ull
#define SEND_STALL_NS    2000000000ull  /* a send blocked this long: reconnect */
#define SEND_STALL_FRAMES 96000ull      /* 2 s of audio on one connection, unanswered */
#define SEND_ANSWER_WAIT_NS 200000000ull /* a crossed limit waits this long for an answer */
#define SEND_ANSWER_POLL_NS 50000000u   /* how often it looks during that wait */
#define SEND_PROOF_READ_NS 100000000ull
#define SEND_AUTH_WAIT_NS 250000000ull  /* how long the app gets to prove itself */
#define SEND_CONNECT_WAIT_NS 100000000ull
#define SEND_WAIT_SLICE_MS 20           /* a stop is never held up longer than this */
#define DELIVERY_ON  1u             /* the audio server is delivering */
#define DELIVERY_END 2u             /* it stopped: an end marker is still to be sent */

struct EQTLinkSender {
    uint16_t port;
    float *ring;
    uint8_t *tx;
    double ticksPerFrame;
    semaphore_t semaphore;
    pthread_t thread;
    bool threadLive;
    _Atomic bool running;

    // Audio thread -> sender thread.
    _Atomic int64_t writeFrame;
    _Atomic uint32_t stampSeq;
    _Atomic int64_t stampFrame;
    _Atomic uint64_t stampHost;
    _Atomic int wakeArmed;

    // Control threads -> sender thread. One word, so a start and a stop racing
    // each other can't leave it delivering with an end marker still requested.
    _Atomic uint32_t delivery;

    // Written once, before hasKey is set, and read only after it.
    uint8_t key[EQT_LINK_KEY_BYTES];
    _Atomic bool hasKey;

    // Sender thread only.
    int fd;
    int64_t readFrame;
    size_t txLength;
    size_t txOffset;
    uint32_t txFrames;
    uint64_t nextConnectNs;
    uint32_t idleWaitS;
    int64_t lastSeenWrite;
    uint64_t lastAudioNs;
    // Reachability is counted in audio, not time: short sounds with pauses between
    // them add up against a suspended app, and silence never counts against it.
    uint64_t unansweredFrames;  /* pushed since the last byte FROM the app */
    uint64_t framesAtConnect;   /* unansweredFrames when this connection began */
    uint64_t blockedSinceNs;    /* when send first stopped accepting bytes, or 0 */
    uint64_t nextProofReadNs;
    uint64_t verdictDueNs;      /* a limit was crossed: act at this time, or 0 */
    bool linkHasAudio;          /* this connection has been handed audio to answer */
    uint64_t unreachableAfterFrames;
    bool unreachableReported;
    EQTLinkUnreachableFn unreachableFn;
    void *unreachableContext;

    _Atomic uint64_t sentFrames;
    _Atomic uint64_t droppedFrames;
    _Atomic uint64_t connects;
    _Atomic uint64_t connectAttempts;
    _Atomic uint64_t wakeups;
    _Atomic int connected;
};

EQTLinkSender *EQTLinkSenderCreate(uint16_t port) {
    EQTLinkSender *s = calloc(1, sizeof *s);
    if (!s) return NULL;
    s->port = port;
    s->fd = -1;
    s->ring = calloc(SEND_RING_FRAMES * EQT_LINK_CHANNELS, sizeof(float));
    s->tx = malloc(EQTLinkChunkBytes(EQT_LINK_MAX_CHUNK_FRAMES));
    mach_timebase_info_data_t tb = {0, 0};
    mach_timebase_info(&tb);
    const double ticksPerNs = tb.numer ? (double)tb.denom / (double)tb.numer : 1.0;
    s->ticksPerFrame = 1e9 / EQT_LINK_SAMPLE_RATE * ticksPerNs;
    if (!s->ring || !s->tx ||
        semaphore_create(mach_task_self(), &s->semaphore, SYNC_POLICY_FIFO, 0) != KERN_SUCCESS) {
        free(s->ring);
        free(s->tx);
        free(s);
        return NULL;
    }
    return s;
}

void EQTLinkSenderDestroy(EQTLinkSender *s) {
    if (!s) return;
    EQTLinkSenderStop(s);
    semaphore_destroy(mach_task_self(), s->semaphore);
    free(s->ring);
    free(s->tx);
    free(s);
}

void EQTLinkSenderPush(EQTLinkSender *s, const float *in, uint32_t frames, uint32_t channels, uint64_t hostTime) {
    if (!in || frames == 0 || channels == 0) return;
    int64_t w = atomic_load_explicit(&s->writeFrame, memory_order_relaxed);
    if (frames > SEND_RING_FRAMES) {            // cannot fit: keep the newest audio
        const uint32_t skip = frames - SEND_RING_FRAMES;
        in += (size_t)skip * channels;
        frames = SEND_RING_FRAMES;
        w += skip;
    }
    for (uint32_t i = 0; i < frames; i++) {
        const uint32_t slot = (uint32_t)((uint64_t)(w + (int64_t)i) & SEND_RING_MASK);
        const float left = in[(size_t)i * channels];
        s->ring[slot * 2] = left;
        s->ring[slot * 2 + 1] = channels > 1 ? in[(size_t)i * channels + 1] : left;
    }
    const int64_t end = w + (int64_t)frames;

    // Seqlock: the frame and its time must be read as a pair.
    const uint32_t q = atomic_load_explicit(&s->stampSeq, memory_order_relaxed);
    atomic_store_explicit(&s->stampSeq, q + 1, memory_order_relaxed);
    atomic_thread_fence(memory_order_release);
    atomic_store_explicit(&s->stampFrame, end, memory_order_relaxed);
    atomic_store_explicit(&s->stampHost, hostTime, memory_order_relaxed);
    atomic_store_explicit(&s->stampSeq, q + 2, memory_order_release);

    atomic_store_explicit(&s->writeFrame, end, memory_order_release);
    // Pairs with the fence after the sender thread arms wakeArmed. Each side
    // stores, then reads the other's flag: without a full barrier both can miss.
    atomic_thread_fence(memory_order_seq_cst);
    if (atomic_exchange_explicit(&s->wakeArmed, 0, memory_order_acq_rel)) {
        semaphore_signal(s->semaphore);
    }
}

/// Host time at which `frame` was written, derived from the newest stamp.
static uint64_t SenderHostTime(const EQTLinkSender *s, int64_t frame) {
    int64_t stampFrame = 0;
    uint64_t stampHost = 0;
    for (int tries = 0; tries < 16; tries++) {
        const uint32_t q1 = atomic_load_explicit(&s->stampSeq, memory_order_acquire);
        if (q1 & 1u) continue;
        stampFrame = atomic_load_explicit(&s->stampFrame, memory_order_relaxed);
        stampHost = atomic_load_explicit(&s->stampHost, memory_order_relaxed);
        atomic_thread_fence(memory_order_acquire);
        if (atomic_load_explicit(&s->stampSeq, memory_order_relaxed) == q1) break;
    }
    if (stampHost == 0) return 0;
    const int64_t behind = stampFrame - frame;
    if (behind <= 0) return stampHost;
    const uint64_t back = (uint64_t)((double)behind * s->ticksPerFrame);
    return back < stampHost ? stampHost - back : 0;
}

static void SenderDisconnect(EQTLinkSender *s) {
    if (s->fd >= 0) close(s->fd);
    s->fd = -1;
    s->txLength = s->txOffset = 0;
    s->txFrames = 0;
    s->blockedSinceNs = 0;
    s->verdictDueNs = 0;
    atomic_store_explicit(&s->connected, 0, memory_order_relaxed);
}

/// Handshake messages are tiny and the socket is new: they fit, or the peer is gone.
static bool AuthSend(int fd, const uint8_t *bytes, size_t length) {
    for (;;) {
        const ssize_t n = send(fd, bytes, length, 0);
        if (n == (ssize_t)length) return true;
        if (n < 0 && errno == EINTR) continue;
        return false;
    }
}

/// Waits for `events` in short slices, so stopping the sender is never held up.
/// Returns true only if the socket became ready.
static bool SenderWait(const EQTLinkSender *s, int fd, short events, uint64_t deadline) {
    for (;;) {
        if (!atomic_load_explicit(&s->running, memory_order_acquire)) return false;
        const uint64_t t = MonotonicNs();
        if (t >= deadline) return false;
        const uint64_t leftMs = (deadline - t) / 1000000ull + 1;
        struct pollfd p = { .fd = fd, .events = events, .revents = 0 };
        const int ready = poll(&p, 1, leftMs < SEND_WAIT_SLICE_MS ? (int)leftMs : SEND_WAIT_SLICE_MS);
        if (ready > 0) return true;
        if (ready < 0 && errno != EINTR) return false;
    }
}

/// Reads exactly `length` bytes, or gives up at the time limit.
static bool AuthRead(const EQTLinkSender *s, int fd, uint8_t *out, size_t length, uint64_t limitNs) {
    const uint64_t deadline = MonotonicNs() + limitNs;
    size_t have = 0;
    while (have < length) {
        if (!SenderWait(s, fd, POLLIN, deadline)) return false;
        const ssize_t n = recv(fd, out + have, length - have, 0);
        if (n > 0) {
            have += (size_t)n;
        } else if (n == 0 || (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK)) {
            return false;
        }
    }
    return true;
}

/// The other end must prove it holds the key before it gets any audio. A suspended
/// app can't answer either, so this also stops audio queueing up in its socket.
static bool SenderAuthenticate(const EQTLinkSender *s, int fd) {
    uint8_t hello[AUTH_HELLO_BYTES], reply[AUTH_SERVER_BYTES];
    uint8_t expected[AUTH_PROOF_BYTES], proof[AUTH_CLIENT_BYTES], channel[AUTH_CHANNEL_BYTES];
    if (!AuthChannelOf(fd, true, channel)) return false;
    memcpy(hello, kAuthHello, sizeof kAuthHello);
    arc4random_buf(hello + 4, AUTH_NONCE_BYTES);
    if (!AuthSend(fd, hello, sizeof hello) || !AuthRead(s, fd, reply, sizeof reply, SEND_AUTH_WAIT_NS)) return false;
    if (memcmp(reply, kAuthServer, sizeof kAuthServer) != 0) return false;

    const uint8_t *serverNonce = reply + 4;
    AuthProof(s->key, kAuthServerLabel, channel, hello + 4, serverNonce, expected);
    if (timingsafe_bcmp(expected, serverNonce + AUTH_NONCE_BYTES, AUTH_PROOF_BYTES) != 0) return false;

    memcpy(proof, kAuthClient, sizeof kAuthClient);
    AuthProof(s->key, kAuthClientLabel, channel, hello + 4, serverNonce, proof + 4);
    return AuthSend(fd, proof, sizeof proof);
}

static void SenderConnect(EQTLinkSender *s) {
    if (!atomic_load_explicit(&s->hasKey, memory_order_acquire)) return;    // nothing to prove itself with
    const uint64_t now = MonotonicNs();
    if (now < s->nextConnectNs) return;
    s->nextConnectNs = now + SEND_WAIT_NS;
    atomic_fetch_add_explicit(&s->connectAttempts, 1, memory_order_relaxed);

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        os_log_error(LinkLog(), "sender socket failed errno=%{public}d", errno);
        return;
    }
    SetCommonSocketOptions(fd);
    // Non-blocking: a suspended app can leave connections queued with nobody
    // accepting them, and a blocking connect here would hang deactivation.
    SetNonBlocking(fd);
    struct sockaddr_in a = LoopbackAddress(s->port);
    if (connect(fd, (const struct sockaddr *)&a, sizeof a) != 0) {
        if (errno != EINPROGRESS) {
            close(fd);
            return;
        }
        int err = 0;
        socklen_t len = sizeof err;
        if (!SenderWait(s, fd, POLLOUT, MonotonicNs() + SEND_CONNECT_WAIT_NS)
            || getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) != 0 || err != 0) {
            close(fd);
            return;
        }
    }
    // No audio leaves this process until the app has proved it holds the key.
    if (!SenderAuthenticate(s, fd)) {
        close(fd);
        return;
    }
    s->fd = fd;
    // Start at the present: audio queued while disconnected is already late.
    s->readFrame = atomic_load_explicit(&s->writeFrame, memory_order_acquire);
    s->txLength = s->txOffset = 0;
    s->txFrames = 0;
    s->framesAtConnect = s->unansweredFrames;
    s->linkHasAudio = false;
    s->nextProofReadNs = 0;
    atomic_fetch_add_explicit(&s->connects, 1, memory_order_relaxed);
    atomic_store_explicit(&s->connected, 1, memory_order_relaxed);
    os_log(LinkLog(), "sender connected port=%{public}d", s->port);
}

/// Sends the rest of the pending chunk. Counted in BYTES: send can stop inside a
/// float, and resuming on a sample boundary would shift every later sample.
static bool SenderFlush(EQTLinkSender *s) {
    while (s->txOffset < s->txLength) {
        const ssize_t n = send(s->fd, s->tx + s->txOffset, s->txLength - s->txOffset, 0);
        if (n > 0) {
            s->txOffset += (size_t)n;
            s->blockedSinceNs = 0;
            continue;
        }
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            if (s->blockedSinceNs == 0) s->blockedSinceNs = MonotonicNs();
            struct pollfd p = { .fd = s->fd, .events = POLLOUT, .revents = 0 };
            (void)poll(&p, 1, 20);
            return false;
        }
        os_log_error(LinkLog(), "sender send failed errno=%{public}d", errno);
        SenderDisconnect(s);
        return false;
    }
    if (s->txFrames) {
        atomic_fetch_add_explicit(&s->sentFrames, s->txFrames, memory_order_relaxed);
        s->txFrames = 0;
        s->linkHasAudio = true;
    }
    s->txLength = s->txOffset = 0;
    return true;
}

#if EQT_TEST_HOOKS
/// Runs on the sender thread when the pump has just found nothing left to send.
static _Atomic(void (*)(EQTLinkSender *)) gTestPumpDrained = NULL;
void EQTTestSetPumpDrainedHook(void (*hook)(EQTLinkSender *)) {
    atomic_store_explicit(&gTestPumpDrained, hook, memory_order_release);
}
#endif

static void SenderPump(EQTLinkSender *s) {
    if (!SenderFlush(s)) return;
    for (;;) {
        const int64_t w = atomic_load_explicit(&s->writeFrame, memory_order_acquire);
        int64_t r = s->readFrame;
        if (w <= r) {
#if EQT_TEST_HOOKS
            void (*drained)(EQTLinkSender *) = atomic_load_explicit(&gTestPumpDrained, memory_order_acquire);
            if (drained) drained(s);
#endif
            // Read the stop request, THEN look for audio again: anything pushed
            // before the stop is visible now, so the marker can't overtake it.
            if ((atomic_load_explicit(&s->delivery, memory_order_acquire) & DELIVERY_END) != 0) {
                if (atomic_load_explicit(&s->writeFrame, memory_order_acquire) > r) continue;
                if (atomic_fetch_and_explicit(&s->delivery, ~DELIVERY_END, memory_order_acq_rel) & DELIVERY_END) {
                    EQTLinkChunkHeader end;
                    memset(&end, 0, sizeof end);
                    end.magic = EQT_LINK_MAGIC;
                    end.version = EQT_LINK_VERSION;
                    end.channels = EQT_LINK_CHANNELS;
                    end.flags = EQT_LINK_FLAG_END_OF_STREAM;
                    end.startFrame = r;
                    memcpy(s->tx, &end, sizeof end);
                    s->txLength = sizeof end;
                    s->txOffset = 0;
                    s->txFrames = 0;
                    (void)SenderFlush(s);
                }
            }
            return;
        }
        // Keep a margin so the audio thread is not writing the frames being copied.
        const int64_t limit = (int64_t)SEND_RING_FRAMES - (int64_t)EQT_LINK_MAX_CHUNK_FRAMES;
        if (w - r > limit) {
            atomic_fetch_add_explicit(&s->droppedFrames, (uint64_t)(w - limit - r), memory_order_relaxed);
            r = w - limit;
        }
        const int64_t avail = w - r;
        const uint32_t n = avail < (int64_t)EQT_LINK_MAX_CHUNK_FRAMES ? (uint32_t)avail : EQT_LINK_MAX_CHUNK_FRAMES;

        float *payload = (float *)(void *)(s->tx + sizeof(EQTLinkChunkHeader));
        for (uint32_t i = 0; i < n; i++) {
            const uint32_t slot = (uint32_t)((uint64_t)(r + (int64_t)i) & SEND_RING_MASK);
            payload[i * 2] = s->ring[slot * 2];
            payload[i * 2 + 1] = s->ring[slot * 2 + 1];
        }
        const int64_t after = atomic_load_explicit(&s->writeFrame, memory_order_acquire);
        // `limit`, not the ring size: the audio thread writes samples before it
        // publishes them, so frames just past `after` may already be changing.
        if (after - r > limit) {
            atomic_fetch_add_explicit(&s->droppedFrames, (uint64_t)n, memory_order_relaxed);
            s->readFrame = after - limit;
            continue;
        }

        EQTLinkChunkHeader h;
        memset(&h, 0, sizeof h);
        h.magic = EQT_LINK_MAGIC;
        h.version = EQT_LINK_VERSION;
        h.channels = EQT_LINK_CHANNELS;
        h.frames = n;
        h.startFrame = r;
        h.endHostTime = SenderHostTime(s, r + (int64_t)n);
        memcpy(s->tx, &h, sizeof h);
        s->txLength = EQTLinkChunkBytes(n);
        s->txOffset = 0;
        s->txFrames = n;
        s->readFrame = r + (int64_t)n;
        if (!SenderFlush(s)) return;
    }
}

/// Reads the app's answers. Only these prove it is alive: `connect` and `send`
/// both succeed against a suspended app, up to the size of the socket buffers.
static void SenderReadProof(EQTLinkSender *s, uint64_t now) {
    if (now < s->nextProofReadNs) return;
    s->nextProofReadNs = now + SEND_PROOF_READ_NS;
    uint8_t answers[64];
    // Bounded: a peer that never stops writing must not hold this thread here.
    for (int i = 0; i < 4; i++) {
        const ssize_t n = recv(s->fd, answers, sizeof answers, 0);
        if (n > 0) {
            s->unansweredFrames = 0;
            s->framesAtConnect = 0;
            s->unreachableReported = false;
            continue;
        }
        if (n < 0 && errno == EINTR) continue;
        if (n == 0 || (errno != EAGAIN && errno != EWOULDBLOCK)) SenderDisconnect(s);
        return;
    }
}

static bool SenderStalled(const EQTLinkSender *s) {
    return s->fd >= 0 && s->unansweredFrames - s->framesAtConnect >= SEND_STALL_FRAMES;
}

static bool SenderReportDue(const EQTLinkSender *s) {
    return s->unreachableFn && !s->unreachableReported
           && s->unansweredFrames >= s->unreachableAfterFrames;
}

/// Audio is going unanswered. Left alone, every app on the phone stays silent
/// with EQtargets still selected.
static void SenderCheckReachable(EQTLinkSender *s, uint64_t now) {
    // Not tied to audio moving: a blocked send would otherwise spin on an idle phone.
    if (s->fd >= 0 && s->blockedSinceNs != 0 && now > s->blockedSinceNs
        && now - s->blockedSinceNs >= SEND_STALL_NS) {
        SenderDisconnect(s);
    }
    if (!SenderStalled(s) && !SenderReportDue(s)) {
        s->verdictDueNs = 0;
        return;
    }
    if (s->fd >= 0) {
        // The app can only answer audio it was given, so a link that has carried
        // none can't be judged yet. A blocked send is still caught above.
        if (!s->linkHasAudio) {
            s->verdictDueNs = 0;
            return;
        }
        // Even then it needs a moment. The thread loop reads again before each look.
        if (s->verdictDueNs == 0) s->verdictDueNs = now + SEND_ANSWER_WAIT_NS;
        if (now < s->verdictDueNs) {
            s->nextProofReadNs = 0;
            return;
        }
    }
    s->verdictDueNs = 0;
    if (SenderStalled(s)) SenderDisconnect(s);
    if (SenderReportDue(s)) {
        s->unreachableReported = true;
        s->unreachableFn(s->unreachableContext);
    }
}

static void *SenderThread(void *arg) {
    EQTLinkSender *s = arg;
    pthread_setname_np("com.eqtargets.link.send");
    while (atomic_load_explicit(&s->running, memory_order_acquire)) {
        atomic_fetch_add_explicit(&s->wakeups, 1, memory_order_relaxed);
        const uint64_t now = MonotonicNs();
        const int64_t written = atomic_load_explicit(&s->writeFrame, memory_order_acquire);
        if (written != s->lastSeenWrite) {
            s->unansweredFrames += (uint64_t)(written - s->lastSeenWrite);
            s->lastSeenWrite = written;
            s->lastAudioNs = now;
        }
        const bool audioMoving = s->lastAudioNs != 0 && now - s->lastAudioNs < SEND_AUDIO_RECENT_NS;
        const bool wantsLink = (atomic_load_explicit(&s->delivery, memory_order_acquire) & DELIVERY_ON) != 0 || audioMoving;

        if (s->fd < 0 && wantsLink) SenderConnect(s);
        if (s->fd >= 0) SenderReadProof(s, now);
        if (s->fd >= 0) SenderPump(s);
        SenderCheckReachable(s, now);

        const bool connected = s->fd >= 0;
        // While audio flows with no connection, the timer alone drives retries,
        // so the audio thread does not wake this thread every cycle. In every
        // other sleep, the next push has to wake it.
        const bool pushWakes = connected || !audioMoving;
        atomic_store_explicit(&s->wakeArmed, pushWakes ? 1 : 0, memory_order_release);
        atomic_thread_fence(memory_order_seq_cst);      // see EQTLinkSenderPush
        const int64_t latest = atomic_load_explicit(&s->writeFrame, memory_order_acquire);
        const bool flushing = connected && s->txOffset < s->txLength;
        const bool pending = connected
            ? (latest > s->readFrame || (atomic_load_explicit(&s->delivery, memory_order_acquire) & DELIVERY_END) != 0)
            : (pushWakes && latest != s->lastSeenWrite);
        if (!flushing && !pending && atomic_load_explicit(&s->running, memory_order_acquire)) {
            if (s->verdictDueNs != 0) {
                const mach_timespec_t look = { 0, SEND_ANSWER_POLL_NS };
                (void)semaphore_timedwait(s->semaphore, look);
            } else if (connected || !wantsLink) {
                // Nothing to do until audio, a delivery change or a stop signals.
                // A selected but idle output must not wake the phone.
                (void)semaphore_wait(s->semaphore);
            } else if (audioMoving) {       // retry fast while audio is waiting
                const mach_timespec_t wait = { 0, SEND_WAIT_NS };
                (void)semaphore_timedwait(s->semaphore, wait);
            } else {                        // and ever more slowly while nothing plays
                const mach_timespec_t wait = { s->idleWaitS, 0 };
                if (semaphore_timedwait(s->semaphore, wait) == KERN_OPERATION_TIMED_OUT) {
                    const uint32_t next = s->idleWaitS * 2u;
                    s->idleWaitS = next < SEND_IDLE_WAIT_MAX_S ? next : SEND_IDLE_WAIT_MAX_S;
                }
            }
        }
        atomic_store_explicit(&s->wakeArmed, 0, memory_order_release);
    }
    SenderDisconnect(s);
    return NULL;
}

int EQTLinkSenderStart(EQTLinkSender *s) {
    if (s->threadLive) return 0;
    atomic_store_explicit(&s->running, true, memory_order_release);
    atomic_store_explicit(&s->delivery, DELIVERY_ON, memory_order_release);
    s->nextConnectNs = 0;
    s->idleWaitS = SEND_IDLE_WAIT_MIN_S;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_set_qos_class_np(&attr, QOS_CLASS_USER_INTERACTIVE, 0);
    const int rc = pthread_create(&s->thread, &attr, SenderThread, s);
    pthread_attr_destroy(&attr);
    if (rc != 0) {
        atomic_store_explicit(&s->running, false, memory_order_release);
        os_log_error(LinkLog(), "sender thread failed rc=%{public}d", rc);
        return rc;
    }
    s->threadLive = true;
    return 0;
}

void EQTLinkSenderStop(EQTLinkSender *s) {
    if (!s->threadLive) return;
    atomic_store_explicit(&s->running, false, memory_order_release);
    semaphore_signal(s->semaphore);
    pthread_join(s->thread, NULL);
    s->threadLive = false;
}

void EQTLinkSenderSetUnreachableHandler(EQTLinkSender *s, double seconds,
                                        EQTLinkUnreachableFn fn, void *context) {
    s->unreachableAfterFrames = (uint64_t)(seconds * EQT_LINK_SAMPLE_RATE);
    s->unreachableContext = context;
    s->unreachableFn = fn;
}

void EQTLinkSenderSetDelivering(EQTLinkSender *s, int delivering) {
    const bool on = delivering != 0;
    // Set only here, never by the audio thread, so a push can't cancel the marker.
    uint32_t old = atomic_load_explicit(&s->delivery, memory_order_acquire);
    do {
        if (((old & DELIVERY_ON) != 0) == on) return;
    } while (!atomic_compare_exchange_weak_explicit(&s->delivery, &old, on ? DELIVERY_ON : DELIVERY_END,
                                                    memory_order_acq_rel, memory_order_acquire));
    semaphore_signal(s->semaphore);
}

void EQTLinkSenderSetKey(EQTLinkSender *s, const uint8_t *key) {
    if (atomic_load_explicit(&s->hasKey, memory_order_acquire)) return;
    memcpy(s->key, key, EQT_LINK_KEY_BYTES);
    atomic_store_explicit(&s->hasKey, true, memory_order_release);
    semaphore_signal(s->semaphore);     // it may be waiting to connect
}

void EQTLinkSenderGetStats(const EQTLinkSender *s, EQTLinkSenderStats *out) {
    out->pushedFrames = (uint64_t)atomic_load_explicit(&s->writeFrame, memory_order_relaxed);
    out->sentFrames = atomic_load_explicit(&s->sentFrames, memory_order_relaxed);
    out->droppedFrames = atomic_load_explicit(&s->droppedFrames, memory_order_relaxed);
    out->connects = atomic_load_explicit(&s->connects, memory_order_relaxed);
    out->connectAttempts = atomic_load_explicit(&s->connectAttempts, memory_order_relaxed);
    out->wakeups = atomic_load_explicit(&s->wakeups, memory_order_relaxed);
    out->connected = atomic_load_explicit(&s->connected, memory_order_relaxed);
}

// MARK: - Receiver

#define RX_BUFFER_BYTES     65536u
#define RX_PROBE_NS         (5ull * 1000000000ull)  /* listener health check */
#define RX_RELISTEN_NS      (1ull * 1000000000ull)
#define RX_AUTH_WAIT_NS     500000000ull            /* a caller gets this long to prove itself */
#define RX_AUTH_MIN_NS      20000000ull             /* a newer caller can't displace one this young */
#define RX_ACCEPT_INTERVAL_NS 31250000ull           /* callers admitted: 32 a second, sustained */
#define RX_ACCEPT_BURST_NS  218750000ull            /* ...after a short burst */
#define RX_ACK_INTERVAL_NS  250000000ull            /* proof of life to the extension */

_Static_assert(RX_BUFFER_BYTES > sizeof(EQTLinkChunkHeader) + EQT_LINK_MAX_CHUNK_FRAMES * EQT_LINK_CHANNELS * sizeof(float),
               "the receive buffer must hold a whole chunk");

struct EQTLinkReceiver {
    uint16_t port;
    uint8_t *rx;
    size_t rxLength;
    int listenFd;
    int peerFd;
    int wakeFds[2];
    pthread_t thread;
    bool threadLive;
    _Atomic bool running;
    uint64_t lastAckNs;
    bool ackDue;
    uint64_t nextProbeNs;
    uint64_t nextListenNs;
    EQTLinkRingWriter writer;

    // Written once, before hasKey is set, and read only after it.
    uint8_t key[EQT_LINK_KEY_BYTES];
    _Atomic bool hasKey;
    // A caller still proving itself. It has no effect on the stream until it has.
    int pendingFd;
    int pendingStage;           /* 0: waiting for its hello, 1: for its proof */
    size_t pendingHave;
    uint64_t pendingDeadlineNs;
    uint8_t pendingIn[AUTH_HELLO_BYTES];
    uint8_t clientNonce[AUTH_NONCE_BYTES];
    uint8_t serverNonce[AUTH_NONCE_BYTES];
    uint8_t pendingChannel[AUTH_CHANNEL_BYTES];
    uint64_t acceptPaceNs;      /* rate limit: when the admitted callers would have run out */
    uint64_t nextAcceptNs;      /* the listener is left alone until then */

    _Atomic uint32_t requestedReserve;
    _Atomic uint64_t receivedFrames;
    _Atomic uint64_t peerFrames;
    _Atomic uint64_t skippedBytes;
    _Atomic uint64_t badSamples;
    _Atomic uint64_t gapFrames;
    _Atomic uint64_t connections;
    _Atomic uint64_t relistens;
    _Atomic uint64_t rejectedCallers;
    _Atomic int listening;
    _Atomic int hasPeer;
};

EQTLinkReceiver *EQTLinkReceiverCreate(uint16_t port, EQTRingHeader *ring) {
    EQTLinkReceiver *r = calloc(1, sizeof *r);
    if (!r) return NULL;
    r->port = port;
    r->listenFd = r->peerFd = r->pendingFd = -1;
    r->wakeFds[0] = r->wakeFds[1] = -1;
    r->rx = malloc(RX_BUFFER_BYTES);
    if (!r->rx || pipe(r->wakeFds) != 0) {
        free(r->rx);
        free(r);
        return NULL;
    }
    SetNonBlocking(r->wakeFds[0]);
    SetNonBlocking(r->wakeFds[1]);
    EQTLinkRingWriterInit(&r->writer, ring);
    atomic_store_explicit(&r->requestedReserve, EQT_LINK_DEFAULT_RESERVE, memory_order_relaxed);
    return r;
}

void EQTLinkReceiverDestroy(EQTLinkReceiver *r) {
    if (!r) return;
    EQTLinkReceiverStop(r);
    close(r->wakeFds[0]);
    close(r->wakeFds[1]);
    free(r->rx);
    free(r);
}

static void ReceiverOnChunk(void *context, const EQTLinkChunkHeader *h, const uint8_t *payload) {
    EQTLinkReceiver *r = context;
    if (h->frames == 0) {               // the audio server stopped delivering
        EQTLinkRingWriterClose(&r->writer);
        return;
    }
    r->ackDue = true;
    r->writer.reserveFrames = atomic_load_explicit(&r->requestedReserve, memory_order_relaxed);
    EQTLinkRingWriterWrite(&r->writer, h, payload);
    atomic_fetch_add_explicit(&r->receivedFrames, h->frames, memory_order_relaxed);
    atomic_fetch_add_explicit(&r->peerFrames, h->frames, memory_order_relaxed);
}

static void ReceiverPublishWriterStats(EQTLinkReceiver *r) {
    atomic_store_explicit(&r->badSamples, r->writer.badSamples, memory_order_relaxed);
    atomic_store_explicit(&r->gapFrames, r->writer.gapFrames, memory_order_relaxed);
}

static void ReceiverDropPeer(EQTLinkReceiver *r) {
    if (r->peerFd >= 0) close(r->peerFd);
    r->peerFd = -1;
    r->rxLength = 0;
    EQTLinkRingWriterClose(&r->writer);
    atomic_store_explicit(&r->hasPeer, 0, memory_order_relaxed);
}

/// A defunct connection may never signal poll either.
static void ReceiverCheckPeer(EQTLinkReceiver *r) {
    if (r->peerFd < 0) return;
    int e = 0;
    socklen_t l = sizeof e;
    if (getsockopt(r->peerFd, SOL_SOCKET, SO_ERROR, &e, &l) != 0) e = errno ? errno : EBADF;
    if (e != 0) {
        os_log_error(LinkLog(), "peer socket unusable errno=%{public}d", e);
        ReceiverDropPeer(r);
    }
}

static void ReceiverCloseListener(EQTLinkReceiver *r) {
    if (r->listenFd >= 0) close(r->listenFd);
    r->listenFd = -1;
    atomic_store_explicit(&r->listening, 0, memory_order_relaxed);
}

static int ReceiverOpenListener(EQTLinkReceiver *r) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return errno;
    int one = 1;
    (void)setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    (void)setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
    struct sockaddr_in a = LoopbackAddress(r->port);    // never reachable from the network
    if (bind(fd, (const struct sockaddr *)&a, sizeof a) != 0 || listen(fd, 6) != 0) {
        const int e = errno;
        close(fd);
        return e ? e : EIO;
    }
    SetNonBlocking(fd);
    r->listenFd = fd;
    atomic_store_explicit(&r->listening, 1, memory_order_relaxed);
    os_log(LinkLog(), "receiver listening port=%{public}d", r->port);
    return 0;
}

/// iOS can mark a suspended app's sockets defunct. A defunct listener never
/// signals readable and answers new connections with a reset, so it has to be
/// checked for directly: it leaves EBADF in SO_ERROR.
static void ReceiverCheckListener(EQTLinkReceiver *r) {
    if (r->listenFd < 0) return;
    int e = 0;
    socklen_t l = sizeof e;
    if (getsockopt(r->listenFd, SOL_SOCKET, SO_ERROR, &e, &l) != 0) e = errno ? errno : EBADF;
    if (e != 0) {
        os_log_error(LinkLog(), "listener unusable errno=%{public}d, rebuilding", e);
        ReceiverCloseListener(r);
        r->nextListenNs = 0;
        atomic_fetch_add_explicit(&r->relistens, 1, memory_order_relaxed);
    }
}

static void ReceiverDropPending(EQTLinkReceiver *r, bool rejected) {
    if (r->pendingFd < 0) return;
    close(r->pendingFd);
    r->pendingFd = -1;
    r->pendingHave = 0;
    r->pendingStage = 0;
    if (rejected) atomic_fetch_add_explicit(&r->rejectedCallers, 1, memory_order_relaxed);
}

#if EQT_TEST_HOOKS
/// Makes every accept fail with this error, and counts the attempts.
static _Atomic int gTestAcceptError = 0;
static _Atomic uint64_t gTestAcceptCalls = 0;
void EQTTestSetAcceptError(int error) {
    atomic_store_explicit(&gTestAcceptError, error, memory_order_relaxed);
}
uint64_t EQTTestAcceptCalls(void) {
    return atomic_load_explicit(&gTestAcceptCalls, memory_order_relaxed);
}
#endif

static int ReceiverAcceptCall(const EQTLinkReceiver *r) {
#if EQT_TEST_HOOKS
    atomic_fetch_add_explicit(&gTestAcceptCalls, 1, memory_order_relaxed);
    const int failure = atomic_load_explicit(&gTestAcceptError, memory_order_relaxed);
    if (failure != 0) {
        errno = failure;
        return -1;
    }
#endif
    return accept(r->listenFd, NULL, NULL);
}

static void ReceiverAccept(EQTLinkReceiver *r, uint64_t now) {
    const int c = ReceiverAcceptCall(r);
    if (c < 0) {
        const int e = errno;
        if (e == EAGAIN || e == EWOULDBLOCK) return;
        // A queue it can't drain keeps the listener readable. Don't spin on it.
        r->nextAcceptNs = now + RX_AUTH_MIN_NS;
        if (e != EINTR && e != ECONNABORTED) ReceiverCheckListener(r);
        return;
    }
    // A flood costs a bounded amount of work, and a caller gets long enough to
    // finish before the next one can take its place.
    r->acceptPaceNs = (r->acceptPaceNs > now ? r->acceptPaceNs : now) + RX_ACCEPT_INTERVAL_NS;
    const uint64_t paced = r->acceptPaceNs > RX_ACCEPT_BURST_NS ? r->acceptPaceNs - RX_ACCEPT_BURST_NS : 0;
    const uint64_t settled = now + RX_AUTH_MIN_NS;
    r->nextAcceptNs = paced > settled ? paced : settled;

    // One caller proves itself at a time. The newest takes the slot, so a caller
    // that goes quiet can't hold the door shut against the real extension.
    ReceiverDropPending(r, true);
    if (!AuthChannelOf(c, false, r->pendingChannel)) {
        close(c);
        atomic_fetch_add_explicit(&r->rejectedCallers, 1, memory_order_relaxed);
        return;
    }
    SetCommonSocketOptions(c);
    SetNonBlocking(c);
    r->pendingFd = c;
    r->pendingDeadlineNs = now + RX_AUTH_WAIT_NS;
}

/// The caller holds the key, so it is the extension. Any older connection is dead.
static void ReceiverPromotePending(EQTLinkReceiver *r) {
    const int c = r->pendingFd;
    r->pendingFd = -1;
    r->pendingHave = 0;
    r->pendingStage = 0;
    if (r->peerFd >= 0) ReceiverDropPeer(r);
    r->peerFd = c;
    r->rxLength = 0;
    r->lastAckNs = 0;
    r->ackDue = false;
    atomic_store_explicit(&r->peerFrames, 0, memory_order_relaxed);
    atomic_fetch_add_explicit(&r->connections, 1, memory_order_relaxed);
    atomic_store_explicit(&r->hasPeer, 1, memory_order_relaxed);
    os_log(LinkLog(), "receiver accepted a peer");
}

static void ReceiverAuthStep(EQTLinkReceiver *r) {
    const ssize_t n = recv(r->pendingFd, r->pendingIn + r->pendingHave, AUTH_HELLO_BYTES - r->pendingHave, 0);
    if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) return;
    if (n <= 0) {
        ReceiverDropPending(r, true);
        return;
    }
    r->pendingHave += (size_t)n;
    if (r->pendingHave < AUTH_HELLO_BYTES) return;
    r->pendingHave = 0;

    if (r->pendingStage == 0) {
        if (!atomic_load_explicit(&r->hasKey, memory_order_acquire)
            || memcmp(r->pendingIn, kAuthHello, sizeof kAuthHello) != 0) {
            ReceiverDropPending(r, true);
            return;
        }
        memcpy(r->clientNonce, r->pendingIn + 4, AUTH_NONCE_BYTES);
        arc4random_buf(r->serverNonce, AUTH_NONCE_BYTES);
        uint8_t reply[AUTH_SERVER_BYTES];
        memcpy(reply, kAuthServer, sizeof kAuthServer);
        memcpy(reply + 4, r->serverNonce, AUTH_NONCE_BYTES);
        AuthProof(r->key, kAuthServerLabel, r->pendingChannel, r->clientNonce, r->serverNonce, reply + 4 + AUTH_NONCE_BYTES);
        if (send(r->pendingFd, reply, sizeof reply, MSG_DONTWAIT) != (ssize_t)sizeof reply) {
            ReceiverDropPending(r, true);
            return;
        }
        r->pendingStage = 1;
        return;
    }

    uint8_t expected[AUTH_PROOF_BYTES];
    AuthProof(r->key, kAuthClientLabel, r->pendingChannel, r->clientNonce, r->serverNonce, expected);
    if (memcmp(r->pendingIn, kAuthClient, sizeof kAuthClient) != 0
        || timingsafe_bcmp(expected, r->pendingIn + 4, AUTH_PROOF_BYTES) != 0) {
        ReceiverDropPending(r, true);
        return;
    }
    ReceiverPromotePending(r);
}

static void ReceiverRead(EQTLinkReceiver *r, uint64_t now) {
    for (int pass = 0; pass < 8; pass++) {
        const ssize_t n = recv(r->peerFd, r->rx + r->rxLength, RX_BUFFER_BYTES - r->rxLength, 0);
        if (n == 0) {
            ReceiverDropPeer(r);
            ReceiverCheckListener(r);   // peer and listener go defunct together
            return;
        }
        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) return;
            os_log_error(LinkLog(), "receiver recv failed errno=%{public}d", errno);
            ReceiverDropPeer(r);
            ReceiverCheckListener(r);
            return;
        }
        r->rxLength += (size_t)n;
        const size_t skipped = EQTLinkConsume(r->rx, &r->rxLength, ReceiverOnChunk, r);
        if (skipped) atomic_fetch_add_explicit(&r->skippedBytes, skipped, memory_order_relaxed);
        ReceiverPublishWriterStats(r);
        if (r->ackDue && now - r->lastAckNs >= RX_ACK_INTERVAL_NS) {
            const uint8_t answer = 0xA5;
            (void)send(r->peerFd, &answer, 1, MSG_DONTWAIT);
            r->lastAckNs = now;
            r->ackDue = false;
        }
        // Garbage with no valid header would otherwise fill the buffer forever.
        if (r->rxLength >= RX_BUFFER_BYTES) r->rxLength = 0;
    }
}

static void *ReceiverThread(void *arg) {
    EQTLinkReceiver *r = arg;
    pthread_setname_np("com.eqtargets.link.receive");
    while (atomic_load_explicit(&r->running, memory_order_acquire)) {
        uint64_t now = MonotonicNs();
        if (r->listenFd < 0 && now >= r->nextListenNs) {
            const int e = ReceiverOpenListener(r);
            if (e != 0) {
                r->nextListenNs = now + RX_RELISTEN_NS;
                os_log_error(LinkLog(), "receiver listen failed errno=%{public}d", e);
            }
        }
        if (now >= r->nextProbeNs) {
            r->nextProbeNs = now + RX_PROBE_NS;
            ReceiverCheckPeer(r);
            ReceiverCheckListener(r);
        }

        struct pollfd fds[4];
        nfds_t count = 0;
        fds[count++] = (struct pollfd){ .fd = r->wakeFds[0], .events = POLLIN, .revents = 0 };
        int listenSlot = -1, peerSlot = -1, pendingSlot = -1;
        int waitMs = 1000;
        const uint64_t polledAt = MonotonicNs();
        if (r->listenFd >= 0) {
            if (polledAt >= r->nextAcceptNs) {
                listenSlot = (int)count;
                fds[count++] = (struct pollfd){ .fd = r->listenFd, .events = POLLIN, .revents = 0 };
            } else {        // new callers wait in the backlog until the rate limit allows
                const uint64_t left = r->nextAcceptNs - polledAt;
                if (left < 1000000000ull) waitMs = (int)(left / 1000000ull) + 1;
            }
        }
        if (r->peerFd >= 0) {
            peerSlot = (int)count;
            fds[count++] = (struct pollfd){ .fd = r->peerFd, .events = POLLIN, .revents = 0 };
        }
        if (r->pendingFd >= 0) {
            pendingSlot = (int)count;
            fds[count++] = (struct pollfd){ .fd = r->pendingFd, .events = POLLIN, .revents = 0 };
            const uint64_t left = r->pendingDeadlineNs > polledAt ? r->pendingDeadlineNs - polledAt : 0;
            if (left < 1000000000ull && (int)(left / 1000000ull) + 1 < waitMs) waitMs = (int)(left / 1000000ull) + 1;
        }
        const int ready = poll(fds, count, waitMs);
        now = MonotonicNs();
        if (r->pendingFd >= 0 && now >= r->pendingDeadlineNs) ReceiverDropPending(r, true);
        if (ready <= 0) continue;

        if (fds[0].revents) {
            uint8_t drain[16];
            while (read(r->wakeFds[0], drain, sizeof drain) > 0) {}
        }
        if (peerSlot >= 0 && fds[peerSlot].revents) ReceiverRead(r, now);
        if (pendingSlot >= 0 && r->pendingFd == fds[pendingSlot].fd && fds[pendingSlot].revents) {
            ReceiverAuthStep(r);
        }
        if (listenSlot >= 0 && r->listenFd == fds[listenSlot].fd && fds[listenSlot].revents) {
            ReceiverAccept(r, now);
        }
    }
    ReceiverDropPeer(r);
    ReceiverDropPending(r, false);
    ReceiverCloseListener(r);
    return NULL;
}

int EQTLinkReceiverStart(EQTLinkReceiver *r) {
    if (r->threadLive) return 0;
    // Bind before returning, so the caller learns immediately if the port is taken.
    const int e = r->listenFd < 0 ? ReceiverOpenListener(r) : 0;
    if (e != 0) {
        os_log_error(LinkLog(), "receiver listen failed errno=%{public}d", e);
        return e;
    }
    atomic_store_explicit(&r->running, true, memory_order_release);
    r->nextProbeNs = MonotonicNs() + RX_PROBE_NS;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_set_qos_class_np(&attr, QOS_CLASS_USER_INTERACTIVE, 0);
    const int rc = pthread_create(&r->thread, &attr, ReceiverThread, r);
    pthread_attr_destroy(&attr);
    if (rc != 0) {
        atomic_store_explicit(&r->running, false, memory_order_release);
        ReceiverCloseListener(r);
        return rc;
    }
    r->threadLive = true;
    return 0;
}

void EQTLinkReceiverStop(EQTLinkReceiver *r) {
    if (!r->threadLive) return;
    atomic_store_explicit(&r->running, false, memory_order_release);
    const uint8_t byte = 1;
    (void)write(r->wakeFds[1], &byte, 1);
    pthread_join(r->thread, NULL);
    r->threadLive = false;
}

void EQTLinkReceiverSetReserveFrames(EQTLinkReceiver *r, uint32_t frames) {
    const uint32_t clamped = frames < EQT_LINK_DEFAULT_RESERVE ? EQT_LINK_DEFAULT_RESERVE
        : (frames > EQT_LINK_MAX_RESERVE ? EQT_LINK_MAX_RESERVE : frames);
    atomic_store_explicit(&r->requestedReserve, clamped, memory_order_relaxed);
}

void EQTLinkReceiverSetKey(EQTLinkReceiver *r, const uint8_t *key) {
    if (atomic_load_explicit(&r->hasKey, memory_order_acquire)) return;
    memcpy(r->key, key, EQT_LINK_KEY_BYTES);
    atomic_store_explicit(&r->hasKey, true, memory_order_release);
}

void EQTLinkReceiverGetStats(const EQTLinkReceiver *r, EQTLinkReceiverStats *out) {
    out->receivedFrames = atomic_load_explicit(&r->receivedFrames, memory_order_relaxed);
    out->peerFrames = atomic_load_explicit(&r->peerFrames, memory_order_relaxed);
    out->skippedBytes = atomic_load_explicit(&r->skippedBytes, memory_order_relaxed);
    out->badSamples = atomic_load_explicit(&r->badSamples, memory_order_relaxed);
    out->gapFrames = atomic_load_explicit(&r->gapFrames, memory_order_relaxed);
    out->connections = atomic_load_explicit(&r->connections, memory_order_relaxed);
    out->relistens = atomic_load_explicit(&r->relistens, memory_order_relaxed);
    out->rejectedCallers = atomic_load_explicit(&r->rejectedCallers, memory_order_relaxed);
    out->reserveFrames = atomic_load_explicit(&r->requestedReserve, memory_order_relaxed);
    out->listening = atomic_load_explicit(&r->listening, memory_order_relaxed);
    out->hasPeer = atomic_load_explicit(&r->hasPeer, memory_order_relaxed);
}
