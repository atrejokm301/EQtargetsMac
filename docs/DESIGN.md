# EQtargets for Mac — UI/UX design spec

**Owner:** Design (this file). **Implemented by:** UI (`Sources/App`). **Date:** 2026-11-04.
**Platform:** macOS 15+ (built and run on macOS 27), SwiftUI only, no third-party packages.
**Read with:** `docs/ARCHITECTURE.md`, which wins on any engineering conflict. This file names
no types beyond the frozen ones (`EngineStatus`, `EngineStats`, `ChainMeters`, `ChainParameters`,
`OutputDevice`) and the ported models (`DualEQState`, `EQBand`, `BassProcessorState`, …).

**How this was checked.** This is a design document, so there was nothing to build. Every model
range, enum case, meter field and status state below was checked by reading the source files.
Contrast ratios were worked out by hand with the WCAG 2.x relative-luminance formula from the hex
values listed. QA must re-check them with a contrast tool (§15). Nothing here has been rendered
or tested on screen yet.

Priorities: **P0** = needed for the first build that Kevin uses daily · **P1** = before calling it done ·
**P2** = nice to have.

---

## 1. Brand personality

**Precise · Friendly · Honest**

| Word | What it means on screen |
|---|---|
| Precise | The graph is the DSP: the same RBJ biquads at the real sample rate (§7.1). Numbers show the units they really have (`125 Hz`, `+4.0 dB`, `Q 1.41`). Nothing is rounded into a lie. |
| Friendly | Plain words first ("Headphone correction", "Your tuning"). The jargon (Target, Fine-Tune, Q) is a small caption, never the headline. Imports show a preview before they apply. Everything can be undone. |
| Honest | The window always says where audio is going and whether it is being processed. The safety limiter says when it acts. The meter shows real gain from the DSP. Nothing moves on screen unless sound is moving. |

Same brand as the iOS app: Target blue, Fine-Tune orange, Bass Style in the light-blue secondary
accent, rounded SF figures, soft cards. On the Mac it gets native window chrome rather than the
iOS true-black canvas.

---

## 2. Competitive notes vs eqMac (the pain points we fix)

Sources: eqMac's public issue tracker (snapshot via IssueHunt / GitHub, read 2026-11-04) and
Apple's Mac help on the orange indicator. Items marked *(verify)* describe how eqMac behaves in
general. Check them against the current eqMac before using them in any marketing.

| # | eqMac pain point | What EQtargets does instead |
|---|---|---|
| 1 | **Volume keys**: the tracker has reports of keyboard volume keys not working, and of a bug at 0–6% volume. | The volume keys move the virtual device's volume, which is mirrored to the real device's hardware volume (ARCHITECTURE §6). QA item V-1 checks this on every output type. |
| 2 | **Random crackling**: the tracker has several "periodic crackling" reports. | We can't promise zero crackles from the UI, but we make them visible. The status pill shows a **Dropouts** chip when `EngineStats.underruns` rises, and Settings → Driver → Diagnostics shows underruns, resyncs, drift and DSP load. |
| 3 | **AutoEQ import errors**: the tracker has an "invalid bandwidth parameter for AutoEq preset" report. | You can drop, paste (⌘V) or open (⌘O) a file, and you always get a **preview** first: filters, preamp and a mini curve. Shelves (`LSC`/`HSC`) are supported. If a file has more than 10 filters we keep the 10 that matter most and tell you which were dropped. Errors are written in plain language. |
| 4 | **Small screens**: the tracker has a feature request about using eqMac on a small screen. | The window resizes properly (min 900×620) and has a designed compact layout. Quick controls live in the menu bar popover. |
| 5 | **One curve for everything** *(verify)*: loading a preset replaces your whole EQ, so headphone correction and personal taste fight over the same bands. | Two separate layers, drawn as three curves: Correction (blue), Your tuning (orange) and Total EQ. Changing one never touches the other. |
| 6 | **Permissions** *(verify for eqMac)*: loopback-style EQ drivers publish an input stream, which costs Microphone permission and lights the orange indicator. | The driver is output-only and audio travels through shared memory. Onboarding says it plainly: *no microphone access, no orange dot.* |
| 7 | **Where is my sound going?** *(verify)*: the Sound menu says "eqMac", not your headphones. | The toolbar status pill always names the **real** device, its sample rate and latency (`AirPods Pro · 48 kHz · 21 ms`). Onboarding explains that Control Center will show "EQtargets Audio". |
| 8 | **Not native** *(verify; its open-source repo ships a web UI)*. | All SwiftUI: real menus, keyboard shortcuts, VoiceOver (graph nodes are adjustable elements), Dark Mode, Reduce Motion, focus rings. |

---

## 3. Audience and design principles

- **Primary:** headphone enthusiasts who already use AutoEQ / Squiglink. They know PEQ, want
  precision, and hate tools that hide numbers.
- **Secondary:** MacBook owners who want "better sound / more bass" and don't know what Q is.
- One screen serves both. The **graph plus plain-word layer cards** work for the casual user;
  the **band inspector** (type / Hz / dB / Q fields) works for the expert. Nothing is hidden
  behind an "Advanced" switch.

Principles (each one settles a design argument):
1. **Always show which layer you're editing.** Colour, badge and line style all say so, never colour alone.
2. **Preview, then apply.** Imports and preset loads that replace a layer can be undone (⌘Z) or previewed first.
3. **Compare is cheap, Off is heavy.** Compare uses `masterBypass`: instant, same route. Off hands the
   macOS output back to the device, so the copy keeps them clearly separate.
4. **Animate only data.** No idle animation. Meters are polled only while they're visible.

---

## 4. Information architecture

```
EQtargets.app
├── Main window ("EQtargets", single Window scene, resizable, min 900×620)
│   ├── Toolbar: Power · Output status pill (+ Limiting/Clipping/Dropouts chip) · Compare · Import · Bass Style panel toggle
│   ├── Banner slot (driver missing / error / compare active) — 0 or 1 at a time
│   ├── Layer cards: [Headphone correction (Target)] [Your tuning (Fine-Tune)]  ← also the layer switch
│   ├── Response graph (Correction · Your tuning · Total EQ, draggable nodes of the edited layer)
│   ├── Band editor: band strip 1…10 + inspector (Type, Frequency, Gain, Q, On, Reset) + layer Preamp
│   └── Bass Style: inspector column (regular width) │ compact row + "Details…" (compact width)
├── Sheets on the main window
│   ├── Import preview (and its error variant)
│   ├── Save / Save As / Rename (name field)  ·  Delete confirmation (alert)
├── Menu bar extra (popover, 360 pt): power, status, output, correction, tuning, compare, Bass chips + mini meter, open/settings/quit
├── Settings window (⌘,): General · Audio · Corrections · Driver (+ Diagnostics)
├── Onboarding window (first run, or "Install Driver…" from the banner): Welcome → Driver → Installing → Done
└── Menus: EQtargets · File · Edit · EQ · View · Window · Help (§6.9)
```

**Data the UI presents** (all of it already exists in the models and the frozen API):
- A **Correction** is an `EQPreset` for the Target layer, plus optional bindings to output device
  UIDs ("Use for AirPods Pro").
- A **Tuning** is an `EQPreset` for the Fine-Tune layer.
- **Bass Style** is a single global `BassProcessorState`, the same as on iOS.
- **Status** comes from `EngineController.status`, `.currentOutput`, `.stats` and `.meters()`.

**Why there's no sidebar.** The skill's default for Mac apps is NavigationSplitView. EQtargets is a
single-document utility (like the Sound settings pane or Audio MIDI Setup). Its job is to look at
one curve while changing it, so a sidebar would add a navigation level and take width from the
graph. The library (corrections and device bindings) lives in the layer-card menus and in
Settings → Corrections. The native trailing **`.inspector`** column gives Bass Style its own
panel without inventing new chrome.

---

## 5. Wireframes

Glyph key: `(⏻ On)` toggle · `( … ⌄)` popup / menu · `[ … ]` button or field · `⇕` stepper ·
`①…⑩` band nodes · `━` solid curve · `┅` dashed curve · `▬` Total EQ (thick) · `◀` preamp handle ·
`░│███` centre-anchored meter.

### 5.1 Main window, regular width (≥ 1040 pt; default 1180 × 740)

```
┌──────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│ ● ● ●  (⏻ On)        ( ● 🎧 AirPods Pro · 48 kHz · 21 ms    ⌄ ) [Limiting]      [◐ Compare] [⤓ Import] [▥]  │ ← unified toolbar
├────────────────────────────────────────────────────────────────────────────────┬─────────────────────────────┤
│                                                                                │ Bass Style              (i) │
│  ┌──────────────────────────────────────┐  ┌──────────────────────────────────┐│ ┌─────────────────────────┐ │
│  │ ━━ Headphone correction  [✎ Editing] │  │ ┅┅ Your tuning              (On) ││ │(Off)(Punch)(Rumble)(Clean)│
│  │ ( Sennheiser HD 600            ⌄ )   │  │ ( Warm evening — Edited    ⌄ )   ││ │ Tight attack, controlled│ │
│  │ 🔗 Used for AirPods Pro         (On) │  │ Fine-Tune · on top of correction ││ │ sub                     │ │
│  └──────────────────────────────────────┘  └──────────────────────────────────┘│ └─────────────────────────┘ │
│  ┌──────────────────────────────────────────────────────────────────────────┐  │ ┌─────────────────────────┐ │
│  │ ━ Correction  ┅ Your tuning  ▬ Total EQ             Peak +4.2 dB · 62 Hz │  │ │ Strength            60% │ │
│  │ +12 ┊                                                                    │  │ │ ━━━━━━━━━━●──────────── │ │
│  │     ┊                                                                    │  │ │ Cutoff · recommended    │ │
│  │  +6 ┊        ③                                                           │  │ │                   85 Hz │ │
│  │     ┊     ②╱▬▬╲                                         ⑨                │  │ │ ━━━━●────────────────── │ │
│  │   0 ①▬▬▬▬▬╱    ╲▬▬④▬▬▬▬⑤▬▬▬▬▬⑥▬▬▬▬▬▬⑦▬▬▬▬▬▬⑧▬▬▬▬▬▬▬╱▬▬╲▬▬▬▬⑩▬▬▬▬▬▬▬▬▬▬▬▬  │  │ │ Post gain       +0.0 dB │ │
│  │     ◀                                                                    │  │ │ ──────────────●──────── │ │
│  │  −6 ┊                                                                    │  │ └─────────────────────────┘ │
│  │ −12 ┊                                                                    │  │ ┌ DYNAMICS ───────────────┐ │
│  │      20    50    100   200    500   1k    2k    5k    10k   20k          │  │ │ Attack emphasis     50% │ │
│  └──────────────────────────────────────────────────────────────────────────┘  │ │ ━━━━━━━━━●───────────── │ │
│  ┌──────────────────────────────────────────────────────────────────────────┐  │ │ Sustain control     Off │ │
│  │ [1·31] [2·63] [3·125] [4·250] [5·500] [6·1k] [7·2k] [8·4k] [9·8k] [10·16k]│  │ │ ●────────────────────── │ │
│  │ Band 3  Type ( Peak ⌄ )  Frequency [ 125 Hz ]⇕  Gain [ +4.0 dB ]⇕  Q [ 1.41 ]⇕│ │ Punch activity  +3.2 dB │ │
│  │ [✓] On   [↺ Reset band]                       Correction preamp [ −6.2 dB ]⇕│  │ │ ░░░░░░░░░░│█████░░░░░░░ │ │
│  └──────────────────────────────────────────────────────────────────────────┘  │ │ trim             boost  │ │
│                                                                                │ │ Attack lifts the leading│ │
│                                                                                │ │ edge of kicks. Sustain… │ │
│                                                                                │ └─────────────────────────┘ │
│                                                                                │ Runs after both EQ layers.  │
│                                                                                │ Never changes your bands.   │
└────────────────────────────────────────────────────────────────────────────────┴─────────────────────────────┘
```

Vertical budget at 740 pt: toolbar 52, padding 24, layer cards 92, gap 12, band card 140, gap 12,
bottom padding 24, which leaves **384 pt for the graph**. Inspector column: ideal 300, min 280, max 360.
Main-column content padding 24.

### 5.2 Main window, compact width (900–1039 pt; e.g. 960 × 640)

Changes from regular: Bass Style collapses into a compact row (the same component as the
menu-bar popover) with a **Details…** button that opens the inspector. Layer cards shrink to one
line, and the binding and on/off controls move into their menus. The band inspector wraps to two rows.

```
┌───────────────────────────────────────────────────────────────────────────────────────┐
│ ● ● ●  (⏻ On)   ( ● 💻 MacBook Pro Speakers · 48 kHz · 21 ms  ⌄ )      [◐] [⤓] [▥]  │
├───────────────────────────────────────────────────────────────────────────────────────┤
│  ┌─────────────────────────────────────────┐ ┌─────────────────────────────────────┐ │
│  │ ━━ Headphone correction ( HD 600 ⌄ ) ✎  │ │ ┅┅ Your tuning ( Flat / Neutral ⌄ ) │ │
│  └─────────────────────────────────────────┘ └─────────────────────────────────────┘ │
│  ┌─────────────────────────────────────────────────────────────────────────────────┐ │
│  │ ━ Correction ┅ Your tuning ▬ Total EQ                     Peak +4.2 dB · 62 Hz │ │
│  │ +12 ┊                                                                           │ │
│  │   0 ①▬▬②▬▬③▬▬▬④▬▬▬⑤▬▬▬⑥▬▬▬⑦▬▬▬⑧▬▬▬⑨▬▬▬⑩▬▬▬▬▬▬▬▬▬▬▬▬                            │ │
│  │ −12 ┊                                                                           │ │
│  │      20      100     200      1k      2k       10k   20k     (50/500/5k hidden) │ │
│  └─────────────────────────────────────────────────────────────────────────────────┘ │
│  ┌─────────────────────────────────────────────────────────────────────────────────┐ │
│  │ [1·31] [2·63] [3·125] [4·250] [5·500] [6·1k] [7·2k] [8·4k] [9·8k] [10·16k]       │ │
│  │ Band 3  ( Peak ⌄ )  [ 125 Hz ]⇕  [ +4.0 dB ]⇕  Q [ 1.41 ]⇕                       │ │
│  │ [✓] On  [↺]                                        Correction preamp [ −6.2 dB ]⇕│ │
│  └─────────────────────────────────────────────────────────────────────────────────┘ │
│  ┌─────────────────────────────────────────────────────────────────────────────────┐ │
│  │ Bass  (Off)(Punch)(Rumble)(Clean)    ░░░░│███░░  +3.2 dB          [Details…]     │ │
│  └─────────────────────────────────────────────────────────────────────────────────┘ │
└───────────────────────────────────────────────────────────────────────────────────────┘
```

Vertical budget at the 620 pt minimum: toolbar 52, padding 16, layer row 44, gap 12, band card 128,
gap 12, Bass row 56, padding 16, gaps 12, which leaves **272 pt for the graph** (floor 240).
If the user opens the inspector at compact width, the compact Bass row hides, so the two never
show at once.

### 5.3 Main window states

```
Driver missing (banner sits above the layer cards; everything else stays editable)
┌──────────────────────────────────────────────────────────────────────────────┐
│ ⚠  EQtargets needs its audio driver to process sound.     [Install Driver…]  │
│    You can set up your EQ now — it applies once the driver is installed.     │
└──────────────────────────────────────────────────────────────────────────────┘

Compare active (held or ⌘B-locked) — banner inside the graph header, curves at 30 % opacity,
flat 0 dB line drawn in primary
┌──────────────────────────────────────────────────────────────────────────────┐
│ ◐ Original sound — EQ and Bass Style are off            [Stop Comparing ⌘B]  │
│ ┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄ (0 dB line) ┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄ │
└──────────────────────────────────────────────────────────────────────────────┘

Drag a file over the window (whole content area is the drop target)
┌──────────────────────────────────────────────────────────────────────────────┐
│ ╭┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄╮ │
│ ┆                         ⤓  Drop to preview                               ┆ │
│ ┆                    headphone correction                                ┆ │
│ ╰┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄╯ │
│  2 pt dashed accent border, inset 8, radius 12, regular material veil         │
│  Wrong file type → border + glyph turn danger: "Only AutoEQ .txt files"       │
└──────────────────────────────────────────────────────────────────────────────┘

Off / not applied — the graph stays fully editable; a caption chip sits top-right of the plot:
   [ Off — not applied ]    or    [ Not applied — driver not installed ]

Both layers flat — centred caption on the plot:
   "Flat — drag a dot to shape your sound, or drop an AutoEQ file here."
```

### 5.4 Import preview sheet (520 × ~600, sheet on the main window)

```
┌──────────────────────────────────────────────────────────────┐
│  Preview headphone correction                                │ 17 semibold rounded
│  Sennheiser HD 600 ParametricEQ.txt · 10 filters             │ 11 secondary
│ ┌──────────────────────────────────────────────────────────┐ │
│ │ ━ New   ┅ Current                                        │ │ mini curve 480×140,
│ │      ╱‾‾╲                                    ╱╲          │ │ same renderer as §7,
│ │ ━━━━╱    ╲━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━╱  ╲━━━━━━━  │ │ no nodes, not interactive
│ └──────────────────────────────────────────────────────────┘ │
│  Name      [ Sennheiser HD 600                          ]    │
│  Preamp    −6.4 dB                                       (i) │
│            File said −6.2 dB — we measured −6.4 dB from the  │
│            filters, which is what keeps it from clipping.    │
│ ┌──────────────────────────────────────────────────────────┐ │
│ │  #  Type         Frequency      Gain      Q     On       │ │ native Table,
│ │  1  Low Shelf      105 Hz     +6.5 dB   0.70    ✓        │ │ read-only, 10 rows,
│ │  2  Peak           161 Hz     −2.9 dB   0.44    ✓        │ │ scrolls if short
│ │  …                                                       │ │
│ │ 10  High Shelf   10.0 kHz     −3.1 dB   0.70    ✓        │ │
│ └──────────────────────────────────────────────────────────┘ │
│  ⚠ This file has 12 filters. EQtargets uses 10, so we kept   │ (only when dropped)
│    the ones that shape the sound most. Dropped: 0.3 dB at    │
│    6.1 kHz, 0.2 dB at 14 kHz.                                │
│  [✓] Use for AirPods Pro                                     │ checkbox, default ON
│      Loads automatically whenever AirPods Pro is the output. │ only if a real output exists
│  Your tuning stays exactly as it is.                         │
│                                    [Cancel] [Apply Correction]│ Return = Apply, Esc = Cancel
└──────────────────────────────────────────────────────────────┘

Error variant (same sheet size, no table)
┌──────────────────────────────────────────────────────────────┐
│  ⚠  No EQ filters found                                      │
│  EQtargets reads AutoEQ “ParametricEQ.txt” files — lines like│
│  “Filter 1: ON PK Fc 105 Hz Gain 6.5 dB Q 0.70”. GraphicEQ   │
│  and convolution files aren't supported.                     │
│  [Find Your Headphones on AutoEQ ↗]                          │
│                       [Close] [Choose Another File…]         │
└──────────────────────────────────────────────────────────────┘
```

### 5.5 Menu bar popover (MenuBarExtra `.window`, 360 pt wide, ≤ 440 pt tall)

```
┌────────────────────────────────────────────────┐
│  EQtargets                            (⏻ On)   │ 13 semibold
│  ● AirPods Pro · 48 kHz · 21 ms                │ 11 secondary (status, same states as pill)
│ ────────────────────────────────────────────── │
│  Output        ( Follow macOS (AirPods Pro) ⌄ )│ rows 32 pt
│  Correction    ( AirPods Pro                ⌄ )│
│  Your tuning   ( Warm evening               ⌄ )│
│  [          ◐  Hold to Compare             ]   │ full width, 32 pt
│ ────────────────────────────────────────────── │
│  Bass Style                                    │
│  (Off) (Punch) (Rumble) (Clean)                │ chips 28 pt, same component
│  ░░░░░░░░│████░░░░░░        +3.2 dB            │ mini meter 4 pt + 11 pt readout
│ ────────────────────────────────────────────── │
│  [Open EQtargets]               Settings…  Quit│
└────────────────────────────────────────────────┘
```
Driver missing: rows 2–4 are replaced by *"Audio driver not installed"* + **[Install Driver…]**.
The Bass meter row hides when the style is Off or Clean.

### 5.6 Onboarding (separate window, 560 × 460, not resizable, centred)

```
1 Welcome                                      2 Driver
┌──────────────────────────────────────────┐   ┌──────────────────────────────────────────┐
│               [ app icon 96 ]            │   │  One small audio driver                  │ 22 bold rounded
│  Better sound for everything on your Mac │   │  EQtargets adds an audio device called   │
│                                          │   │  “EQtargets Audio”. Your Mac sends sound │
│  🎧 Headphone correction                 │   │  to it, EQtargets shapes it, and plays it│
│     Import your headphones' AutoEQ       │   │  on your speakers or headphones.         │
│     profile in one drop.                 │   │  🔑 One password prompt                  │
│  🎚 Your tuning                          │   │  🎙 No microphone access — no orange dot │
│     Shape the sound on top, without      │   │  ⏺ Nothing recorded, nothing sent        │
│     losing the correction.               │   │  ⌫ Easy to remove (Settings → Driver)    │
│  〰 Bass Style                           │   │  Sound pauses for a few seconds while    │
│     Punch or Rumble that reacts to the   │   │  macOS restarts its audio.               │
│     music.                               │   │                                          │
│                              [Continue]  │   │              [Not Now] [Install Driver]  │
└──────────────────────────────────────────┘   └──────────────────────────────────────────┘
3 Installing                                   4 Done
┌──────────────────────────────────────────┐   ┌──────────────────────────────────────────┐
│  Installing…                             │   │              ✓ (positive, 48)            │
│  ✓ Copying the driver                    │   │  You're all set                          │
│  ◌ Restarting macOS audio                │   │  Listening on MacBook Pro Speakers.      │
│  ○ Waiting for EQtargets Audio           │   │  Pick headphones in Control Center as    │
│  ───────────── (indeterminate) ───────── │   │  usual — EQtargets follows them.         │
│  Sound may pause for a few seconds.      │   │  [✓] Show in menu bar                    │
│                                          │   │  [ ] Open at login                       │
│                              (disabled)  │   │                       [Start EQtargets]  │
└──────────────────────────────────────────┘   └──────────────────────────────────────────┘
Cancelled password → "Installation cancelled" · "Nothing was changed. EQtargets needs the
driver to shape your Mac's sound."  [Not Now] [Try Again]
Failure → "Installation didn't finish" · <error text> · [Copy Details] [Try Again]
```
Step transitions: crossfade plus 8 pt horizontal slide, 350 ms ease-in-out (Reduce Motion: crossfade only, 150 ms).

### 5.7 Settings (⌘,; native `TabView` + `Form(.grouped)`, 560 wide)

```
General                                        Audio
┌──────────────────────────────────────────┐   ┌──────────────────────────────────────────┐
│ [✓] Open EQtargets at login              │   │ Output     ( Follow macOS            ⌄ ) │
│ [✓] Show in menu bar                     │   │   Follow macOS uses whatever you pick in │
│ [✓] Show in Dock                         │   │   Control Center or Sound settings.      │
│     When hidden, use the menu bar icon   │   │ [✓] Safety limiter (recommended)         │
│     to open EQtargets.                   │   │   Catches overs at −1 dB so boosts never │
│ [✓] Turn on when EQtargets opens         │   │   clip. Only acts when needed.           │
│ Quitting EQtargets turns it off and      │   │                                          │
│ gives macOS its output back.             │   │                                          │
└──────────────────────────────────────────┘   └──────────────────────────────────────────┘
Corrections                                    Driver
┌──────────────────────────────────────────┐   ┌──────────────────────────────────────────┐
│ Name               Used for       Filters │   │ Status    ● Installed — EQtargets Audio  │
│ Sennheiser HD 600  —                 10   │   │ [Reinstall Driver…] [Uninstall Driver…]  │
│ AirPods Pro        AirPods Pro        8   │   │ ▸ Diagnostics                            │
│ [+] [−]  [Rename…]       [Import…]        │   │   Sample rate 48 kHz · Buffer 512        │
│ Double-click a name to rename.            │   │   Latency 21 ms · Clock drift +3.1 ppm   │
└──────────────────────────────────────────┘   │   Underruns 0 · Resyncs 0 · DSP load 2 % │
                                               └──────────────────────────────────────────┘
```
"Show in menu bar" and "Show in Dock" can never both be off: the last one still on is disabled,
with the help text "EQtargets needs at least one way to be opened."

---

## 6. Interaction spec

### 6.1 Layers
- The **layer cards are the layer switch.** Clicking anywhere on a card that isn't one of its
  controls selects that layer (`DualEQState.editingLayer`). ⌘1 selects Correction, ⌘2 selects Your
  tuning. Clicking a legend item in the graph does the same.
- The default editing layer is **Your tuning**. The models already behave this way: `.flat` and
  `loadTarget` both set `.fineTune`. Most people never edit the imported correction. When they do,
  the preset name gets a "— Edited" suffix and the menu offers **Save Changes / Save as New
  Correction… / Revert to Saved**.
- Each layer has an **On** switch (`EQLayerState.isBypassed`), so you can hear Correction alone or
  Tuning alone. When a layer is off, its curve isn't drawn and its legend item reads "Correction (off)".
- Only the **edited layer's** nodes are drawn and draggable. This is deliberate: an accidental drag
  can't spoil a measured AutoEQ correction while you're tuning.

### 6.2 Graph: direct manipulation

| Input | Effect | Notes |
|---|---|---|
| Hover node | Node grows +2 pt and shows a halo; pointer `.grabIdle`; readout chip "Band 3 · Peak · 125 Hz · +4.0 dB · Q 1.41" | chip placement §7.5 |
| Click node | Selects the band (strip and inspector follow) | clicking again on a stack of overlapping nodes selects the next band underneath |
| Drag node | x → frequency (log), y → gain; pointer `.grabActive`; live readout | updates `EngineController.apply` at ≤ 60 Hz (contract) |
| ⌥ while dragging | **Fine:** pointer movement × 0.1 | ⌥ always means "finer", everywhere |
| ⇧ while dragging | **Constrain** to the dominant axis after 4 pt of travel | design-tool convention |
| Scroll / two-finger swipe over a node | Q: each 10 pt of scroll multiplies Q by 2^(1/6), ⌥ = 2^(1/24); clamped 0.1…10 | `scrollingDeltaY` used as delivered, so the user's natural-scrolling setting is respected; positive = narrower. QA G-3 checks both settings |
| Pinch (trackpad) with a band selected | Q = Q_start ÷ magnification (spread fingers = wider bell) | `MagnifyGesture` |
| Double-click node | Gain → 0 dB (frequency, Q and type kept) | same as ⌘⌫ |
| Drag near 0 dB | Snaps to 0.0 dB within ±0.3 dB (not in ⌥ fine mode); Force Touch trackpads get an `.alignment` haptic (P2) | |
| Right-click node | Menu: Type ▸ (Peak / Low Shelf / High Shelf) · Turn Band Off/On · Reset Band · Copy Band Values | |
| Click empty plot | Deselect | no band creation: the band count is fixed at 10 |
| Right-click empty plot | Scale ▸ Auto / ±12 dB / ±24 dB · Show Correction Curve · Show Your Tuning Curve | |
| Drag preamp handle `◀` (left edge) | Edited layer's preamp | double-click = **Auto preamp**: −max(peak of that layer's bands, 0), the same rule `AutoEQParser` uses |
| Hover empty plot (P2) | Faint vertical hairline; the header readout shows "1.2 kHz · Total +2.3 dB" instead of the peak | |

**Keyboard (graph focused, band selected):**

| Key | Effect | ⌥ (fine) | ⇧ (coarse) |
|---|---|---|---|
| ← / → | Frequency ÷/× 2^(1/24) | 2^(1/96) | 2^(1/3) |
| ↑ / ↓ | Gain ±0.5 dB | ±0.1 dB | ±3 dB |
| `[` / `]` | Q ÷/× 2^(1/6) (wider / narrower) | 2^(1/24) | — |
| 1…9, 0 | Select band 1…10 | | |
| ⌘[ / ⌘] | Previous / next band (also in the EQ menu) | | |
| ⌘⌫ | Reset band gain | | |
| Esc | Deselect | | |
| Tab | Leaves the graph (standard focus order; never trapped) | | |

### 6.3 Band strip and inspector
- **Band strip:** 10 pills, `Band n · freq` (`3·125`). Selected pill = layer-tinted fill and stroke.
  Disabled band = dashed border, tertiary text. A shelf shows a tiny shelf glyph after the number.
- **Inspector fields:** Type (`Picker` menu: Peak / Low Shelf / High Shelf, from `EQFilterType.title`) ·
  Frequency · Gain · Q (`TextField` + `Stepper`) · On (checkbox) · Reset band (icon button) · layer
  Preamp (labelled "Correction preamp" or "Tuning preamp").
- **Parsing input:** Frequency accepts `1200`, `1.2k`, `1.2 kHz`, `1,200`. Gain accepts `-3`, `−3`, `3`,
  `+3 dB`. Out-of-range input is clamped to the model range (f 20…20 000, gain ±20, Q 0.1…10,
  preamp ±20), and the field flashes the clamped value once (150 ms). Unparseable input reverts on
  commit, and the field shakes 3 pt × 2 (Reduce Motion: no shake, the field border shows danger for 1 s).
- **Steppers:** frequency × or ÷ 2^(1/12) · gain ±0.5 dB · Q × or ÷ 2^(1/6) · preamp ±0.5 dB.
  ↑/↓ inside a focused field do the same (⌥ fine, ⇧ coarse, as in §6.2).
- **Display formats:** frequency `31.5 Hz` (< 100: one decimal, trailing .0 dropped) · `125 Hz` · `1.25 kHz`
  (≥ 1 k: 3 significant digits) · gain `+4.0 dB` / `−3.0 dB` / `0.0 dB` (U+2212 minus) · Q `1.41`.
  All figures use `.monospacedDigit()`.
- With no band selected, the inspector shows the controls of the band last selected for that layer
  (band 1 by default). It never shows an empty state.

### 6.4 Compare (A/B)
- **Hold to peek, click to lock.** A press shorter than 250 ms toggles a latch. A longer hold is
  momentary: bypass on at press-down (no delay), off on release. ⌘B toggles the latch. Holding the
  **B** key (no modifiers, main window, no text field editing) works like holding the button.
  VoiceOver activation toggles the latch.
- Compare drives `ChainParameters.masterBypass`, which bypasses the whole chain including Bass
  Style. It never touches power or routing, so it is instant and can't glitch.
- While comparing: the button is drawn inverted ("◐ Original"), the graph banner from §5.3 shows, and
  curves drop to 30% opacity. You can still edit, and the banner stays up.
- **P2, honest A/B:** the banner adds "Original is about X dB louder", where X is the K-weighted
  loudness of the Total EQ curve against flat (computed from the curve, labelled "about"). Louder
  usually sounds "better", so this is the honest thing to show. A true level-matched compare needs
  DSP support and is listed in §16.

### 6.5 Import
- **Three entry points:** drop a file anywhere on the main window · ⌘V when no text field is
  focused (also File ▸ Paste AutoEQ from Clipboard) · ⌘O / the toolbar Import button (`fileImporter`,
  `.plainText`).
- **Every path opens the preview sheet** (§5.4). Nothing is applied until the user picks **Apply
  Correction**.
- **Apply:** `dual.loadTarget(layer)` (Fine-Tune is kept, and the editing layer becomes Your
  tuning) · save it as a new Correction named in the sheet (name collisions get " 2", " 3") ·
  optionally bind it to the current output UID · one undo step ("Undo Import Correction") · toast
  "Imported “Sennheiser HD 600”".
- **Name default:** the file name with `ParametricEQ`, `.txt`, `_` and trailing whitespace removed.
- **Limits:** files over 1 MB are rejected before parsing ("too large"). Text is decoded as UTF-8,
  falling back to Latin-1.
- **Paste without filters:** a toast "The clipboard doesn't contain AutoEQ filters." and no sheet.

### 6.6 Device binding ("Use for AirPods Pro")
- The Correction card's third row shows **🔗 Use for {current output}** (an unbound toggle-button) or
  **🔗 Used for {device}**. Clicking it when bound opens a menu: Stop Using for {device} · Use for
  Another Device ▸ (devices from `outputDevices`).
- When `onOutputChanged` fires and the new device has a binding: load that Correction (one undo
  step) and show the toast "Now playing through AirPods Pro — loaded “AirPods Pro”". With no
  binding: keep the current Correction and stay silent. The P2 alternative is an inline suggestion
  in the card: "New output: AirPods Pro · Use this correction for it?".
- Bindings are keyed by `OutputDevice.uid`, never by name. Settings → Corrections lists them.

### 6.7 Power and status
- **Power** is a native `Toggle` with a custom style (§10). It calls `setPowered`. While the status is
  `.starting`, the glyph becomes a spinner. With `.driverMissing` the toggle is disabled, and its
  help text reads "Install the audio driver first."
- **Status pill** maps `EngineStatus` one to one:

| `EngineStatus` | Leading glyph | Text | Click |
|---|---|---|---|
| `.running` | ● positive dot + transport symbol | `AirPods Pro · 48 kHz · 21 ms` | output menu |
| `.idle` | ○ ring (secondary) + transport | `AirPods Pro · Waiting for sound` | output menu |
| `.off` | ⏻ secondary | `Off · macOS plays directly to AirPods Pro` | output menu |
| `.starting` | small spinner | `Starting…` | — |
| `.driverMissing` | ⚠ warning | `Audio driver not installed` + inline **Install…** | opens onboarding at step 2 |
| `.error(msg)` | ⛔ danger | `msg` (middle-truncated; full text in help) + **Details** | popover with full text + Copy + Try Again |
| no `currentOutput` | ⚠ warning | `No output device` | output menu |

- **Chips** after the pill text (one at a time, highest first):
  **Clipping** (protection off and an over was detected) ›
  **Limiting** (`limiterReductionDB > 0.1`, or `overCount` moved with protection on) ›
  **Dropouts** (`stats.underruns` rose in the last 10 s). Each chip holds for 2 s after the last
  event, then fades out over 300 ms.
- Clicking **Limiting** or **Clipping** opens a popover. It explains what happened and offers
  **Lower Preamp to {x} dB**, where x = (Your tuning's current preamp) − (peak of the Total EQ curve,
  rounded up to 0.5 dB), clamped to −20 dB. (Erratum fixed 2026-11-05: the earlier "x = −peak" was only
  right when the tuning preamp was 0; the app implements this form.) The change is applied to Your
  tuning's preamp and is one undo step.
- **Output menu:** section "Play through" · "Follow macOS (AirPods Pro)" ✓ · then each `OutputDevice`
  (transport symbol, name, rate as secondary text) · divider · "Sound Settings…" (opens System
  Settings ▸ Sound).
- **Transport → SF Symbol:** builtIn `laptopcomputer` · bluetooth `headphones` (`airpods`/`airpodspro`/
  `airpodsmax` when the name contains those words) · usb `hifispeaker` · hdmi / displayPort `display` ·
  airPlay `airplayaudio` · thunderbolt `bolt.horizontal` · virtual / aggregate / other `speaker.wave.2`.
  QA checks that these symbol names exist.

### 6.8 Undo / redo
`UndoManager` from the environment. Coalescing: **one step per gesture** (a node drag, a slider drag, a
scroll burst ending after 400 ms idle, a pinch), per committed field, per preset load, import or
reset. Action names: "Move Band 3", "Change Q", "Change Preamp", "Load Correction", "Import
Correction", "Reset Band", "Reset Your Tuning", "Change Bass Style". Undo covers DualEQState and
BassProcessorState. Power, routing and settings are not undoable.

### 6.9 Menus and keyboard shortcuts

| Menu | Item | Shortcut |
|---|---|---|
| EQtargets | About · Settings… · Hide · Quit (Quit also turns EQtargets off) | standard (⌘, ⌘H ⌘Q) |
| File | Import AutoEQ File… | ⌘O |
| File | Paste AutoEQ from Clipboard | ⌘V (routed when no text field is focused) |
| File | Save Changes · Save As… (applies to the edited layer) | ⌘S · ⇧⌘S |
| Edit | Undo / Redo | ⌘Z / ⇧⌘Z |
| Edit | Reset Band | ⌘⌫ |
| Edit | Reset Your Tuning | ⌥⌘⌫ |
| EQ | Turn EQtargets On / Off | ⌥⌘P |
| EQ | Compare (Lock) | ⌘B |
| EQ | Edit Headphone Correction / Edit Your Tuning | ⌘1 / ⌘2 |
| EQ | Previous Band / Next Band | ⌘[ / ⌘] |
| EQ | Bass Style ▸ Off · Punch · Rumble · Clean | ⌃⌘0 · ⌃⌘1 · ⌃⌘2 · ⌃⌘3 |
| View | Show / Hide Bass Style | ⌥⌘B |
| View | Graph Scale ▸ Auto · ±12 dB · ±24 dB | — |
| View | Show Correction Curve · Show Your Tuning Curve | — |
| Help | AutoEQ Website · EQtargets Help (P2) | — |

`⌘N` is removed (`CommandGroup(replacing: .newItem) {}`) because there is a single window. Every
toolbar button's help text includes its shortcut.

---

## 7. Graph spec

### 7.1 Truth (Graph == DSP)
- Curves use `EQBiquad.magnitudeDB` at the **running sample rate** (`EngineStats.sampleRate` while
  running, else 48 kHz). They do **not** use the fixed 48 kHz of `FrequencyResponse`. Near Nyquist
  the bilinear-transform shapes differ between 44.1, 48 and 96 kHz, and the graph must show what is
  actually playing.
- **Sampling density:** at least `max(256, plotWidthPt / 2)` log-spaced points, capped at 1024,
  **plus the exact centre frequency of every enabled band** merged into the grid. Without the
  centres, the apex of a narrow peak falls between samples. A worked example: the 96-point grid that
  `FrequencyResponse` uses steps 0.105 octave, and a +12 dB, Q 10 peak is only about 0.14 octave
  wide. Worst case, that peak is drawn at about **+7.6 dB instead of +12 dB** (worked out by hand
  from the analog prototype; see the report). Cost at 512 points × 20 biquads is trivial if cos(ω)
  and cos(2ω) are cached per grid point.
- The Total EQ curve is Correction + Your tuning, each including its preamp. Bass Style is **not**
  drawn: it is post-PEQ and partly dynamic. The Bass panel says so.

### 7.2 Chassis and axes
- Chassis: radius 12, fill `graph.chassis`, 0.5 pt `separatorColor` border, no shadow, no material, no blur.
- Plot insets: top 36 (header row inside the chassis: legend at left, readout at right, 12 pt from
  the top) · leading 44 (dB labels right-aligned at x = 36) · bottom 28 · trailing 16.
- **X axis:** log10, 20 Hz…20 kHz, `x = (log10 f − log10 20) / 3 · width` (= `FrequencyResponse.xPosition`).
  Major lines with labels at 20, 50, 100, 200, 500, 1k, 2k, 5k, 10k, 20k. Minor lines with no label
  at 30–90, 300–900, 3k–9k.
- **Y axis:** **Auto** scale is ±12 dB, expanding to ±24 dB when any node or curve exceeds ±11 dB.
  The re-scale happens **only on gesture end**, animated over 250 ms ease-in-out, because a moving
  scale under a dragging finger is disorienting. ±12: major every 6 dB (labelled), minor every 3.
  ±24: major every 12 (labelled), minor every 6. Labels read `+12`, `+6`, `0`, `−6`, `−12`, with a
  `dB` caption above the top label.
- Grid strokes: 0 dB line 1 pt `text.primary` at 30%. Major lines 0.5 pt at 10%, minor lines 0.5 pt at 5%.
  These lines are decoration, so WCAG contrast doesn't apply. The 0 dB line is the one essential line.
- **X-label collisions:** a label is drawn only if its rect clears the previous drawn label by 8 pt.
  Drop order as width shrinks: first 50, 500, 5k, then 200, 2k. **20, 100, 1k, 10k, 20k always stay.**

### 7.3 Curves (z-order bottom → top)

| # | Layer | Style | Why |
|---|---|---|---|
| 1 | Total EQ fill | between the curve and the **0 dB line** (not the plot bottom), `accent.stroke` at 12% light / 18% dark | the shaded area *is* the change; boosts and cuts read symmetrically |
| 2 | Total EQ line | 3 pt, `text.primary` (label colour), round caps/joins | neutral "what you hear". Accent blue would clash with Target blue (#0073D9 vs #2673C7 are near-identical); the icon's hero curve is also white |
| 3 | Non-edited layer | 1.5 pt, layer stroke colour, dash [5, 4] | present but secondary; keeps full colour for ≥ 3:1 contrast |
| 4 | Edited layer | 2 pt, layer stroke colour, solid | sits on top of the Total line, so when they coincide you see a coloured line with a neutral halo, which reads as both |
| 5 | Nodes, preamp handle, chips | see below | |

- A flat layer (`isFlat`) isn't drawn unless it's the edited one. A bypassed layer is never drawn.
- During Compare everything drops to 30% opacity and a 1.5 pt primary 0 dB line is drawn on top.
- Curves outside the Y range clip at the plot edge, with a 6 pt chevron on the edge where they leave.
- Curves update **immediately** while dragging (direct manipulation is 1:1, with no animation). On a
  preset load, curves morph over 250 ms ease-in-out by interpolating the point arrays
  (Reduce Motion: instant).

### 7.4 Nodes (edited layer only)

| State | Visual | Size |
|---|---|---|
| Default | fill `graph.chassis`, 2 pt ring in layer stroke, number (11 pt semibold rounded) in layer ink | 20 pt visual · **28 × 28 pt hit** |
| Hover | ring 2.5 pt, halo 28 pt layer stroke at 12%, pointer `.grabIdle` | 22 pt |
| Selected | fill layer stroke, number in `onFill`, outer 2 pt `text.primary` ring at 24 pt | 20 pt + ring |
| Dragging | selected look, pointer `.grabActive`, readout chip | |
| Band off | 2 pt dashed ring [3, 2] `text.tertiary`, tertiary number; still selectable and draggable | 20 pt |
| Keyboard focus | system focus ring around the node | |
| Shelf types | same states, **rounded square (radius 5)** instead of a circle | shape coding, so type doesn't rely on colour |

- **Position:** x = band frequency, y = band gain **+ that layer's preamp**, so a node rides its own
  curve. Vertical drag converts back (gain = y − preamp). The inspector always shows the true band gain.
- **Collisions:** node positions are data and are never nudged. Hit-testing takes the selected band
  first, then the nearest centre within 14 pt. Clicking again without moving cycles through bands
  whose hit areas overlap. The band strip is always an unambiguous fallback.
- **Preamp handle:** a 14 × 20 tab on the plot's left edge at y = preamp, in the edited layer's stroke
  colour, with a 28 × 28 hit area. Its label ("Preamp −6.2 dB") appears only on hover or drag.

### 7.5 Readout chip and header
- **Chip** (hover / drag): `125 Hz · +4.0 dB · Q 1.41` (with the band name on hover), 11 pt medium
  rounded, monospaced digits, capsule, padding 8 × 4, `.thickMaterial` (solid `bg.card` under Reduce
  Transparency). Placed so its bottom is 8 pt above the node's top. If that would cross the plot top,
  it goes 8 pt below the node instead. Horizontally clamped to the plot with 4 pt inset. It never
  covers its own node.
- **Header:** legend at left (16 × 3 swatches drawn in each curve's real style, plus labels
  "Correction", "Your tuning", "Total EQ"). Readout at right: "Peak +4.2 dB · 62 Hz" from
  `FrequencyResponse.peak`, or "Flat" when there's no peak. Living in the header row, outside the
  plot, means neither can collide with nodes. This is a deliberate change from the iOS floating peak chip.

---

## 8. Bass Style panel and the live activity meter

### 8.1 Layout (inspector column; the same component appears in a sheet-like overlay from "Details…" at compact width)
1. Header: "Bass Style" (17 semibold rounded) and an (i) button whose popover gives a short
   explanation of the four styles.
2. **Style chips** (Off / Punch / Rumble / Clean: `BassStyle.compactTitle` plus `systemImage`), four
   equal-width capsules in one row, 28 pt tall. Selecting calls `selectStyle(_, applyRecommendedCutoff: true)`.
   Below them, the subtitle (`BassStyle.subtitle`; for Off the UI shows its own line, §11).
3. **Shape card** (hidden when Off): Strength `60%` · Cutoff `85 Hz` titled "Cutoff · recommended"
   while `cutoffMatchesStyleRecommendation` is true. When it isn't, a small **↺ 85 Hz** button
   restores the recommended value. · Post gain `+0.0 dB`. Native `Slider`s, tinted with `bass.stroke`.
4. **Dynamics card** (Punch and Rumble only, `hasDynamics`):
   - Punch: "Attack emphasis" (`punchAttack`), "Sustain control" (`punchSustain`).
   - Rumble: "Sustain length" (`rumbleSustain`), "Attack softening" (`rumbleSoften`).
   - Values show `Off` below 0.5%, otherwise `50%`.
   - Then the **activity meter**, then the helper text (§11).
   - Clean shows a single line in place of the card: "Clean is a steady, gentle lift — it has no dynamic stage."
5. Footer (11 secondary): "Runs after both EQ layers. Never changes your bands. Not drawn on the graph."

### 8.2 Activity meter (full size)

```
 Punch activity                                   +3.2 dB      ← 13 caption-title left / 13 semibold rounded mono readout right
 ░░░░░░░░░░░░░░░┆░░░░░░░░░│████████░░░░░░░░░░░░░░░░░░░       ← 8 pt capsule track
                ↑ trim limit (6 dB)  ↑ centre (0 dB)
 trim                                                boost     ← 11 pt secondary
```

- **Geometry:** full card width, 8 pt tall capsule track (`meter.track`). A centre tick 1 × 12 pt
  (2 pt above and below the track) in `text.primary` at 25%. Each half spans **9 dB**
  (`TransientPunchTuning.maxAttackBoostDB`, which is the largest of the four ceilings), so equal
  lengths mean equal dB on both sides and across styles.
- **Right half (boost / sustain):** grows rightward from the centre, `bass.meter`. Fed by
  `ChainMeters.punchBoostDB`.
- **Left half (trim / soften):** right-aligned in the left half so it grows leftward, `text.secondary`
  (neutral: same stage, opposite direction). Fed by `ChainMeters.punchTrimDB`.
- **Ceiling marks** (1 × 4 pt `text.tertiary` ticks at the top edge of the track) show where each half
  stops for the current style. Punch: trim 6 dB (left at 6/9), boost 9 dB (right end). Rumble:
  soften 4 dB (left at 4/9), sustain 7 dB (right at 7/9). The bar can never pass them, and the marks
  say so honestly. Values come from `TransientPunchTuning.maxSustainTrimDB` and
  `SustainRumbleTuning.maxSoftenDB / maxSustainBoostDB`.
- **Readout:** whichever side is larger: `+3.2 dB` / `−1.4 dB` / `0.0 dB` (both < 0.05). Primary
  when active, secondary when idle.
- **Ballistics (same as iOS):** instant rise. Release uses a coefficient of 0.82 per 50 ms, re-derived
  for the poll interval as `decay = pow(0.82, interval / 0.050)` (at 30 Hz: 0.876 per tick), which
  is about −45% after 150 ms. On top of that, `.animation(.easeOut(duration: 0.08))` on the bar widths.
  Reduce Motion keeps the meter live (it's data), but the bar width changes are not animated.
- **Polling:** `EngineController.meters()` at **30 Hz** (the contract maximum), only while **all** of
  these hold: the style has dynamics; the status is `.running`; the meter's window is visible and not
  occluded (`NSWindow.occlusionState`) or the popover is open. Otherwise the poll stops (no timer
  left running) and the bar shows the idle caption.
- **Idle captions** replace the readout: Off → "EQtargets is off" · idle → "Play something to see it
  move" · driver missing → "Driver not installed".
- **Labels:** Punch "trim … boost", Rumble "soften … sustain"; title "Punch activity" / "Rumble activity".
- **Mini meter** (popover and compact row): 120 × 4 pt, same semantics and scale, no ceiling marks, no
  side labels, 11 pt readout. VoiceOver is the same as the full meter.

---

## 9. Design tokens

### 9.1 Colour — roles, not just hues
Every brand hue has up to three roles. **stroke** is for graph lines and nodes (non-text, needs ≥ 3:1).
**ink** is for text in that hue (needs ≥ 4.5:1). **fill** is for a background behind a white or black
label. The brand values from iOS are kept exactly for **strokes**. Light-mode **inks** are darker
shades of the same hue, because the brand values fail AA as small text on light surfaces. That's a
change in luminance, not saturation.

Implement as dynamic `NSColor(name:dynamicProvider:)` wrapped in `Color(nsColor:)` (§14). Don't use
an asset catalog or forced themes. AppKit then resolves the appearance inside sheets, popovers and
the MenuBarExtra window automatically. (The iOS app needed manual `\.colorScheme` plumbing for
exactly this.) The Mac follows the system appearance
only, so the iOS surface skins (Warm/White/Black/Navy) are **not** ported in v1.

**Reference surfaces** used for the contrast maths:

| Token | Light | Dark | Notes |
|---|---|---|---|
| `bg.canvas` | system `windowBackgroundColor` ≈ #ECECEC | ≈ #323232 | approximate; desktop tinting shifts it a few levels |
| `bg.card` | #FFFFFF (`controlBackgroundColor`) | #1E1E1E | layer cards, band card, Bass cards |
| `graph.chassis` | #FFFFFF | #141416 | the darker "screen" inset in dark mode |
| `meter.track` | black 8% over card ≈ #EBEBEB | white 8% over card ≈ #303030 | |

**Palette:**

| Token | Light | Dark | Use |
|---|---|---|---|
| `text.primary` | system `labelColor` (≈ black 85%) | `labelColor` (≈ white 85%) | primary text, **Total EQ line** |
| `text.secondary` | **#5B5B62** | **#A1A1A6** | helper text, axis labels, meter trim fill. *Not* `secondaryLabelColor`, which is ≈ 50% alpha and works out to about 4.0:1 on white, failing AA at 11 pt |
| `text.tertiary` | #8A8A8E | #6E6E73 | **disabled / placeholder only** (WCAG exempts inactive UI); never information |
| `target.stroke` | #2673C7 | #66BFFF | Correction curve, nodes, swatch (iOS brand) |
| `target.ink` | #1F61AD | #66BFFF | Correction text |
| `target.onFill` | #FFFFFF | #141416 | number on a selected node |
| `fine.stroke` | #E0731F | #FFB359 | Your-tuning curve, nodes (iOS brand) |
| `fine.ink` | #A84D05 | #FFB359 | Your-tuning text |
| `fine.onFill` | #141416 | #141416 | number on a selected node |
| `accent.stroke` | #0073D9 | #59B3FF | Total fill tint, links, drop border (iOS blue accent) |
| `accent.ink` | #005FB8 | #59B3FF | accent text |
| `accent.fill` | #0073D9 | #0073D9 | Power **On** background (white label) in both modes |
| `bass.stroke` | #3399F2 | #8CD9FF | Bass slider tint, chip icons (iOS `accentSecondary`) |
| `bass.ink` | #1A6BBF | #8CD9FF | Bass text |
| `bass.fill` | #1A6BBF (+ white label) | #8CD9FF (+ #141416 label) | selected style chip |
| `bass.meter` | #2180D9 | #8CD9FF (75% → 100% gradient) | boost bar |
| `positive` | #17784B | #66E699 | Running dot, install success |
| `warning` | #8A5A00 | #FFC24D | driver missing, Limiting, Dropouts |
| `danger` | #C42B33 | #FF7378 | errors, Clipping, invalid drop |
| layer-selected tint | layer stroke at 16% over card | layer stroke at 20% over card | selected layer card / band pill |

Callout for the iOS app (read-only here, so not changed): its selected Bass chip draws
`theme.background` text on `accentSecondary` in light mode, which works out to about **2.8:1**. Its
light-mode `positive` gain text on white is about **4.2:1**. Both are below AA. The Mac tokens above
avoid both problems.

**Contrast (hand-computed with the WCAG 2.x formula; QA re-checks them with a tool):**

| Pair | Light | Dark | Requirement |
|---|---|---|---|
| text.primary on card / canvas | 15.1 / 13.3 | 12.3 / 9.7 | 4.5 text ✓ |
| text.secondary on card / canvas / chassis | 6.74 / 5.70 / 6.74 | 6.48 / 4.99 / 7.15 | 4.5 text ✓ |
| text.tertiary on card / canvas | 3.44 / 2.91 | 3.29 / 2.53 | disabled only (exempt) |
| target.ink on card / canvas | 6.23 / 5.27 | 8.31 / 6.39 | 4.5 ✓ |
| fine.ink on card / canvas | 5.63 / 4.77 | 9.40 / 7.23 | 4.5 ✓ |
| accent.ink on card / canvas | 6.31 / 5.34 | 7.40 / 5.69 | 4.5 ✓ |
| bass.ink on card / canvas | 5.39 / **4.56** | 10.70 / 8.23 | 4.5 ✓ (light canvas is the tightest pair) |
| positive on card / canvas | 5.49 / 4.65 | 10.59 / 8.15 | 4.5 ✓ |
| warning on card / canvas | 5.93 / 5.02 | 10.38 / 7.98 | 4.5 ✓ |
| danger on card / canvas | 5.61 / 4.75 | 6.33 / **4.87** | 4.5 ✓ (iOS dark #FF666B would be 4.50 on the dark canvas, so it was nudged to #FF7378) |
| white on accent.fill (Power On) | 4.71 | 4.71 | 4.5 ✓ |
| white on bass.fill / #141416 on bass.fill | 5.39 | 11.81 | 4.5 ✓ |
| target.onFill on target.stroke | 4.82 | 9.17 | 4.5 ✓ (11 pt number) |
| fine.onFill on fine.stroke | 5.82 | 10.38 | 4.5 ✓ |
| target.ink on selected card tint | 5.05 | 5.51 | 4.5 ✓ |
| fine.ink on selected card tint | 4.76 | 5.99 | 4.5 ✓ |
| target.stroke on chassis | 4.82 | 9.17 | 3.0 graphic ✓ |
| fine.stroke on chassis | **3.16** | 10.38 | 3.0 graphic ✓ (tight; Increase Contrast swaps it for fine.ink at 5.63) |
| Total EQ line (labelColor) on chassis | 15.1 | 13.4 | 3.0 ✓ |
| bass.meter vs meter.track | 3.42 | 8.47 | 3.0 graphic ✓ |
| trim bar (text.secondary) vs meter.track | 5.65 | 5.13 | 3.0 ✓ |

**Colour-vision safety:** blue vs orange stays distinct under protanopia and deuteranopia, and the
layers are also separated by line style (solid, dashed, thick neutral), by the legend, and by text
badges. Node *type* uses shape (circle or rounded square), not colour.

### 9.2 Typography (SF, system fonts only; no Inter bundle on the Mac)
iOS bundles Inter. On the Mac, native **SF Pro** draws all chrome, controls and menus, and
**SF Pro Rounded** (`.system(…, design: .rounded)`) carries the brand: titles, chips, figures, graph
labels and meter readouts. This matches the brief's "rounded SF", avoids shipping a font, and
keeps menus and Forms native.

| Token | Size / line | Weight | Design | Use |
|---|---|---|---|---|
| `display` | 22 / 28 | bold | rounded | onboarding titles only |
| `title` | 17 / 22 | semibold | rounded | sheet titles, "Bass Style" panel title |
| `body` | 13 / 18 | regular; medium for values; semibold for selected / labels | default (values: rounded + `monospacedDigit`) | everything interactive |
| `caption` | 11 / 14 | regular / medium / semibold | rounded for graph and meter, default otherwise | helper text, axis labels, legend, node numbers, status line |

**Sizes per screen (max 3):** main window 17 / 13 / 11 · popover 13 / 11 · import sheet 17 / 13 / 11 ·
onboarding 22 / 13 / 11 · Settings uses native Form sizes (13 / 11).
Section labels inside cards ("DYNAMICS") are caption semibold, uppercase, tracking 0.6. That's the
same size, so it doesn't count as a fourth size.

### 9.3 Spacing (4 / 8 grid)
`s1 = 4 · s2 = 8 · s3 = 12 · s4 = 16 · s6 = 24 · s8 = 32`.
- Window content padding: 24 regular, 16 compact. Inspector padding 16.
- Card padding 16 (12 in the compact row and the popover). Gap between cards 12. Rows inside a card 8.
  Groups inside a card 16.
- Control heights: native regular size for fields, steppers and popups. Custom controls: chips 28,
  band pills 32, power toggle 28 × 64, status pill 28 (min 280, max 520 wide), popover rows 32.
- **Hit targets.** The skill's 44 pt is iOS *touch*. A Mac pointer is precise, and native Mac
  controls are 20–28 pt. Rule: native controls keep native sizing, and **every custom target is ≥ 28 pt**
  (graph nodes and the preamp handle 28 × 28, chips 28 high, meter not interactive). That clears the
  brief's ≥ 24 pt floor.

### 9.4 Radii
`r6` text fields (native) · `r8` band pills, small buttons · `r12` cards, graph chassis, drop border ·
`r16` onboarding feature tiles · `capsule` chips, status pill, power toggle, meter, readout chip, toast ·
node = circle (peak) / `r5` square (shelf). All continuous corners (`style: .continuous`).

### 9.5 Materials and elevation
- Window, toolbar, inspector column, Settings, popover: **system materials, untouched**.
- Cards: **solid** `bg.card` plus a 0.5 pt `separatorColor` border. In light mode only, add a shadow of
  black 6%, radius 2, y 1. **No shadow in dark mode.** Cards are solid on purpose: contrast stays
  predictable (§9.1), and ten-plus live materials are a GPU cost for no information.
- "Subtle glass" (brand) goes only on **floating** things (toast, drag readout chip, compare banner,
  drop veil): `if #available(macOS 26, *) { .glassEffect(.regular) } else { .regularMaterial }`.
  Under Reduce Transparency, use solid `bg.card` with a 0.5 pt border.

### 9.6 Motion

| Token | Value | Use |
|---|---|---|
| `motion.hover` | 120 ms ease-out | hover fills, node grow |
| `motion.select` | 200 ms ease-in-out | chip and band selection, layer-card highlight |
| `motion.spring` | spring(response 0.30, damping 0.80) | layer switch: the "Editing" badge and tint move between cards (matchedGeometryEffect) |
| `motion.curve` | 250 ms ease-in-out | preset-load curve morph, graph re-scale |
| `motion.screen` | 350 ms ease-in-out | onboarding steps, sheet content swaps |
| `motion.toast` | in 200 ms ease-out (fade + 8 pt rise) · hold 4 s · out 200 ms ease-in | toasts |
| `motion.chip` | appear instantly · hold 2 s · fade out 300 ms ease-out | Limiting / Clipping / Dropouts |
| `motion.meter` | instant rise · 0.82 per 50 ms release · 80 ms ease-out on width | activity meters |
| press | scale 0.97, 120 ms ease-out | custom buttons and chips |

Nothing is linear and nothing loops or animates while idle. **Reduce Motion:** springs, slides and
scales become 150 ms crossfades; curve morphs and re-scales are instant; field shake becomes a border
flash; meters stay live but aren't eased.

---

## 10. Component inventory and states

| Component | Default | Hover | Pressed | Disabled | Active / selected | Loading | Error |
|---|---|---|---|---|---|---|---|
| **PowerToggle** (custom `ToggleStyle`) | Off: clear capsule, 0.5 pt separator border, "⏻ Off" secondary | +6% primary fill | scale 0.97 | driver missing: Off look at 40%, help "Install the audio driver first." | On: `accent.fill`, white "⏻ On" | `.starting`: spinner replaces ⏻ | `.error`: Off look; the pill carries the error |
| **StatusPill** | glyph + text (§6.7) on primary 6% (light) / white 8% (dark) capsule | +4% fill | 0.97 | — | output menu open: +8% fill | `Starting…` + spinner | danger glyph + message + Details |
| **StatusChip** (Limiting / Clipping / Dropouts) | hidden | underline + pointer | — | — | Limiting/Dropouts: `warning` text on warning 14%; Clipping: white on `danger` | — | — |
| **CompareButton** | bordered "◐ Compare" | native hover | momentary bypass while held | driver missing / off: disabled, help "Turn EQtargets on to compare." | inverted (primary fill, inverse label) "◐ Original"; latched shows a lock glyph | — | — |
| **LayerCard** | `bg.card`, swatch line, title, profile popup, meta row | border → layer stroke 40% | 0.99 | — | layer tint 16% / 20% fill, 1 pt layer stroke, "✎ Editing" badge (layer ink) | — | — |
| **ProfilePicker** (Menu) | name + ⌄ | native | native | no presets: "None" | "— Edited" suffix when dirty | — | — |
| **ResponseGraph** | §7 | crosshair (P2) | — | power off / driver missing: "Not applied" chip; fully editable | focus ring when keyboard-focused | — | — |
| **BandNode** | §7.4 | §7.4 | dragging | band off: dashed ring | selected | — | value clamped at a range edge: a 1 pt danger ring flashes once (150 ms) |
| **BandPill** | number · freq, card fill, 0.5 pt border | border layer stroke 40% | 0.97 | band off: dashed border, tertiary text | layer tint fill + 1 pt layer stroke | — | — |
| **ValueField** (TextField + Stepper) | native | native | native | — | native focus ring | — | unparseable: revert + shake (or a 1 s danger border under Reduce Motion) |
| **StyleChips** | `bg.card`, 0.5 pt border, icon + label primary | +4% primary fill | 0.97 | — | `bass.fill` + on-fill label | — | — |
| **LabeledSlider** | title (secondary) · value (primary mono) · native Slider tinted `bass.stroke` | native | native | parent Off: hidden (not greyed) | — | — | — |
| **ActivityMeter** (full / mini) | §8.2 | — | — | not `hasDynamics`: not shown | live | — | idle caption |
| **DropOverlay** | hidden | — | — | — | `isTargeted`: veil + 2 pt dashed accent border | — | invalid type: danger border + "Only AutoEQ .txt files" |
| **ImportPreviewSheet** | §5.4 | — | — | Apply disabled while Name is empty | — | parsing > 100 ms: spinner over the table | error variant (§5.4) |
| **Banner** (driver missing / error / compare) | full width, 12 pt padding, glyph + text + action | — | — | — | — | — | error: danger glyph, Try Again + Copy Details |
| **Toast** | capsule, floating glass, top centre of the graph | pauses the hold timer | — | — | — | — | — |
| **OnboardingStep** | §5.6 | — | — | Install disabled while installing | step dots (4, current = accent) | progress list | cancelled / failure variants |
| **PopoverRow** | label + popup, 32 pt | native | native | driver missing: row hidden | — | — | — |

Empty and edge states: no Corrections → picker shows "None (flat)" plus Import. Device names longer
than the pill → middle truncation with the full name in the help tooltip. Preset names → tail
truncation in cards, names capped at 60 characters. A 30% localisation length budget is allowed for
every label, and ViewThatFits handles the band inspector wrap.

---

## 11. Copy deck

Style: sentence case for labels and helper text; **Title Case for buttons and menu items** (macOS
HIG); "…" (U+2026) for commands that ask for more input; "−" (U+2212) for negative numbers; curly
quotes; a no-break space (U+00A0) between number and unit; `%` without a space (`60%`); units Hz,
kHz, dB, ms. Plain words first, jargon in captions.

### 11.1 Toolbar and status
| ID | String |
|---|---|
| power.on / off | `On` · `Off` |
| power.help.on | `Turn EQtargets off — macOS plays straight to {device} (⌥⌘P)` |
| power.help.off | `Turn EQtargets on (⌥⌘P)` |
| power.help.disabled | `Install the audio driver first.` |
| status.running | `{device} · {rate} · {latency}` → `AirPods Pro · 48 kHz · 21 ms` |
| status.idle | `{device} · Waiting for sound` |
| status.off | `Off · macOS plays directly to {device}` |
| status.starting | `Starting…` |
| status.driverMissing | `Audio driver not installed` · button `Install…` |
| status.error | `{message}` · button `Details` |
| status.noDevice | `No output device` |
| status.help.running | `Sound from every app is being shaped and played on {device}.` |
| status.help.idle | `Nothing is playing. EQtargets uses no power until sound starts.` |
| output.section | `Play through` |
| output.follow | `Follow macOS ({device})` |
| output.soundSettings | `Sound Settings…` |
| chip.limiting | `Limiting` |
| chip.limiting.help | `Your EQ pushed the sound past 0 dB. The safety limiter caught it, so nothing clipped — lowering the preamp keeps it cleaner.` |
| chip.clipping | `Clipping` |
| chip.clipping.help | `The sound is clipping. Lower the preamp, or turn on the safety limiter in Settings → Audio.` |
| chip.fix | `Lower Preamp to {x} dB` |
| chip.dropouts | `Dropouts` |
| chip.dropouts.help | `The audio briefly ran dry {n} times in the last few seconds. If you hear crackles, open Settings → Driver → Diagnostics.` |
| compare.label / active | `Compare` · `Original` |
| compare.help | `Hold to hear your Mac without EQtargets. Click to lock (⌘B).` |
| compare.help.disabled | `Turn EQtargets on to compare.` |
| compare.banner | `Original sound — EQ and Bass Style are off` · button `Stop Comparing` |
| compare.banner.loudness (P2) | `Original is about {x} dB louder — louder usually sounds “better”.` |
| import.label | `Import` |
| import.help | `Import an AutoEQ ParametricEQ.txt (⌘O). You can also drop the file here or paste it with ⌘V.` |
| bassPanel.help | `Show or hide Bass Style (⌥⌘B)` |

### 11.2 Layers, graph, bands
| ID | String |
|---|---|
| layer.target.title | `Headphone correction` |
| layer.target.caption | `Target · from AutoEQ` |
| layer.fine.title | `Your tuning` |
| layer.fine.caption | `Fine-Tune · on top of the correction` |
| layer.editing | `Editing` |
| layer.edited.suffix | ` — Edited` |
| layer.on.a11y | `Headphone correction on` · `Your tuning on` |
| bind.unbound | `Use for {device}` |
| bind.bound | `Used for {device}` |
| bind.stop | `Stop Using for {device}` |
| bind.other | `Use for Another Device` |
| target.menu | `None (flat)` · `Import AutoEQ File…` · `Paste from Clipboard` · `Save Changes` · `Save as New Correction…` · `Revert to Saved` · `Rename…` · `Delete…` · `Manage Corrections…` |
| fine.menu | {built-ins} · {user presets} · `Save Changes` · `Save as New Preset…` · `Revert to Saved` · `Reset to Flat` · `Rename…` · `Delete…` |
| save.title / field / button | `Save Correction` / `Save Preset` · `Name` · `Save` |
| delete.title / body | `Delete “{name}”?` · `This can't be undone. Devices using it go back to no correction.` · buttons `Delete` `Cancel` |
| legend | `Correction` · `Your tuning` · `Total EQ` · off state `Correction (off)` |
| graph.peak | `Peak {+x.x dB} · {f}` |
| graph.flat | `Flat` |
| graph.hover (P2) | `{f} · Total {g}` |
| graph.empty | `Flat — drag a dot to shape your sound, or drop an AutoEQ file here.` |
| graph.notApplied | `Off — not applied` · `Not applied — driver not installed` |
| graph.scale | `Auto` · `±12 dB` · `±24 dB` |
| node.readout | `Band {n} · {Type} · {f} · {g} · Q {q}` |
| band.pill | `{n}·{f}` (a11y: `Band {n}, {f}`) |
| inspector | `Band {n}` · `Type` · `Frequency` · `Gain` · `Q` · `On` · `Reset band` |
| inspector.reset.help | `Reset gain to 0 dB (⌘⌫)` |
| inspector.q.help | `Higher Q = narrower. For shelves, Q sets how steep the shelf is (0.71 is standard).` |
| preamp.label | `Correction preamp` · `Tuning preamp` |
| preamp.help | `Lowers this whole layer so boosts don't clip. Imported corrections set it for you. Double-click the handle on the graph to set it automatically.` |
| banner.driver | `EQtargets needs its audio driver to process sound.` · `You can set up your EQ now — it applies once the driver is installed.` · `Install Driver…` |
| banner.error | `Something went wrong: {message}` · `Try Again` · `Copy Details` |
| toast.bound | `Now playing through {device} — loaded “{correction}”` |
| toast.imported / saved | `Imported “{name}”` · `Saved “{name}”` |
| toast.pasteFail | `The clipboard doesn't contain AutoEQ filters.` |
| toast.preamp | `Preamp set to {x} dB` |

### 11.3 Bass Style
| ID | String |
|---|---|
| bass.title | `Bass Style` |
| bass.chips | `Off` · `Punch` · `Rumble` · `Clean` (a11y: full `BassStyle.title`) |
| bass.subtitle.off | `Pick a style to add weight without touching your EQ.` |
| bass.subtitle.* | from `BassStyle.subtitle`: `Tight attack, controlled sub` · `Deep shelf, long low end` · `Gentle lift, clean headroom` |
| bass.info | `Punch tightens kicks. Rumble lets low notes ring longer. Clean is a gentle, steady lift. Every style is loudness-matched, so you compare character, not volume.` |
| bass.strength / help | `Strength` · `How much of the style you hear. Loudness stays matched, so more isn't just louder.` |
| bass.cutoff / recommended / help | `Cutoff` · `Cutoff · recommended` · `Where the bass shaping is centred. Picking a style sets the recommended value.` |
| bass.cutoff.restore | `↺ {n} Hz` (help `Back to the recommended cutoff`) |
| bass.postGain / help | `Post gain` · `Extra level after the bass stage, if the style feels quieter or louder than you like.` |
| dyn.header | `Dynamics` |
| dyn.punch | `Attack emphasis` · `Sustain control` |
| dyn.rumble | `Sustain length` · `Attack softening` |
| dyn.valueOff | `Off` |
| meter.title | `Punch activity` · `Rumble activity` |
| meter.sides | `trim` / `boost` · `soften` / `sustain` |
| meter.idle | `EQtargets is off` · `Play something to see it move` · `Driver not installed` |
| dyn.help.punch | `Attack lifts the leading edge of kicks. Sustain control trims what sits behind them — raise it for a tighter, drier low end.` |
| dyn.help.rumble | `Sustain holds a note up as it decays, so the low end rings on longer — it only acts once the note is already falling, so steady bass keeps its level. Attack softening rounds the leading edge, the deliberate opposite of Punch.` |
| bass.clean.note | `Clean is a steady, gentle lift — it has no dynamic stage.` |
| bass.footer | `Runs after both EQ layers. Never changes your bands. Not drawn on the graph.` |
| bass.compact.details | `Details…` |

### 11.4 Import
| ID | String |
|---|---|
| imp.title | `Preview headphone correction` |
| imp.subtitle | `{filename} · {n} filters` |
| imp.legend | `New` · `Current` |
| imp.name | `Name` |
| imp.preamp | `Preamp` |
| imp.preamp.differs | `File said {a} dB — we measured {b} dB from the filters, which is what keeps it from clipping.` |
| imp.table | `#` · `Type` · `Frequency` · `Gain` · `Q` · `On` |
| imp.dropped | `This file has {n} filters. EQtargets uses 10, so we kept the ones that shape the sound most. Dropped: {list}.` |
| imp.bind / caption | `Use for {device}` · `Loads automatically whenever {device} is the output.` |
| imp.keep | `Your tuning stays exactly as it is.` |
| imp.buttons | `Cancel` · `Apply Correction` |
| imp.err.empty | `This file is empty.` · `Export a ParametricEQ.txt from AutoEQ and try again.` |
| imp.err.noFilters | `No EQ filters found` · `EQtargets reads AutoEQ “ParametricEQ.txt” files — lines like “Filter 1: ON PK Fc 105 Hz Gain 6.5 dB Q 0.70”. GraphicEQ and convolution files aren't supported.` |
| imp.err.unreadable | `Couldn't open “{file}”.` · `{system reason}` |
| imp.err.tooLarge | `This file is too large to be an EQ preset.` |
| imp.err.buttons | `Close` · `Choose Another File…` · `Find Your Headphones on AutoEQ` |
| drop.valid / invalid | `Drop to preview headphone correction` · `Only AutoEQ .txt files` |

### 11.5 Onboarding, menu bar, Settings
| ID | String |
|---|---|
| ob1.title | `Better sound for everything on your Mac` |
| ob1.rows | `Headphone correction` — `Import your headphones' AutoEQ profile in one drop.` · `Your tuning` — `Shape the sound on top, without losing the correction.` · `Bass Style` — `Punch or Rumble that reacts to the music.` |
| ob1.button | `Continue` |
| ob2.title | `One small audio driver` |
| ob2.body | `EQtargets adds an audio device called “EQtargets Audio”. Your Mac sends sound to it, EQtargets shapes it, and plays it on your speakers or headphones.` |
| ob2.rows | `One password prompt` — `macOS asks once, to install the driver.` · `No microphone access` — `No orange dot. EQtargets never listens to your mic.` · `Nothing recorded` — `Sound is shaped live and never saved or sent anywhere.` · `Easy to remove` — `Uninstall anytime in Settings → Driver.` |
| ob2.note | `Sound pauses for a few seconds while macOS restarts its audio.` |
| ob2.buttons | `Not Now` · `Install Driver` |
| ob3 | `Installing…` · `Copying the driver` · `Restarting macOS audio` · `Waiting for EQtargets Audio` · `Sound may pause for a few seconds.` |
| ob4 | `You're all set` · `Listening on {device}.` · `Pick headphones in Control Center as usual — EQtargets follows them.` · `Show in menu bar` · `Open at login` · `Start EQtargets` |
| ob.cancel | `Installation cancelled` · `Nothing was changed. EQtargets needs the driver to shape your Mac's sound.` · `Not Now` · `Try Again` |
| ob.fail | `Installation didn't finish` · `{error}` · `Copy Details` · `Try Again` |
| mb.rows | `Output` · `Correction` · `Your tuning` · `Hold to Compare` · `Bass Style` |
| mb.footer | `Open EQtargets` · `Settings…` · `Quit` |
| mb.driver | `Audio driver not installed` · `Install Driver…` |
| set.tabs | `General` · `Audio` · `Corrections` · `Driver` |
| set.general | `Open EQtargets at login` · `Show in menu bar` · `Show in Dock` (`When hidden, use the menu bar icon to open EQtargets.`) · `Turn on when EQtargets opens` · `Quitting EQtargets turns it off and gives macOS its output back.` · last-one-on help: `EQtargets needs at least one way to be opened.` |
| set.audio | `Output` · `Follow macOS` · `Follow macOS uses whatever you pick in Control Center or Sound settings.` · `Safety limiter (recommended)` · `Catches overs at −1 dB so boosts never clip. Only acts when needed.` |
| set.corrections | `Name` · `Used for` · `Filters` · `Rename…` · `Import…` · `Double-click a name to rename.` |
| set.driver | `Status` · `Installed — EQtargets Audio` / `Not installed` · `Reinstall Driver…` · `Uninstall Driver…` · `Diagnostics` · `Sample rate` · `Buffer` · `Latency` · `Clock drift` · `Underruns` · `Resyncs` · `DSP load` |
| set.uninstall.alert | `Uninstall the audio driver?` · `macOS will play sound directly to {device} again. Sound pauses for a few seconds.` · `Uninstall` · `Cancel` |

Note for Core (not changed here): the built-in Fine-Tune name `Treble Smooth (-2.5 dB Highs)` uses
a hyphen-minus where the copy rules want "−". It's cosmetic, and it's a preset *name*, so changing
it affects saved selections. That's Core's call.

---

## 12. Accessibility spec

- **VoiceOver, graph.** The container is labelled "Frequency response" with value "Correction
  {name}, Your tuning {name}, Total EQ peak +4.2 dB at 62 hertz". Each **node** of the edited
  layer is its own element:
  - label "Band 3, Peak, 125 hertz"
  - value "plus 4.0 decibels, Q 1.41" (adds ", off" when disabled)
  - `.accessibilityAdjustableAction`: increment/decrement gain ±0.5 dB
  - custom actions: "Raise frequency", "Lower frequency", "Narrower", "Wider", "Reset gain",
    "Turn band off/on", "Change type to Low Shelf / High Shelf / Peak"
  - the preamp handle is adjustable in the same way.
- **Audio graph:** `.accessibilityChartDescriptor` with a log-frequency X axis (Hz), a dB Y axis, and
  three series (Correction, Your tuning, Total EQ) sampled at 31 third-octave points, so VoiceOver
  users can *hear* the curve.
- **P2:** an `.accessibilityRotor("Bands")` listing the 10 nodes.
- **Layer cards:** a radio-group feel. Label "Headphone correction, Sennheiser HD 600", trait
  `.isSelected` when editing, hint "Selects this layer for editing".
- **Power:** a real `Toggle` (label "EQtargets", value on/off). **Compare:** label "Compare with
  original", value "Off / On / Locked"; VoiceOver activation toggles the lock. When the state
  changes, post an announcement: "Comparing: original sound" / "EQ on".
- **Meters:** label "Punch activity", value "Boost 3.2 decibels" / "Trim 1.4 decibels" / "Idle",
  trait `.updatesFrequently`. **No** live announcements, which would be noise.
- **Status pill:** label "Output", value equal to the visible text with "kHz" and "ms" spelled out.
  Chips: "Warning: limiting".
- **Keyboard:** every control is reachable with Full Keyboard Access. The graph is
  `.focusable()` with the system focus ring and handles keys via `.onKeyPress` (§6.2). Tab is never
  trapped. Every shortcut has a menu item.
- **Reduce Motion:** §9.6. **Reduce Transparency:** materials and glass become solid `bg.card` /
  `windowBackgroundColor`.
- **Increase Contrast** (`colorSchemeContrast == .increased`): grid opacity +50%; curve widths
  +0.5 pt; card borders 1 pt `separatorColor` at full strength; light-mode `fine.stroke` swaps to
  `fine.ink`; the dashed non-edited curve keeps full colour.
- **Differentiate Without Color:** already met by line styles, shapes, text badges and status text.
  Additionally, status dots gain their glyph (✓ ⚠ ⛔) inside.
- Text is never smaller than 11 pt. Contrast is per §9.1. Custom targets are ≥ 28 pt.

---

## 13. App icon (macOS) and menu bar glyph

**Problems with the iOS 1024 px source** (`EQtargetsMusic/Assets.xcassets/AppIcon.appiconset/AppIcon.png`):
1. **It's an icon inside an icon.** The art is a dark bezelled plate taking about 61% of the canvas
   (≈ 625 px), sitting on a grey canvas with a purple glow. Masked to a squircle you get a double
   frame, and the content is far smaller than its neighbours in the Dock.
2. **The frequency labels contain an error.** They read `20 · 100 · 500 · 1k · 5k · 20 · 20k`, so
   "20" appears twice. They're also unreadable below 128 px.
3. The impact "crack" lines and the fine grid turn to noise at 16 and 32 px.
4. The metal bezel will fight the system edge treatment on macOS 26 and later.

**Treatment:** rebuild it as an **Icon Composer `.icon`** (layered Liquid Glass icon). Kevin runs
macOS 27, where non-conforming legacy icons are reportedly shrunk into a grey squircle. Xcode builds
the pre-26 bitmaps (for the macOS 15 deployment target) from the same `.icon` at build time.

| Layer (back → front) | Content | Notes |
|---|---|---|
| Background | full-bleed dark gradient #1A1A22 → #0E0E14 with a soft radial purple-blue bloom (≈ #5B5BD6 at 25%) top-centre | replaces both the grey canvas and the outer glow; fills the whole squircle |
| Sliders | the rainbow fader tracks (keep 7 for brand recognition), **thicker** tracks and caps, no text, no grid | keeps the brand's rainbow |
| Curve | the white curve with node dots, stroke ≈ 3× the iOS weight so it survives at 32 px | the hero; matches the in-app white "Total EQ" line |
| Dart | the dart, simplified (no crack lines, fewer facets) | foreground layer, gets the strongest glass depth; it's the "target" pun |

- **Remove:** the grey canvas, the purple outer halo, the metal bezel, all frequency labels, the crack lines.
- **Check:** Default, Dark, Clear and Tinted appearances in Icon Composer. In Tinted / Clear, the white
  curve and the dart silhouette must still read.
- **Check sizes:** 16, 32, 128, 512 and 1024. At 16 and 32 the curve and dart must dominate. If the
  rainbow becomes mush there, the fallback is 5 thicker sliders (Kevin decides).
- **Wiring:** put the `.icon` in the project (not inside an asset catalog) and set
  `ASSETCATALOG_COMPILER_APPICON_NAME` to its base name. *XcodeGen support for `.icon` is not
  verified* (see §16). If it doesn't work, the stopgap is to export PNGs from Icon Composer into a
  classic `AppIcon.appiconset` using macOS sizes, with the body drawn at the standard macOS grid
  (≈ 824 px rounded rect on the 1024 canvas). That's fine for macOS 15 but may get the grey-squircle
  treatment on 26+.

**Menu bar glyph** (template image, SF Symbol): On = `slider.vertical.3` · Off = the same glyph at 45%
opacity · needs attention (driver missing or error) = `exclamationmark.triangle.fill`. QA M-2 checks
that Off is distinguishable on light and dark menu bars. If it isn't, use a custom template drawn
from the icon's curve.

---

## 14. SwiftUI implementation notes (macOS 15, Apple frameworks only)

- **Scenes:**
  - `Window("EQtargets", id: "main")` (single window, so no ⌘N), `.defaultSize(width: 1180, height: 740)`,
    `.windowResizability(.contentMinSize)`; root view `.frame(minWidth: 900, minHeight: 620)`;
    `.windowToolbarStyle(.unified(showsTitle: false))`.
  - `MenuBarExtra(isInserted:)` with `.menuBarExtraStyle(.window)`.
  - `Settings { TabView {…} }`.
  - `Window("Welcome to EQtargets", id: "onboarding")` with `.windowResizability(.contentSize)`,
    opened via `openWindow`.
- **Width class:** `onGeometryChange(for: Bool.self) { $0.size.width < 1040 }` on the root. Bass panel:
  `.inspector(isPresented:)` plus `.inspectorColumnWidth(min: 280, ideal: 300, max: 360)`. The
  presentation flag is stored separately for each width class.
- **Toolbar:** `ToolbarItem(placement: .navigation)` Power · `.principal` StatusPill · `.primaryAction`
  Compare, Import, Bass toggle.
- **Graph:** a `Canvas` for grid and curves; nodes and the preamp handle as SwiftUI views positioned
  in a named coordinate space (this gives hover, accessibility and focus per node for free).
  - Pointer: `.pointerStyle(.grabIdle / .grabActive)` (macOS 15).
  - Drag: `DragGesture(minimumDistance: 0)`, reading `NSEvent.modifierFlags` live for ⌥ and ⇧.
  - Pinch: `MagnifyGesture`.
  - Double-click: `.simultaneousGesture(TapGesture(count: 2))`.
  - Scroll → Q: an `NSEvent.addLocalMonitorForEvents(matching: .scrollWheel)` installed only while a
    node is hovered and removed on exit. It returns the event untouched when it doesn't handle it.
  - Haptic (P2): `NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)`.
- **Throttle** `EngineController.apply` to 60 Hz during drags. Cache the non-edited layer's points and
  recompute only the edited layer plus Total.
- **Keys:** `.onKeyPress(keys:phases:)` (the B hold uses `phases: [.down, .up]`), with commands in
  `.commands { CommandMenu("EQ") {…}; CommandGroup(replacing: .newItem) {} }`.
- **Import:**
  - Drop: `.dropDestination(for: URL.self, action:isTargeted:)`, plus `String.self` for dragged text.
  - Paste: `.onPasteCommand(of: [.plainText, .fileURL])`.
  - Open: `.fileImporter(allowedContentTypes: [.plainText])`.
  - File preamp: read with a one-line regex `Preamp:\s*([+-]?\d+(?:\.\d+)?)\s*dB`, shown next to the
    derived one.
- **Undo:** `@Environment(\.undoManager)`, register on gesture end, `setActionName`.
- **Colours:** a single `Theme.swift`:
  ```swift
  extension Color {
      /// Light/dark pair resolved by AppKit at draw time, so sheets, popovers and the
      /// MenuBarExtra window pick the right one without any colorScheme plumbing.
      static func eqt(_ light: UInt32, _ dark: UInt32) -> Color {
          Color(nsColor: NSColor(name: nil) { appearance in
              let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
              let v = isDark ? dark : light
              return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                             green: CGFloat((v >> 8) & 0xFF) / 255,
                             blue: CGFloat(v & 0xFF) / 255, alpha: 1)
          })
      }
  }
  ```
- **Meter poll:** `.task(id: shouldPoll)` loop with `Task.sleep(for: .milliseconds(33))`. `shouldPoll`
  includes window visibility, read from `NSWindow.occlusionState` via
  `NSWindow.didChangeOcclusionStateNotification`.
- **Login item:** `SMAppService.mainApp`. **Dock icon:** `NSApp.setActivationPolicy(.regular / .accessory)`.
- **Performance budget (to measure, in Release):** a graph redraw at 1180 pt width with 512 points
  ≤ 2 ms on the main thread. Main-thread wakeups when idle with the window hidden = **0 per second**.
  Meter poll 30 Hz only while visible.

---

## 15. QA checklist

**Visual and contrast**
- [ ] C-1 Re-measure every §9.1 pair with Digital Color Meter + a WCAG checker, in light **and** dark, on a plain wallpaper **and** a strongly coloured one (desktop tinting). Tightest pairs: bass.ink on light canvas (4.56), danger on dark canvas (4.87), fine.stroke graphic (3.16).
- [ ] C-2 Increase Contrast and Reduce Transparency each switched on: every surface stays legible, with no translucent text backgrounds.
- [ ] C-3 Grayscale filter (Accessibility → Display → Color Filters): the layers are still distinguishable by line style and badge.
- [ ] C-4 At most 3 type sizes per screen (main window, popover, sheet, onboarding).

**Layout**
- [ ] L-1 Resize from 900×620 to full screen: no clipping, overlap or truncated values. The graph never drops under 240 pt. The compact/regular switch happens at 1040 pt with no flicker loop.
- [ ] L-2 Long names: a 40-character device name (middle-truncated, with tooltip) and a 60-character correction name.
- [ ] L-3 Opening the inspector at compact width hides the compact Bass row (never both).

**Graph and interaction**
- [ ] G-1 **Graph == DSP:** a +12 dB, Q 10 peak at 1 kHz shows its apex at +12.0 dB ±0.1 in the readout and on the plot. Repeat with the device at 44.1 kHz and 96 kHz and a 16 kHz high shelf (the curve should change shape with the rate).
- [ ] G-2 Drag: ⌥ is 10× finer, ⇧ locks the axis, double-click resets gain, there's a 0 dB snap, and the chip never covers its node (try a node at the top edge and at both side edges).
- [ ] G-3 Scroll-to-Q direction feels right with natural scrolling on **and** off; pinch-out widens the bell.
- [ ] G-4 Overlapping nodes: two bands at the same frequency and gain can both be selected (click cycles), and the band strip selects either.
- [ ] G-5 Only the edited layer's nodes respond. Clicking the other layer's curve does nothing.
- [ ] G-6 Keyboard: every §6.2 key; Tab leaves the graph; Esc deselects.
- [ ] G-7 Undo: one ⌘Z undoes a whole drag; menu names are correct; redo works.
- [ ] G-8 The scale re-scales only on mouse-up, never during a drag.

**Import**
- [ ] I-1 Real AutoEQ file (PK only), oratory1990 file (LSC/HSC), a 12-filter file (dropped list shown), an empty file, a GraphicEQ file (no-filters error), a 5 MB file (too large), a PNG drop (overlay refuses), paste of valid and of invalid text.
- [ ] I-2 Applying never changes Your tuning; "Use for {device}" binds to the UID; one undo step reverts the whole import.

**Bass and meter**
- [ ] B-1 With music playing, Punch: the meter moves right on kicks; raising "Sustain control" adds leftward movement. Rumble: the bar grows right on decaying notes. The bar never crosses its ceiling marks.
- [ ] B-2 With the style Off or Clean, the window hidden, the window occluded or the power off: confirm that **no** `meters()` polling happens (log or Instruments shows zero 30 Hz wakeups).
- [ ] B-3 Meter fall: a single kick decays visibly over about 150–300 ms and rises instantly.

**Status and routing** (needs the driver installed by Kevin)
- [ ] V-1 Volume keys on built-in speakers, AirPods and a USB DAC: the HUD moves and the level changes.
- [ ] R-1 Each `EngineStatus` shows the §6.7 row (force driverMissing by running without the driver, and force an error).
- [ ] R-2 Switching to AirPods in Control Center: the pill updates within 1 s and the bound correction loads with a toast.
- [ ] R-3 Limiting chip appears with a +12 dB boost and preamp 0; "Lower Preamp" fixes it in one undo step.

**Menus, menu bar, onboarding, accessibility**
- [ ] M-1 Every shortcut in §6.9 works and appears in its menu; no conflicts with system shortcuts.
- [ ] M-2 The menu bar glyph's On, Off and Attention states are distinguishable on light and dark menu bars.
- [ ] M-3 Hiding the Dock icon *and* the menu bar extra is impossible.
- [ ] O-1 Onboarding: install success, cancelled password, failure (simulate), Not Now → banner → Install Driver… returns to step 2.
- [ ] A-1 VoiceOver: graph nodes are adjustable, custom actions work, the audio graph plays, meters don't chatter, Compare announces.
- [ ] A-2 Full Keyboard Access reaches every control; focus rings are visible.
- [ ] A-3 Reduce Motion: no springs, slides or scales; meters still live.
- [ ] P-1 Release build: graph redraw ≤ 2 ms at default size (Instruments); 0 idle wakeups with the window hidden.
- [ ] SF-1 Every SF Symbol named here exists on macOS 15 (`airpodspro`, `airplayaudio`, `bolt.horizontal`, …), with fallbacks where they don't.

---

## 16. Open issues and asks for other owners

1. **Core / UI — graph sampling (Graph == DSP).** `FrequencyResponse.curves` uses 96 points at a
   fixed 48 kHz. The UI needs an additive internal helper that takes `sampleRate` and a grid with
   band centre frequencies merged in (§7.1). This is additive; the frozen APIs are untouched.
2. **Core — parse report.** The import preview needs "how many filters were in the file, which were
   dropped, and the file's own preamp". `AutoEQParser.parse` returns only `EQLayerState`. Suggested:
   an additive `parseReport(text:)` that shares the same regex. Duplicating the regex in the UI
   would be fragile.
3. **Engine — level-matched compare (P2).** `masterBypass` leaves samples untouched, so an honest
   level-matched A/B would need a bypass-path gain. That's a contract change, not proposed now.
   The UI shows a loudness hint instead (§6.4).
4. **Icon — XcodeGen and `.icon`.** It's unverified whether XcodeGen emits the right file reference
   for an Icon Composer `.icon`. Reports also say an asset catalog `AppIcon` can suppress the `.icon`
   on macOS. Needs a spike: add the `.icon`, run `xcodegen generate`, build, and check the bundle's
   `Assets.car` / Finder icon on macOS 27 **and** 15.
5. **Copy** — the built-in preset name hyphen (§11.5 note).
6. **eqMac claims** marked *(verify)* in §2 must be checked before any public use.
