# EQtargets Audio — HAL driver

An AudioServerPlugIn (C17) that publishes one **output-only** virtual device,
**EQtargets Audio** (UID `com.eqtargets.audio.device`). While EQtargets is on,
macOS's default output points at it; coreaudiod mixes every app into it and the
driver copies that mix, bit for bit, into a POSIX shared-memory ring that
EQtargets.app reads, equalises and plays on the real output device.

## Why it is built this way

- **No input stream, nothing in input scope.** A loopback "cable" (BlackHole /
  eqMac style) needs an input stream, and any input stream costs Microphone
  permission and lights the orange indicator. Here `Streams(input)` is empty,
  `OwnedObjects(input)` is empty, the device can't be the default input, and no
  input channel layout or stereo pair is advertised. The audio leaves through
  shared memory instead. Don't change this into an input stream or a CATap.
- **Bit-transparent.** WriteMix copies the HAL's float32 mix unmodified. The
  master volume and mute controls exist so the volume keys and the Sound menu
  work, but the driver **does not apply them**. The app mirrors them to the real
  device, or applies them digitally if the device has no hardware volume.

## Files

| File | What |
|---|---|
| `EQtargetsAudioDriver.c` | plug-in / box / device / stream / controls object model, property engine, clock, IO entry points, factory `EQTargets_Create` |
| `EQTDriverRing.c` | ring create/attach and the real-time writer (`EQTDriverRingWriteMix`) |
| `EQTDriver.h` | internal declarations; enables `-Wfunction-effects` |
| `Info.plist` | CFPlugIn factory/type UUIDs (factory `2831EA39-…`, type `kAudioServerPlugInTypeUUID`) |
| `../Shared/EQTRingProtocol.h` | the ring contract (frozen; bump the version to change it) |

Objects: plug-in `1` → box `2`, device `3` → output stream `4`, master output
volume `5`, master output mute `6`. Only `EQTargets_Create` is exported.

## Device

- Transport virtual, can be the default **output** but not the default system
  (alert) output, clock domain 0 (unspecified). Visible, except while an app
  manages visibility through `'eqta'` and no app reads the ring (below).
- Rates 44.1 / 48 / 88.2 / 96 / 176.4 / 192 kHz (default 48 kHz). A rate change,
  whether through `NominalSampleRate` or a stream format, goes through
  `RequestDeviceConfigurationChange` (dispatched, as in Apple's NullAudio). Then
  `PerformDeviceConfigurationChange` applies it, re-anchors the clock, writes the
  rate to the ring, bumps the generation and notifies nominal rate plus the
  stream formats. **Latest request wins:** a set is compared with the rate last
  *requested* (not the applied one), so the same rate set twice is one request
  and a quick switch back is not lost; Perform applies the latest requested
  rate and is a no-op (no re-anchor, no new timeline) when that is already the
  rate. An aborted or failed request is forgotten.
- One output stream: 2 ch float32 native packed interleaved (virtual =
  physical), starting channel 1, terminal type speaker, `IsActive` settable.
- Clock: as in NullAudio, sample time is `mach_absolute_time` at the nominal rate.
  Zero timestamps fall every 16384 frames after the anchor. The anchor is reset on
  the first StartIO and on every rate change, and the seed changes with it.
- **Volume taper**, with scalar `s` from 0 to 1 and gain from −64 to 0 dB:
  `dB = 60·log10(F + (1−F)·s)` where `F = 10^(−64/60)`. Amplitude is the cube
  of a linear control (the "cubic" law), offset so `s = 0` is exactly −64 dB.
  Reference points: 0.25 → −30.2 dB, 0.5 → −15.9 dB, 0.75 → −6.8 dB.
  Volume and mute are saved in the host's storage, so a coreaudiod restart
  doesn't reset them.
- **`'eqtl'` custom property** (CFNumber, frames, settable): the app reports
  its pipeline latency. It is clamped to 0…192000 and added to
  `kAudioDevicePropertyLatency` (output scope), with change notifications for
  both properties.
- **`'eqta'` custom property** (CFNumber, settable; added 2026-11-05): SET 1 =
  "the calling process reads the ring", 0 = "it doesn't". The driver keeps up to
  8 reader processes by pid and drops one when it exits (a `DISPATCH_PROC_EXIT`
  watch, best effort inside coreaudiod's sandbox). GET = number of readers. Once
  any process has set it, the device is **hidden and cannot be the default
  output while no reader is attached**: the Sound menu can't offer it and
  coreaudiod can't fall back to it while nothing would play what reaches it.
  A fresh driver instance (install, coreaudiod restart, reboot) is visible
  until an app sets it, so older apps keep working.
- Volume dB values clamp, ±∞ included (−∞ dB = silence); only NaN is refused.

## IO protocol (writer half of `EQTRingProtocol.h`)

`WillDoIOOperation` only accepts `WriteMix` (in place). For each WriteMix of N
frames at output sample time T (rounded, not truncated):

1. If `T > writeHead`, zero-fill `[max(writeHead, T+N−capacity), T)` so a skipped
   cycle reads as silence and never as stale audio. This writes at most
   `capacity` frames however large the gap is.
2. Copy the frames that will still be inside the reader's window. Frames more than
   `capacity` behind the new head would land in the slots of newer audio, so
   they are skipped, and so are frames before 0.
3. Release-store `writeHead = max(writeHead, T+N)`. Then store `ioBufferFrames`,
   `lastWriteHostTime`, `writeCycles` and `zeroFilledFrames`.

On the first StartIO and on every rate change the writer stores `writeHead = 0`,
bumps the generation, and stores `writeHead = 0` again. The extra leading store
means a reader that sees the new generation also sees head 0, never the old
timeline's head. `ioRunning` is 1 while any client runs and 0 after the last
StopIO.

The IO path takes no locks, does no allocation, logging or CF calls, and makes no
syscalls. Every IO entry point is `CA_REALTIME_API` (`nonblocking`), and
`-Wfunction-effects` makes the compiler check that. The one audited exception is
`mach_absolute_time()`, a commpage read, behind `EQTDriverHostTimeNow()`.
Property state sits behind a pthread mutex that is only taken off the IO thread,
and host callbacks are never made while it is held.

**Shared memory**: `Initialize` creates or attaches `/eqtargets.audio.ring`
(or `$EQT_RING_NAME_OVERRIDE`, which only the test harness sets). It uses
`O_CREAT|O_RDWR` 0644, then `fchmod` 0644 and `ftruncate`. If the size is wrong it
calls `shm_unlink` and recreates the object, then maps it, writes the header and
publishes `magic` last. **Note:** macOS reports shm sizes rounded up to the VM
page, so this ring of 266240 bytes `fstat`s as **278528** on Apple silicon.
Readers must accept either value. If shm fails, the device is still published and
WriteMix does nothing (the error is logged under subsystem
`com.eqtargets.app.driver`).

## Test without installing

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate                                            # from the repo root
xcodebuild -project EQtargets.xcodeproj -scheme eqt-driver-harness -derivedDataPath build/driver build
build/driver/Build/Products/Debug/eqt-driver-harness          # every line PASS, exit 0
```

`eqt-driver-harness` `dlopen`s the **built** driver, creates it through the
factory, and plays coreaudiod's role with a fake host. That host records
PropertiesChanged calls, keeps an in-memory store, and turns Request into a
synchronous Perform. The harness then drives the real IO entry points and reads
the ring back exactly like the app (`O_RDONLY`, `PROT_READ`), checking the bytes
are bit-exact. It covers the object tree, no-input, formats, rates, volume taper,
`'eqtl'`, error paths, gaps, rewrites, wrap, rate change, zero timestamps,
client counting, and a re-attach from a second process (a simulated coreaudiod
restart).

`eqt-driver-harness --serve <s> --ppm <p>` writes a real-time 1 kHz / −20 dBFS
tone into `$EQT_RING_NAME_OVERRIDE`. It is a known source for checking
`eqt-probe --ring`.

## Install / remove (needs sudo — a human step)

```bash
xcodebuild -project EQtargets.xcodeproj -scheme EQtargetsAudioDriver -configuration Release -derivedDataPath build/release build
xcodebuild -project EQtargets.xcodeproj -scheme eqt-probe           -configuration Release -derivedDataPath build/release build
scripts/install-driver.sh          # validates, copies to /Library/Audio/Plug-Ins/HAL, restarts coreaudiod, runs eqt-probe --devices
scripts/uninstall-driver.sh
```

After installing:

- `eqt-probe --devices` lists devices and who is running **input** (the
  Bluetooth HFP check). It exits 0 if EQtargets Audio is present and 3 if not.
- `eqt-probe --ring` dumps the ring header and measures frames/s and drift in ppm.
- `eqt-probe --selftest` plays a tone **directly into** EQtargets Audio and
  verifies it through the ring. It never changes the default output.

The driver is ad-hoc signed, like the app. Ad-hoc signed HAL plug-ins load
fine once the download quarantine is gone, and the in-app installer removes it
from the installed copy. Developer ID signing and notarization would only
remove the one-time Gatekeeper approval of the app.
