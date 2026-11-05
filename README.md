# EQtargets for Mac

A system-wide parametric EQ for macOS — like eqMac, but friendlier — rebuilt from
scratch on 2026-11-04 (the previous version was lost in a Mac migration).
Bundle `com.eqtargets.app`. Sister iOS app: **EQtargets Music** (`~/EQtargetsMusic`,
read-only reference; its DSP is ported here, not reinvented).

What you get:

- **Two 10-band PEQs as two layers.** *Headphone correction* (Target) is imported from
  an AutoEQ / Squiglink / oratory1990 `ParametricEQ.txt` and can be bound to an output
  device. *Your tuning* (Fine-Tune) is your own type / frequency / gain / Q per band plus
  preamp. It sits on top of the correction and never overwrites it.
- **Bass Style**: Off · Punch · Rumble · Clean, with dynamic **Punch** (attack lift +
  sustain trim) and **Rumble** (sustain lift + attack softening) stages and a **live
  activity meter**. It runs after both EQ layers and is loudness-matched with K-weighting,
  never by peak.
- **Every app's audio, with no permissions.** There is no Microphone or Screen Recording
  prompt and no orange or purple dot. The driver is output-only, and audio reaches the
  app through shared memory.
- Output protection (a −1 dBFS lookahead limiter), click-free parameter glides, an A/B
  Compare, a menu bar extra, and follow-the-Sound-menu routing (AirPods etc.).

## Architecture in brief

```
 any app ─► macOS default output = "EQtargets Audio"  (Driver/, C AudioServerPlugIn, OUTPUT-ONLY)
               │ WriteMix → POSIX shm ring "/eqtargets.audio.ring"   (Shared/EQTRingProtocol.h)
               ▼
 EQtargets.app  RingReader (windowed-sinc resampler + PLL on ring fill)      Sources/EQTCore/DSP
               → Target PEQ → Fine-Tune PEQ → Bass shape → Punch/Rumble
               → output protection → digital volume fallback
               → AUHAL output unit on the REAL device (speakers, AirPods, DAC)  Sources/EQTAudio
```

| Path | What |
|---|---|
| `Driver/` | `EQtargetsAudio.driver`: the HAL plug-in (ring writer, volume/mute, `'eqtl'` latency property). See `Driver/README.md` |
| `Shared/EQTRingProtocol.h` | Frozen driver ↔ app shared-memory contract |
| `Sources/EQTCore/` | Ported iOS models, plus the DSP: PEQ, limiter, resampler, `ProcessingChain`, `RingReader` |
| `Sources/EQTAudio/` | Core Audio glue: `EngineController` (frozen API), HAL helpers, AUHAL output, routing, driver installer |
| `Sources/App/` | SwiftUI app: `AppModel`, views, menu bar extra, onboarding, settings, snapshot renderer, DEBUG self-test |
| `Tools/` | `eqt-probe` (diagnostics), `eqt-driver-harness` (driver tests without installing), `eqt-engine` (headless engine + self-tests) |
| `Tests/EQTCoreTests/` | XCTest for the DSP and models (128 tests) |
| `docs/ARCHITECTURE.md` | **The contract**: signal path, hard rules, frozen APIs, routing rules. Read it first |
| `docs/DESIGN.md` | UI/UX spec |
| `HANDOFF.md` | Current state, verification evidence, what is NOT verified yet |

## Build

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer   # the CLT alone is not enough
cd ~/ParametricEQ
xcodegen generate            # after adding/removing files or editing project.yml
xcodebuild -project EQtargets.xcodeproj -scheme EQtargets -configuration Release -derivedDataPath build/release build
# → build/release/Build/Products/Release/EQtargets.app (the driver is embedded in Contents/Resources)
```

The schemes are `EQtargets` (app + embedded driver), `EQtargetsAudioDriver`, `eqt-probe`,
`eqt-driver-harness`, `eqt-engine` and `EQTCoreTests` (use `test`, not `build`). Signing
is ad-hoc everywhere. Use **Release** for anything performance-related: Debug Swift DSP is
about 30× slower.

## Install the audio driver (one admin password)

Pick one:

1. **In the app:** the first launch without the driver opens onboarding. Click
   **Install Driver**, or use the "Install…" banner, or Settings → Driver. The app copies its
   embedded `Contents/Resources/EQtargetsAudio.driver` to `/Library/Audio/Plug-Ins/HAL`
   and restarts coreaudiod.
2. **Script:** build the Release driver and the probe, then run the script:
   ```bash
   xcodebuild -project EQtargets.xcodeproj -scheme EQtargetsAudioDriver -configuration Release -derivedDataPath build/release build
   xcodebuild -project EQtargets.xcodeproj -scheme eqt-probe           -configuration Release -derivedDataPath build/release build
   scripts/install-driver.sh          # validates the bundle, sudo-copies it, restarts coreaudiod, runs eqt-probe --devices
   ```
3. **CLI:** `eqt-engine install-driver PATH/EQtargetsAudio.driver`.

Sound pauses for a few seconds while coreaudiod restarts. Afterwards, `eqt-probe --devices`
must list **EQtargets Audio** with **0 input channels**.

## Run

- **App:** open `EQtargets.app`. **On** routes macOS's output through EQtargets. **Off** and
  **Quit** hand the output back to your real device. So do `pkill EQtargets` and Ctrl-C;
  only `kill -9` skips that, and the next launch repairs it.
- **Headless:** `eqt-engine run --seconds 120 [--output UID]` powers the real engine and
  prints stats every second. It always restores the default output on exit (normal end,
  Ctrl-C, SIGTERM, SIGHUP), and refuses with exit 2 when the driver isn't installed.
- **Diagnostics (read-only):** `eqt-engine status`, `eqt-probe --devices` (includes the
  Bluetooth HFP check), `eqt-probe --ring`.

## Test

Nothing below needs sudo, and nothing changes the default output or any system setting.

```bash
P=build/integrate/Build/Products   # whatever -derivedDataPath you built with
xcodebuild -project EQtargets.xcodeproj -scheme EQTCoreTests -derivedDataPath build/integrate test                         # DSP + models
xcodebuild -project EQtargets.xcodeproj -scheme EQTCoreTests -configuration Release -derivedDataPath build/integrate test   # also prints PERF lines
$P/Release/eqt-driver-harness $P/Release/EQtargetsAudio.driver   # driver loaded in-process with a fake host (228 checks)
$P/Release/eqt-engine --offline-selftest                         # engine + render callback, simulated time (123 checks)
$P/Debug/EQtargets.app/Contents/MacOS/EQtargets --ui-selftest    # app logic + real-engine seam with the driver hidden (107 checks, Debug only)
$P/Debug/EQtargets.app/Contents/MacOS/EQtargets --render-snapshots build/snapshots   # 32 PNGs, 16 states × light/dark
# With the driver installed (each plays a test tone INTO EQtargets Audio only; nothing is audible or changed):
$P/Release/eqt-probe --selftest
$P/Release/eqt-engine --driver-selftest --seconds 15
$P/Release/eqt-engine --auhal-selftest --seconds 20               # real AUHAL on the speakers, chain muted (silence)
```

## Uninstall

- In the app: Settings → Driver → **Uninstall Driver…**. It hands the output back first.
- Script: `scripts/uninstall-driver.sh` (sudo; restarts coreaudiod).
- CLI: `eqt-engine uninstall-driver`.

The ~270 KB shared-memory ring stays in kernel memory until the next reboot. It is
harmless, and a reinstalled driver re-attaches to it. App settings live in the
`com.eqtargets.app` defaults domain (`defaults delete com.eqtargets.app` resets them).

## Never change without asking

The bundle IDs (`com.eqtargets.app`, `com.eqtargets.app.driver`), signing, and the
**output-only driver rule**: no input stream, no CATap/process tap, and no input or
duplex on the output device (it forces AirPods into HFP). See `AGENTS.md` and
`docs/ARCHITECTURE.md` §2.
