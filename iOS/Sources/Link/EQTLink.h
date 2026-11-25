//
//  EQTLink.h
//  EQtargets (iOS)
//
//  Carries the system mix from the Media Device Extension to the app.
//
//  WHY A LOOPBACK SOCKET
//  ------------------------------------------------------------------
//  The extension's sandbox denies App Group file writes, POSIX shared memory
//  and bind(). Connecting out is allowed, so the app listens on 127.0.0.1 and
//  the extension dials it. The Mac driver's shared-memory ring cannot be used
//  across this boundary, but the app still writes what it receives into an
//  in-process EQTRingHeader, so the Mac's tested RingReader (resampler + PLL)
//  and ProcessingChain run unchanged.
//
//  WHY EACH CHUNK CARRIES ITS CAPTURE TIME
//  ------------------------------------------------------------------
//  Socket delivery is bursty. RingReader's PLL measures the ring fill against a
//  projected write head, so stamping chunks with their ARRIVAL time would feed
//  socket jitter straight into the playback ratio. mach_absolute_time is shared
//  by every process on the device, so each chunk carries the time its last frame
//  was written by the audio server. The projection then follows the source clock
//  and ignores how the bytes happened to arrive.
//
//  WIRE FORMAT (little-endian, same device only)
//  ------------------------------------------------------------------
//  [EQTLinkChunkHeader, 32 bytes][float32 L, R, L, R ... `frames` pairs]
//  TCP does not preserve boundaries: partial bytes are carried over on both
//  sides, and every header is validated so a desync can recover.
//  A header with frames == 0 and EQT_LINK_FLAG_END_OF_STREAM means the audio
//  server stopped delivering. The reader then drains without counting a dropout,
//  and the next chunk starts a clean new timeline.
//
//  The app answers with one byte every 250 ms while audio arrives. That byte is
//  the only proof it is running: a suspended app's listener still completes
//  connections in the kernel, and the socket buffers still accept data.
//
//  HANDSHAKE (first, on every connection)
//  ------------------------------------------------------------------
//  Loopback is open to every app on the phone, so each side proves it holds the
//  key the app created at first launch:
//    extension -> "EQA1" + 32-byte nonce
//    app       -> "EQA2" + 32-byte nonce + HMAC-SHA256(key, server label + connection + both nonces)
//    extension -> "EQA3" + HMAC-SHA256(key, client label + connection + both nonces)
//  "Connection" is the socket's client and server address and port, as each end
//  sees them. It stops another app relaying the messages between the two real
//  ends: its second socket has different values, and the kernel won't let two
//  sockets share all four. The extension sends no audio until the app has proved
//  itself, and the app ignores a caller until it has. A caller without the key can
//  neither hear the audio nor feed its own in. It can still deny service, by
//  holding the port or flooding it, at a rate-limited cost to the app.
//

#ifndef EQT_LINK_H
#define EQT_LINK_H

#include <stddef.h>
#include <stdint.h>
#include "EQTRingProtocol.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Not EffectDeck's 47101, so both apps can be installed and running together.
#define EQT_LINK_PORT             47211
#define EQT_LINK_HOST             "127.0.0.1"
#define EQT_LINK_SAMPLE_RATE      48000.0
#define EQT_LINK_CHANNELS         2u
#define EQT_LINK_MAGIC            0x4C545145u   /* bytes 'E','Q','T','L' in memory */
#define EQT_LINK_VERSION          1u
#define EQT_LINK_MAX_CHUNK_FRAMES 2048u
/// Writer block size reported to RingReader at the start of a stream. It sizes
/// the target latency; the engine raises it if the stream underruns.
#define EQT_LINK_DEFAULT_RESERVE  1024u
#define EQT_LINK_MAX_RESERVE      4096u
#define EQT_LINK_FLAG_END_OF_STREAM 1u
/// The shared secret both halves must hold (see LinkKey.swift).
#define EQT_LINK_KEY_BYTES        32u
/// A gap up to this long is bridged with silence. Longer starts a new timeline.
#define EQT_LINK_MAX_GAP_FRAMES   4096u
/// Far above any real signal. Keeps a value like 1e38 out of the DSP.
#define EQT_LINK_MAX_SAMPLE       8.0f

typedef struct EQTLinkChunkHeader {
    uint32_t magic;
    uint16_t version;
    uint16_t channels;
    uint32_t frames;
    uint32_t flags;          /* 0 on audio chunks */
    int64_t  startFrame;     /* absolute frame index in the sender's timeline */
    uint64_t endHostTime;    /* mach_absolute_time when frame startFrame+frames was written */
} EQTLinkChunkHeader;

_Static_assert(sizeof(EQTLinkChunkHeader) == 32, "wire header must stay 32 bytes");

// MARK: Codec

/// Bytes of a complete chunk carrying `frames` frames.
size_t EQTLinkChunkBytes(uint32_t frames);
/// 1 if every header field is one this build can safely act on.
int EQTLinkHeaderIsValid(const EQTLinkChunkHeader *header);

typedef void (*EQTLinkChunkFn)(void *context, const EQTLinkChunkHeader *header, const uint8_t *payload);

/// Delivers every complete chunk in `buffer`, keeps the unfinished remainder at
/// the front and updates `length`. Invalid bytes are skipped one at a time until
/// a valid header appears. `payload` may be unaligned. Returns the bytes skipped.
size_t EQTLinkConsume(uint8_t *buffer, size_t *length, EQTLinkChunkFn fn, void *context);

// MARK: Ring writer (app side)

/// Plays the role the Mac driver's WriteMix plays for the shared ring.
typedef struct EQTLinkRingWriter {
    EQTRingHeader *ring;
    int64_t  base;           /* sender frame mapped to ring frame 0 */
    int64_t  head;           /* ring frames written in this generation */
    int      open;
    uint32_t reserveFrames;
    uint64_t gapFrames;
    uint64_t badSamples;
    uint64_t restarts;
} EQTLinkRingWriter;

/// Formats `ring` (EQT_RING_TOTAL_BYTES of writable memory) as a valid, idle ring.
void EQTLinkRingFormat(EQTRingHeader *ring);
void EQTLinkRingWriterInit(EQTLinkRingWriter *writer, EQTRingHeader *ring);
/// Zero-fills any gap, copies the chunk, replaces non-finite samples with 0,
/// then publishes the head. A chunk that moves backwards starts a new generation.
void EQTLinkRingWriterWrite(EQTLinkRingWriter *writer, const EQTLinkChunkHeader *header, const uint8_t *payload);
/// The peer left: the reader fades out and waits.
void EQTLinkRingWriterClose(EQTLinkRingWriter *writer);

// MARK: Sender (extension side)

typedef struct EQTLinkSender EQTLinkSender;

typedef struct EQTLinkSenderStats {
    uint64_t pushedFrames;
    uint64_t sentFrames;
    uint64_t droppedFrames;
    uint64_t connects;
    uint64_t connectAttempts;
    uint64_t wakeups;        /* times the sender thread ran */
    int      connected;
} EQTLinkSenderStats;

EQTLinkSender *EQTLinkSenderCreate(uint16_t port);
/// Stops the sender first. Never call while the audio thread may still push.
void EQTLinkSenderDestroy(EQTLinkSender *sender);
/// Without a key the sender never connects. Only the first call takes effect.
void EQTLinkSenderSetKey(EQTLinkSender *sender, const uint8_t *key);
/// Idempotent. Returns 0 on success.
int EQTLinkSenderStart(EQTLinkSender *sender);
void EQTLinkSenderStop(EQTLinkSender *sender);
/// Real-time safe: no allocation, locks or Objective-C. `hostTime` is the
/// mach_absolute_time at which these frames were written.
void EQTLinkSenderPush(EQTLinkSender *sender, const float *interleaved, uint32_t frames,
                       uint32_t channels, uint64_t hostTime);
/// The audio server started (1) or stopped (0) delivering. Stopping tells the
/// app the stream ended and pauses reconnect attempts, so a selected but idle
/// output costs no wake-ups. Not for the audio thread.
void EQTLinkSenderSetDelivering(EQTLinkSender *sender, int delivering);
typedef void (*EQTLinkUnreachableFn)(void *context);
/// `fn` runs once, on the sender thread, after `seconds` of audio with no answer
/// from the app, counted across pauses. Set it before the first Start.
void EQTLinkSenderSetUnreachableHandler(EQTLinkSender *sender, double seconds,
                                        EQTLinkUnreachableFn fn, void *context);
void EQTLinkSenderGetStats(const EQTLinkSender *sender, EQTLinkSenderStats *out);

// MARK: Receiver (app side)

typedef struct EQTLinkReceiver EQTLinkReceiver;

typedef struct EQTLinkReceiverStats {
    uint64_t receivedFrames;
    uint64_t peerFrames;     /* received from the current peer */
    uint64_t skippedBytes;
    uint64_t badSamples;
    uint64_t gapFrames;
    uint64_t connections;
    uint64_t relistens;
    uint64_t rejectedCallers; /* callers that failed or abandoned the handshake */
    uint32_t reserveFrames;
    int      listening;
    int      hasPeer;
} EQTLinkReceiverStats;

/// `ring` must stay valid until the receiver is destroyed.
EQTLinkReceiver *EQTLinkReceiverCreate(uint16_t port, EQTRingHeader *ring);
void EQTLinkReceiverDestroy(EQTLinkReceiver *receiver);
/// Without a key every caller is refused. Only the first call takes effect.
void EQTLinkReceiverSetKey(EQTLinkReceiver *receiver, const uint8_t *key);
/// Binds 127.0.0.1 only. Idempotent. Returns 0 on success.
int EQTLinkReceiverStart(EQTLinkReceiver *receiver);
void EQTLinkReceiverStop(EQTLinkReceiver *receiver);
/// Clamped to [EQT_LINK_DEFAULT_RESERVE, EQT_LINK_MAX_RESERVE].
void EQTLinkReceiverSetReserveFrames(EQTLinkReceiver *receiver, uint32_t frames);
void EQTLinkReceiverGetStats(const EQTLinkReceiver *receiver, EQTLinkReceiverStats *out);

#ifdef __cplusplus
}
#endif

#endif /* EQT_LINK_H */
