# EQtargets for Mac — architecture & build contract

**Product:** EQtargets (macOS), bundle `com.eqtargets.app`.
A system-wide parametric EQ for MacBooks, like eqMac but friendlier. Rebuilt from
scratch on 2026-11-04 after the original project was lost in a Mac migration.

Sister app: **EQtargets Music** (iOS), [github.com/atrejokm301/EQtargetsMusic](https://github.com/atrejokm301/EQtargetsMusic)
(a read-only reference — never edit it from this project). Its DSP was confirmed by ear on device by the owner (Kevin);
this app ports that DSP rather than re-inventing it.

## 1. What the user gets

1. **Two 10-band PEQs**, as two independent layers:
   - **Target** — headphone/speaker correction imported from AutoEQ / Squiglink /
     oratory1990 (`ParametricEQ.txt`: `Preamp: -6.2 dB` + `Filter N: ON PK Fc … Hz Gain … dB Q …`,
     also `LSC`/`HSC`/`LS`/`HS` shelves). Can be bound to an output device (AirPods get
     the AirPods curve, speakers get the speaker curve).
   - **Fine-Tune** — the user's own tuning: per band filter type (Peak / Low shelf /
     High shelf), frequency, gain, Q, enable; plus preamp. Sits on top of Target and
     never overwrites it.
2. **Bass Style** — independent post-PEQ stage: Off · Punch · Rumble · Clean, with
   Strength / Cutoff / Post gain, and the **dynamic Punch and Rumble stages** with a
   **live activity meter** (centre-anchored: boost/sustain grows right, trim/soften grows left).
3. System-wide: every app's audio, no Microphone / Screen & System Audio Recording
   permission, no orange or purple indicator.

## 2. Signal path

```
 any app ──► macOS default output = "EQtargets Audio" (our HAL driver, OUTPUT-ONLY)
                │  WriteMix → POSIX shm ring "/eqtargets.audio.ring" (Shared/EQTRingProtocol.h)
                ▼
 EQtargets.app  RingReader (windowed-sinc resampler + PLL on ring fill)
                → ProcessingChain:
                    Target PEQ (preamp + 10 biquads)
                  → Fine-Tune PEQ (preamp + 10 biquads)
                  → Bass Style static shape (4 biquads + K-weighted loudness-matched gain)
                  → Punch / Rumble dynamic stage (TransientPunchDSPCore, LR4 crossover)
                  → Output protection (lookahead safety limiter, ceiling −1 dBFS)
                  → output gain / mute (digital volume fallback)
                → AUHAL output unit bound to the REAL device (speakers, AirPods, DAC…)
```

### Hard rules (each one was learned the hard way — do not relitigate)

- **The driver publishes NO input stream.** Input streams cost Microphone permission and
  light the orange indicator. The mix travels through shared memory instead.
- **Never use Core Audio process taps (CATap / `AudioHardwareCreateProcessTap`).** They are
  permission-gated capture. They were removed from the previous version on purpose.
- **Never open input/duplex on the output device.** On AirPods/Bluetooth that forces the
  HFP headset profile and wrecks music quality. AUHAL: input disabled (`EnableIO` input = 0).
- **Level-matching = perceived loudness (K-weighted), never peak.** Already implemented in
  `BassProcessorDSP`; keep it.
- **Graph == DSP.** The PEQ stages render the exact RBJ formulas in `EQBiquad`, so the
  frequency-response plot is the truth.
- **Render-thread code** (driver IO, `RingReader.render`, `ProcessingChain.process`, the AUHAL
  callback): no allocation, no locks, no ObjC/Swift runtime calls that can block, no Swift
  arrays/`[T]` or class references that retain/release, no `log/exp/pow/sin` per sample,
  denormal guards on decaying state. Coefficients are computed on the main thread and
  handed over lock-free (double buffer / atomic index).
- **Parameter changes glide.** Dragging a band, a slider or switching a style never clicks.
- **Performance is measured, not assumed** — measure DSP cost in a Release (`-O`) build.
  Debug `-Onone` Swift DSP is ~30× slower and misleading.
- **Honest verification only.** Nothing is "done" without a build and a test/measurement
  that would fail if it were broken.

## 3. Repository layout & ownership

| Path | What | Owner (build phase) |
|---|---|---|
| `Shared/EQTRingProtocol.h` | shm ring contract (C, imported by Swift via bridging header) | frozen — bump version to change |
| `Driver/` | AudioServerPlugIn in C → `EQtargetsAudio.driver` | Driver |
| `Tools/probe/` | `eqt-probe`: `--devices`, `--ring`, `--selftest` | Driver |
| `Tools/driver-harness/` | `eqt-driver-harness`: dlopen the BUILT driver, fake host, drive IO, verify ring | Driver |
| `scripts/install-driver.sh`, `uninstall-driver.sh` | sudo install/uninstall + restart coreaudiod | Driver |
| `Sources/EQTCore/Models/` | ported iOS models: `EQModels.swift` (bands, layers, AutoEQ parser, FrequencyResponse, EQBiquad, presets), `BassProcessor.swift` | Core |
| `Sources/EQTCore/DSP/` | `TransientPunchProcessor.swift` (verbatim iOS), `ProcessingChain.swift`, `RingReader.swift`, plus new PEQ / resampler / limiter files | Core |
| `Tests/EQTCoreTests/` | XCTest logic tests, no host app (compile EQTCore sources directly) | Core |
| `Sources/EQTAudio/` | Core Audio HAL glue: `EngineController.swift` (frozen API), device list/listeners, AUHAL output, routing, volume mirroring, driver install | Engine |
| `Tools/engine-cli/` | `eqt-engine`: headless engine (`run`, `--offline-selftest`) | Engine |
| `Sources/App/` | SwiftUI app: AppModel, persistence, presets, device→Target binding, all views, menu bar extra, snapshot renderer | UI |
| `docs/DESIGN.md` | UI/UX spec (wireframes, tokens, interactions) | Design |

Everything is ONE Swift module per target (no frameworks), so types are `internal`.
The app target compiles EQTCore + EQTAudio + App. `EQTCoreTests` compiles EQTCore + tests.
`eqt-engine` compiles EQTCore + EQTAudio + its main.

## 4. Frozen API contracts

Signatures in these files are frozen; replace stub bodies only:

- `Sources/EQTCore/DSP/ProcessingChain.swift` — `ChainParameters`, `ChainMeters`, `ProcessingChain`
- `Sources/EQTCore/DSP/RingReader.swift` — `RingReaderStats`, `RingReader`
- `Sources/EQTAudio/EngineController.swift` — `OutputTransport`, `OutputDevice`, `EngineStatus`,
  `EngineStats`, `EngineController`
- `Shared/EQTRingProtocol.h` — ring layout, names, UIDs, atomic helpers. Swift cannot import computed macros: use `EQTRingTotalBytes()` / `EQTRingSampleBytes()`

Adding new *internal* helpers/types is fine. Changing a frozen signature requires
updating this doc and every caller in the same change.

### Ported model types (from iOS, `Sources/EQTCore/Models`)

- `EQFilterType { peak, lowShelf, highShelf }`, `EQBand(frequency, gain, q, isEnabled, filterType)`
  ranges: f 20…20 000 Hz, gain −20…+20 dB, Q 0.1…10. `EQBand.defaultTenBands()` = ISO 31.5…16k.
- `EQLayerState(preamp −20…+20, bands[10], isBypassed)`, `EQLayer { target, fineTune }`
- `DualEQState(target, fineTune, isBypassed, editingLayer)`; `.flat`
- `AutoEQParser.parse(text:) throws -> EQLayerState` (keeps the 10 most significant filters,
  derives preamp from the realized curve, never positive)
- `FrequencyResponse.curves(dual:)`, `.peakMagnitudeDB(bands:)`, `.xPosition`, formatters; `EQBiquad`
- `EQPreset`, `BuiltinPresets.targets / .fineTunes`
- `BassStyle { none, transientPunch, sustainRumble, naturalClean }` (+ `title`, `compactTitle`,
  `subtitle`, `systemImage`, `hasDynamics`, `recommendedCutoffHz`)
- `BassProcessorState` (style, strength 0…1, cutoff 40…250, postGain −12…+6, punchAttack,
  punchSustain, rumbleSustain, rumbleSoften; hand-written Codable that tolerates missing keys)
- `BassProcessorDSP.unitParams(from:sampleRate:) -> UnitParams(globalGainDB, unitBypass, bands[4] of BandParams(type, frequency, gainDB, q, bypass))`
- `TransientPunchCoefficients.make(from:sampleRate:)`, `TransientPunchDSPCore` (prepare / update /
  process(channels:frameCount:) / attackBoostDB / sustainTrimDB / reset), tuning enums.

## 5. Driver ↔ app ring

See the header comment in `Shared/EQTRingProtocol.h` — it is the spec. Summary: driver creates
`/eqtargets.audio.ring` (`shm_open` O_CREAT|O_RDWR, mode 0644, `fchmod` to defeat umask,
`ftruncate` to `EQT_RING_TOTAL_BYTES`; if an existing object has the wrong size, `shm_unlink`
and recreate), writes header fields then publishes `magic` last. App opens it **read-only**
(`O_RDONLY`, `PROT_READ`). Interleaved float32 stereo, capacity 32768 frames, absolute frame
indexing, `generation` bumps on StartIO / rate change, `writeHead` release/acquire.

**Reader attachment (`'eqta'`, added 2026-11-05, ring layout unchanged):** the app SETs the
custom device property `EQT_PROPERTY_READER_ATTACHED` (CFNumber) to 1 at the start of every
route (before it takes macOS's default output) and to 0 once routing is torn down and the
default is no longer EQtargets Audio. The driver tracks attached processes by pid (exit-watched)
and, once any process has set the property, hides the device (IsHidden 1, CanBeDefaultDevice 0)
while none is attached. A hidden device is still found by UID; `DeviceCatalog.virtualDevice()`
also falls back to the plug-in's own device list. Older drivers lack the property; the app
then skips it.

Known accepted risk: mode 0644 means any local process can read the system mix from the ring
(coreaudiod runs as `_coreaudiod`, so the user can't be given exclusive access without root).
Documented in the security audit; acceptable for a personal-use build.

## 6. Device routing rules (Engine)

- On power-on: find EQtargets Audio by UID `com.eqtargets.audio.device`. Pick the real output:
  pinned UID if set and present → else current macOS default if it isn't our device → else
  last-used real device (persisted UID) → else built-in speakers. Match the virtual device's
  nominal rate to the real device's (driver supports 44.1/48/88.2/96/176.4/192 kHz).
  Set macOS default output = EQtargets Audio. Leave the *system/alert* output alone.
- Follow macOS: when the default output changes to some other device (user picked it in the
  Sound menu, AirPods connected and macOS switched to them), adopt it as the new real output,
  switch AUHAL to it, then set the default back to EQtargets Audio.
- Follow macOS applies unless a pinned device is actually present (an absent pin never makes
  Control Center picks bounce back). With a present pin, any pick puts the route back on the
  PINNED device (`RoutingPolicy.defaultChangeTarget`), never "stay where we are": after a
  fallback whose return was missed, that left the pinned AirPods silent while the speakers
  played (2026-11-14). Control Center shows a spinner on the picked device because the
  default goes straight back to EQtargets Audio; that is cosmetic and inherent to the design.
- Real device disappears → fall back (pinned → last → built-in) without user action, and
  remember it: when that device comes back (DAC power cycle, display audio after sleep, a
  device published late after a coreaudiod restart) route back to it (Follow macOS only).
- macOS's default output found on EQtargets Audio while this engine isn't playing it (Off,
  error, stepped aside) → hand it back to a real device, unless another process is attached
  as a reader (`'eqta'`). With a current driver the device is hidden then anyway.
- A device that refuses to play (AUHAL init/start fails) is not remembered as the last-used
  device, and the default goes back to: the device that was playing a moment ago → a recent
  PERSONAL device (Bluetooth/USB/Thunderbolt) → the refusing device itself. Never a jump onto
  speakers/TV/AirPlay the user wasn't hearing, never a default left on EQtargets Audio with
  nothing reading it. Later restores (stranded default) keep avoiding that device until
  something plays again.
- The driver's `'eqta'` reader count includes this process while it is attached; only OTHER
  readers keep a stranded default on EQtargets Audio (`RoutingPolicy.otherReaders`).
- Volume mirroring to a per-channel-only (L/R) device keeps its balance: the loudest channel
  is the volume, the others keep their ratio to it.
- Every teardown of a running output (Off, quit, device switch) fades the device out over
  5 ms first (bounded wait ≤ 50 ms on the main thread), instead of cutting mid-waveform.
- Latency: before building the AUHAL, the engine asks the real device for a 128-frame IO
  buffer (`OutputUnit.preferredBufferFrames`), clamped to the device's range, never larger
  than it runs now. The HAL keeps that size per process, so other apps are unaffected and it
  ends with the app (measured: an old build on the same device kept 512-frame callbacks
  while the new one ran 128). Everything downstream (ring target, presentation latency,
  `'eqtl'`) uses the size read back. Measured on the speakers (`--auhal-selftest`, 30 s):
  512 → 128, ring target 1298 → 914 frames, ≈ 16 ms less, 0 underruns; whole-process
  CPU 0.35 → 0.24 s, but about twice the context switches (4× the callbacks). Energy was
  not measured. Bluetooth (AirPods Max, 2026-11-14): the device rounds the 128 request up
  to **256** although its range says 15…960; 4 min at 256, 0 underruns. Live in the app,
  the latency reported to players fell 9306 → 8794 frames (204.5 → 193.9 ms). The
  AirPods' own 7680 frames (160 ms) is the bulk and has no clean lever.
- Idle power: AUHAL runs only while the virtual device is running somewhere
  (`kAudioDevicePropertyDeviceIsRunningSomewhere`), with a ~3 s hangover; zero CPU when silent.
- Volume keys move the virtual device's volume/mute. Mirror them to the real device's hardware
  volume/mute when settable; otherwise apply digitally via `ChainParameters.outputGainDB/outputMuted`.
  On power-on, seed the virtual volume from the real device's current volume.
- Off / quit: restore macOS default output to the real device synchronously. The app turns
  SIGTERM / SIGINT / SIGHUP (`pkill`, Ctrl-C, scripts) into a normal quit so this still runs;
  only SIGKILL skips it, and launch recovery covers that on the next launch.
- Launch recovery: if macOS's default output is EQtargets Audio but the app is powered off (e.g.
  after a crash), restore it to the last real device immediately.
- Report pipeline latency to the driver via the `'eqtl'` custom property when supported.
  The driver applies each change through Request/PerformDeviceConfigurationChange,
  because the HAL never passes a plain latency PropertiesChanged on to running clients
  (measured 2026-11-14: the `'eqtl'` notice arrived, the latency one never did, so open
  players kept the latency they read at start — video lagged on AirPods until the player
  was relaunched). Each change briefly restarts IO on EQtargets Audio, so the engine sends
  one figure per route (the ring target estimated before the reader runs) and re-sends it
  only when it moves by ≥ 20 ms (`LatencyMath.reportThresholdSeconds`).

## 7. Build, test, run

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd EQtargetsMac                                     # the repo root
xcodegen generate                                   # after adding/removing files or editing project.yml
# Use YOUR OWN derived-data dir per work stream so parallel builds never collide:
xcodebuild -project EQtargets.xcodeproj -scheme EQTCoreTests -derivedDataPath build/<you> test   # use `test`, not `build` (logic-test bundle has no build destination)
xcodebuild -project EQtargets.xcodeproj -scheme EQtargets   -derivedDataPath build/<you> build
xcodebuild -project EQtargets.xcodeproj -scheme eqt-driver-harness -derivedDataPath build/<you> build
xcodebuild -project EQtargets.xcodeproj -scheme eqt-engine  -derivedDataPath build/<you> build
# Release (for any performance measurement):
xcodebuild ... -configuration Release ...
```

- `xcodegen generate` rewrites `EQtargets.xcodeproj` from `project.yml`. Sources are picked up by
  folder, so new files inside an existing source folder only need a re-generate. If two work
  streams regenerate at the same time that is harmless (same input → same output).
- Driver install needs root: `scripts/install-driver.sh` (copies to `/Library/Audio/Plug-Ins/HAL`,
  restarts coreaudiod). **Agents cannot run sudo** — the human does that step. Everything else
  (driver logic via `eqt-driver-harness`, engine via `eqt-engine --offline-selftest`, DSP via XCTest)
  must be verifiable without installing.
- Signing is ad-hoc (`-`) everywhere; no team, no sandbox, no hardened runtime. Never change the
  bundle IDs.
- Test-only hooks (never set them in normal use): `EQT_RING_NAME_OVERRIDE` (driver/harness/probe:
  private ring) and, in **DEBUG builds only**, `EQT_DEVICE_UID_OVERRIDE` (engine/app: look for a
  different device UID, i.e. hide an installed driver so the driver-missing paths can be tested
  without sudo). `EQtargets --ui-selftest` (Debug) uses the latter to drive the REAL
  EngineController under the real AppModel with an interlock that never powers on if the
  driver is still visible.
