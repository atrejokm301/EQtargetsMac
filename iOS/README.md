# EQtargets for iOS

The EQtargets Mac app on iPhone and iPad: **system-wide** parametric EQ for every app's audio,
with the same Target, Fine-Tune and Bass Style layers.

It uses Apple's **Media Device Extension** (iOS 27+). EQtargets appears in Control Center as an
audio output. Pick it, and the system hands the extension the audio other apps are playing.

```
Spotify / Safari / any app
   |  pick "EQtargets" in Control Center
Extension (MediaDevice + AudioServerPlugIn)   receives the system mix
   |  loopback TCP, 127.0.0.1:47211, float32 stereo 48 kHz, with capture timestamps
App: RingReader -> ProcessingChain            the Mac app's clock sync and DSP, unchanged
   |
The output you were using (AirPods, wired, speaker)
```

The extension's sandbox forbids shared memory, App Group writes and listening sockets, so the
extension connects out to the app.

## Status

| Part | Verified how |
|---|---|
| Mac DSP on iOS | The Mac test suite, on the iOS simulator |
| Link, framing, clock sync | Logic tests over real loopback sockets and simulated bursty delivery |
| Audio driver | Contract tests through its real plug-in interface, with a fake host |
| App + extension | Signed Release build, installed on an iPhone 17 Pro Max |
| **Control Center route on a real iPhone** | Ran on an iPhone 17 Pro Max, iOS 27.3: 72 seconds over Bluetooth with no dropouts. The EQ bands and Rumble were confirmed by ear. Longer use and calls are not tested |
| **Delay on that phone (Bluetooth)** | About 216 ms: 177 ms Bluetooth, 38 ms EQtargets. iOS delivers audio in 1,024-frame blocks (21 ms), with timing spikes up to 9 ms, so the buffer has only about 1.5 ms to spare |
| **Control Center tiles** | EQ on/off and Bass Style. Covered by logic tests and installed, but not yet tapped on a real phone |
| **CPU on that phone** | While playing over Bluetooth: about 21% of one core in total (3.1% app, 0.5% extension, 17% iOS audio server), against 6% playing without EQtargets. Measured before the final `-O3` and LTO flags |
| **Local link security** | The app and extension prove themselves to each other with HMAC-SHA256, using a per-install key in a Keychain group only they can read. Each proof is tied to its own TCP connection, so another app can't relay it. Fake apps, replay, relay and floods are covered by logic tests. No hostile app has been run on a real phone. Another app can still deny service by holding or flooding port 47211, but it can't hear the audio or feed its own in |

## Requirements

- Xcode 27, `xcodegen` (`brew install xcodegen`), a device on iOS 27 or later.
- **A paid Apple Developer Program membership** to install the real app. The Media Sharing
  Extension capability is not available to free Personal Teams (`validTeamTypes` in Xcode's
  `DVTPortalCachedPortalCapabilities.json`).
- The simulator cannot run the extension: `MediaDevice.framework` is not in its SDK.

## Build

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd iOS && xcodegen generate

# Logic tests
xcodebuild -project EQtargetsIOS.xcodeproj -scheme EQtargetsLogicTests \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' test

# The app without the extension, on the simulator. Launch with --demo to run
# a synthetic signal through the real link, reader and DSP.
xcodebuild -project EQtargetsIOS.xcodeproj -scheme EQtargetsPreview \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' build

# The real app + extension for a device, unsigned (compile check)
xcodebuild -project EQtargetsIOS.xcodeproj -scheme EQtargets -configuration Release \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

## First install on a device (after joining the Developer Program)

1. Build once with `-allowProvisioningUpdates`. Xcode registers the App IDs
   `com.eqtargets.ios` and `com.eqtargets.ios.extension` with the capability on.
2. In the [developer portal](https://developer.apple.com/account/resources/identifiers/list),
   under Identifiers, create a **Media Device Sharing Extension** identifier:
   `media-device-protocol.com.eqtargets.ios`.
3. Select that identifier on the **extension App ID only**. The app's list stays empty, because
   any value there breaks its audio session. If a profile with an empty list is already cached,
   move it aside so Xcode fetches a fresh one.
4. Build the `EQtargets` scheme in **Release** with your team:
   `DEVELOPMENT_TEAM=<team id>`, from Terminal in the Mac's own login session. Over SSH, the
   extension fails to sign with `errSecInternalComponent`. Release uses `-O3`, full LTO for C
   and Swift, cross-module and whole-module Swift, dead-code stripping and stripped binaries.

### Names

| Where | Name | Set in |
|---|---|---|
| App Store | EQtargets AutoEQ | App Store Connect, when the listing is created |
| Home screen | EQtargets | `CFBundleDisplayName` in the app's `Info.plist` |
| Control Center | EQtargets, with "EQtargets Audio" as the second line | `EQT_ROUTE_NAME`, `UTTypeDescription` |

### These freeze at the first install

Changing them later breaks the output until a reboot, or removes it from the picker:

| Value | Where |
|---|---|
| Protocol ID `media-device-protocol.com.eqtargets.ios` | `EQTIdentity.h`, extension entitlement, extension `Info.plist` |
| Type description `EQtargets Audio` | extension `Info.plist` |
| Device UUID `45515447-5453-494F-A000-000000000001` | `EQTIdentity.h` |

**Reinstall over the top.** Deleting the app and installing again leaves a dead audio port, and
the next pick says "Unable to Connect" until the phone restarts.

### Still to check on a phone

- Both tiles with the app open, in the background, and after a force-quit. iOS may refuse to start
  the audio in the background, and then the On tile opens the app.
- After a restart, unlock, tap a tile, and confirm the saved EQ and presets are still there.
- With the app Off, pick EQtargets while Control Center stays open.
- Picking it while the app is off and in the background: the sound should come back within a few
  seconds, when iOS drops the connection.
- A phone call, and iOS suspending the app in the background.
- Video delay, and picking the output while video is on screen.
- Picking EQtargets again while it is already selected.
- Two fingers on the graph, and scrolling the page across a slider.
- From the logs: any StartIO arriving during a StopIO's wait, and any audio landing after the last
  StopIO. These settle timing cases the tests cannot reach.
- Lip sync. The driver reports zero latency, so video apps cannot compensate for the delay yet.
- Battery drain over a long listening session.
- Switching headphones with EQtargets selected (AirPods to AirPods, Bluetooth to wired, headphones
  to the speaker). EQtargets must still be selected afterwards, with the new pair's Correction
  loaded. If it drops out, read the journal below.

### The route journal

The app keeps its last 400 route and engine events on the phone, so a drop-out can be explained
without reading the phone's system log, which needs root on the Mac. Read it over the cable or
Wi-Fi:

```bash
xcrun devicectl device copy from --device "$PHONE" --domain-type appDataContainer \
  --domain-identifier com.eqtargets.ios --source Library/Caches/link-journal.txt \
  --destination link-journal.txt
```

If "peer left" follows a route change while the app kept ticking, iOS most likely moved the
output itself, and only Control Center can pick EQtargets again. A "no tick for N s" line means
the app was suspended or its main thread was blocked. It is written when the app runs again,
after the gap; "since" gives when the gap began. If that gap covers more than the extension's
5 s, the extension most likely gave the route back. Repeated lines are collapsed ("again, N in
a row"), and a burst past 60 lines is counted as skipped.

## Known limits (all from iOS)

- Control Center tiles can only be a toggle or a button, so there is no hold menu. They can't pick
  EQtargets as the output, and a locked iPhone has to be unlocked before they run.
- EQtargets must stay open or in the app switcher. Swiping it away stops the EQ.
- No app can pick an output from code. If iOS moves the output to headphones that just connected,
  EQtargets has to be picked again in Control Center. What the app does control: for 8 seconds
  after a headphone change, and while its audio is down, it asks iOS for background time so it is
  not suspended mid-switch, which would make the extension give the route back. iOS grants about
  30 seconds and can refuse.
- Off really stops the audio so iOS can suspend the app. If you pick EQtargets while it is off and
  in the background, the sound cuts out for a few seconds until iOS drops the connection.
- iOS may ask for microphone permission because of the audio mode required to avoid a feedback
  loop. The app has no code that reads the microphone.
- There is no in-app output button on purpose. `AVRoutePickerView` pulls this app's own audio onto
  the EQtargets route and causes a feedback loop, so the output is chosen in Control Center.
- Picking the output while video is on screen can fail, including YouTube and Spotify Canvas.
  Pick it while no video is showing.
- The link runs at 48 kHz, so other rates are resampled.
- Turning the EQ off while EQtargets is the selected output only bypasses it. An app cannot change
  the system route, so choose another output in Control Center to disconnect.

## Credits

The extension and driver are adapted from
[ios27-media-device-passthrough](https://github.com/satomasahiro2005/ios27-media-device-passthrough)
(MIT No Attribution). Its device measurements, and those published with
[EffectDeck](https://github.com/satomasahiro2005/EffectDeck), shaped the session and lifecycle rules.
