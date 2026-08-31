# Audify

Per-app and per-tab volume control for macOS, from the menu bar.

macOS gives you one volume slider for the whole machine. Audify gives you one per app — and one
per browser tab — so you can drop Chrome to 30% during a call, mute a noisy Electron app, or boost
a quiet video past 100%, without touching anything else.

Built for macOS 26, supports macOS 15 and later. Native Swift, universal binary, no Electron, no
kernel extension, no virtual audio driver to install.

---

## What it does

- **Per-app volume and mute** for every app that plays audio, remembered by app across relaunches.
  Only apps that are actually playing (or that you've adjusted) are shown — background system
  services never clutter the list.
- **Per-tab volume and mute** in Chrome, Edge, Brave, Vivaldi and other Chromium browsers, with
  each site's level remembered for next time.
- **Master output** volume, mute and output-device switching, without opening System Settings.
- **Microphone mute**, from the menu bar or a global keyboard shortcut (**⌥⌘M** by default), with
  an on-screen confirmation and a menu bar badge so you always know if your mic is live.
- **Volume boost to 200%**, off by default. Every app and tab is hard-capped at 100% until you
  explicitly opt in under Settings ▸ General — the safe default for your speakers and your hearing.
- **Live level meters** per app, so you can see what is making noise.
- **Menu bar only** — no Dock icon, no window, no background daemon.
- **Start at login**, asked for once rather than assumed.

## The thing that matters most: it costs nothing when idle

An app sitting at 100% volume is not touched by Audify at all. No capture, no extra buffer, no
added latency, no CPU. The audio graph is built the moment you move a slider away from 100% and is
torn down completely when the last adjusted app returns to unity.

At rest Audify is a menu bar icon and a handful of event listeners:

| State | CPU |
|---|---|
| Nothing adjusted (typical) | 0.0% — no audio graph exists |
| Menu closed, several apps adjusted | one render callback, mixing with Accelerate |
| Menu open | + 15 Hz meter refresh |

There is no polling anywhere. Process appearance, playback start/stop, device changes and sample
rate changes all arrive as Core Audio property notifications. The only timer in the app drives the
level meters, and it exists only while the popover is on screen.

## How it works

macOS has no per-app volume API. Audify uses **Core Audio process taps** (macOS 14.2+), which is
the same mechanism Apple's own audio capture APIs use — no driver to install, nothing to uninstall
later.

```
 Safari  ──▶ tap ─┐
 Music   ──▶ tap ─┼─▶ private aggregate device ──▶ gain + mix ──▶ real output device
 Zoom    ──▶ tap ─┘
 everything else ──────────────────────────────────────────────▶ real output device
```

Design decisions worth knowing about:

- **One aggregate device, one render callback, N taps.** Adjusting ten apps costs one audio
  callback, not ten. Mixing uses `vDSP_vsma`, so the steady-state path is SIMD.
- **Taps are `.mutedWhenTapped`.** If Audify crashes or is force-quit, tapped apps immediately go
  back to playing through the hardware at full volume. Failing open is worth more than a tidier graph.
- **The aggregate device is private.** It never appears in Sound Settings or in any other app's
  device list.
- **The master slider drives the hardware device**, not our own graph, so it behaves exactly like
  the volume keys and affects apps Audify is not touching.
- **The render thread never blocks.** Gain changes are lock-free single-word stores. Structural
  changes take a lock the audio thread only ever *tries* — if it can't get it, that one buffer is
  silence rather than a stall or a priority inversion.
- **Levels are keyed by bundle identifier**, and on macOS 26 taps additionally use
  `processRestoreEnabled`, so the OS itself re-attaches a tap when an app relaunches.
- **Browser helper processes are collapsed onto their host app**, so Chrome is one row rather than
  fourteen `Chrome Helper` rows.
- **System daemons never reach the mixer.** macOS reports *every* process that has ever touched
  Core Audio — UI sound servers, accessibility daemons, Siri's audio pipeline — not just apps.
  These are filtered out before a listener is even attached to them, and idle apps (playing
  nothing, at 100%, unadjusted) are hidden by default too. What's left is only what's worth a slider.
- **Volume boost defaults to off.** `preferences.volume(forApp:)` clamps to 100% unless boost is
  explicitly enabled in Settings, so there is no accidental path to sending an app louder than its
  source ever intended.
- **The microphone shortcut uses Carbon's `RegisterEventHotKey`**, the same global-hotkey mechanism
  Spotlight and the screenshot tool use — not a raw keystroke monitor. That means it needs no
  Accessibility or Input Monitoring permission, and it does nothing at all except in the instant
  the exact combination is pressed.

## Microphone mute

A menu bar button and a global keyboard shortcut (**⌥⌘M** by default — the same combination the
popular "Mute" utility uses) mute the system default microphone from anywhere, in any app. Toggling
shows a brief on-screen confirmation and badges the menu bar icon so the mic's state is always
visible without opening the mixer. Both the shortcut and its combination can be turned off or
changed under Settings ▸ General.

Muting is a hardware-level control (the same one Control Center uses) — it needs no audio
permission and involves no Core Audio tap, so it works even before you've granted Audify system
audio access.

## Install

Requires Xcode command line tools. From the repository root:

```sh
make install
```

That builds a universal release binary, generates the icon, assembles `Audify.app`, signs it, and
copies it into `/Applications`. Look for the fader icon in the menu bar.

Other targets:

```sh
make bundle      # build ./dist/Audify.app without installing
make run         # build and run from ./dist
make diagnose    # print the audio graph Audify sees (see caveat below)
make test        # unit tests
make dmg         # distributable disk image
make uninstall   # remove the app and its settings
make clean
```

### Signing

`make install` signs ad-hoc, which is fine for your own machine. Two consequences: macOS treats
each rebuild as a new app, so audio permission may need re-granting, and *Start at Login* may need
approving in System Settings. For a build you intend to share:

```sh
make dmg SIGN_ID="Developer ID Application: Your Name (TEAMID)"
xcrun notarytool submit dist/Audify.dmg --keychain-profile "AC" --wait
xcrun stapler staple dist/Audify.app
```

## Permissions

Audify needs **system audio access** (System Settings ▸ Privacy & Security ▸ Audio Recording) to
change an app's level. Audio is re-mixed in memory and nothing is ever written to disk or sent
anywhere — there is no network code in the audio path at all.

Two things about this permission are worth knowing, because they are unusual:

1. **Denial is silent.** When audio capture is not permitted, macOS still creates the tap, still
   runs the render callback, and simply delivers buffers of zeros. No error is returned. Audify
   therefore detects the real state behaviourally: if apps it is tapping are playing and not one
   non-zero sample has arrived, it reports the permission as blocked and offers to open Settings.
2. **`make diagnose` can report a false failure.** macOS attributes a privacy request to the
   *responsible* process, so a run started from a terminal is judged as your terminal, not as
   Audify. If diagnostics report blocked capture but the app itself works, that is why. To run
   diagnostics under Audify's own identity:

   ```sh
   open -n -a /Applications/Audify.app --args --diagnose /tmp/audify.txt && cat /tmp/audify.txt
   ```

## Browser tabs

Per-tab audio is not visible to any native app, so tab control needs a browser extension. It talks
to Audify over a WebSocket bound to `127.0.0.1` and gated by a pairing code — nothing off-machine
can reach it.

1. Open **Chrome ▸ Extensions**, turn on **Developer mode**, choose **Load unpacked**.
2. Select `/Applications/Audify.app/Contents/Resources/Extension`
   (or use *Reveal Extension Folder* in Audify ▸ Settings ▸ Browser).
3. Click the extension's icon, paste the pairing code from **Audify ▸ Settings ▸ Browser**, and
   press **Connect**.

Audible tabs then appear under **Browser Tabs** in the Audify menu. See
[`Extension/README.md`](Extension/README.md) for details and troubleshooting.

## Limitations

Stated plainly, because they are inherent rather than unfinished:

- **Tab volume applies to media elements.** The extension controls `<video>` and `<audio>`, which
  covers YouTube, Netflix, Spotify Web, Meet, Zoom Web and effectively all streaming. A page that
  synthesises audio purely through the Web Audio API is not affected; muting that tab still works,
  and so does turning the whole browser down.
- **Boost above 100% in a tab** routes audio through a Web Audio gain node. For media served
  without permissive CORS headers this is not possible, and Audify keeps that element at 100%
  rather than risking silence.
- **Firefox is not supported yet.** The extension is Chromium MV3; Firefox needs its own manifest.
- **Adjusted apps gain one buffer of latency** (about 11 ms by default, configurable in Settings ▸
  Advanced). Apps left at 100% have no added latency whatsoever.
- **Some output devices have no software volume** — several HDMI and professional interfaces. The
  master slider is disabled for those; per-app control still works normally.
- **Audio capture permission is required.** Without it, per-app volume cannot work at all; this is
  the only mechanism macOS offers.

## Layout

```
Sources/AudifyKit/         Audio engine and state, no UI
  CoreAudioProperty.swift    Property helpers and self-removing listeners
  AudioProcessRegistry.swift Which apps are playing, listener-driven
  TapMixerEngine.swift       Taps, the aggregate device, lifecycle
  MixerRenderContext.swift   The real-time render callback
  OutputDeviceController.swift  Master volume, mute, device switching
  BridgeServer.swift         Loopback WebSocket server for the extension
  AudifyController.swift     Orchestration; the object the UI observes
Sources/Audify/            Menu bar app
Extension/                 Chromium MV3 extension
Tools/makeicon.swift       Draws the app icon at build time
```

`AudifyKit` has no dependency on the UI, which is what makes `make diagnose` and the tests possible
without launching an app.
