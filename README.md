<p align="center">
  <img src="assets/icon.png" width="120" alt="NextUp 3 icon">
</p>

<h1 align="center">NextUp 3</h1>

<p align="center">
  See and skip the upcoming track right from the Lock Screen, Control Center and Dynamic Island.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/iOS-14.2%20%E2%80%93%2026-blue" alt="iOS 14.2 – 26">
  <img src="https://img.shields.io/badge/jailbreak-rootful%20%7C%20rootless%20%7C%20roothide-green" alt="rootful | rootless | roothide">
  <img src="https://img.shields.io/badge/license-GPL--3.0-orange" alt="GPL-3.0">
</p>

NextUp 3 is a modern revival of the classic
[NextUp](https://github.com/Nosskirneh/NextUp) tweak (iOS 11 – 13). It adds
an **Up Next row** to the system now-playing UI showing the next track with its
artwork, so you always know what's coming and can act on it before it plays.

## Features

- **Works everywhere** — Lock Screen, Control Center, and the Dynamic
  Island expanded player (iOS 16+).
- **Skip ahead** — remove the upcoming track from the queue with one tap, or tap
  its artwork to play it right now.
- **Bring back the previous track** — re-queue what just played as the next track.
- **Volume slider on the Lock Screen** *(opt-in, iOS 16/17)* — Apple lays its own
  volume row out in Control Center but only shows it on the Lock Screen while the
  session is on AirPlay. Switch this on and it appears for local playback too.
- **Swipe gestures** — swipe the row for an interactive carousel: ← skips the
  next track, → puts the track you just heard back into the queue as up next,
  with neighbour artwork sliding in as you drag.
- **Native look on every version** — the row adopts each iOS version's
  now-playing style (padding, corner radii, and button feedback are matched to
  Apple's own player), so it feels built-in everywhere.
- **Per-app and per-surface toggles** — a Settings pane lets you enable/disable
  each app and each surface (Lock Screen / Control Center / Dynamic Island);
  changes apply instantly, no respring. The pane lists only what your device
  has: apps that are actually installed, and the Dynamic Island row only where
  there is an island (including one enabled by a tweak such as VisibleIsland).
- **Accessible & localized** — VoiceOver, Reduce Motion, Increase Contrast and
  Dynamic Type support; 27 languages.

## Supported apps

| App | Notes |
|---|---|
| Apple Music | full support |
| Apple Podcasts | full support |
| YouTube Music | full support, built against 9.28.4 |
| Spotify | full support, built against 9.1.62 |

## Compatibility

**iOS 14.2 – 26**, on all jailbreak types (rootful, rootless, roothide).

## Screenshots

<table align="center">
  <tr>
    <td rowspan="2" align="center" valign="middle">
      <img src="assets/control-center.png" width="320" alt="Control Center player with NextUp 3"><br>
      <sub>Control Center</sub>
    </td>
    <td align="center">
      <img src="assets/lock-screen.png" width="430" alt="Lock Screen player with NextUp 3"><br>
      <sub>Lock Screen</sub>
    </td>
  </tr>
  <tr>
    <td align="center">
      <img src="assets/dynamic-island.png" width="430" alt="Dynamic Island expanded player with NextUp 3"><br>
      <sub>Dynamic Island</sub>
    </td>
  </tr>
</table>

## Install

- **[Havoc](https://havoc.app/package/nextup3)** (recommended) — search for
  *NextUp 3* in your package manager.
- Or grab the `.deb` from [Releases](https://github.com/Yves000/NextUp3/releases)
  and install it with Sileo / Filza / `dpkg -i`.

Dependencies (installed automatically): `libSandy`, `PreferenceLoader`, and
ElleKit or Substrate. The package restarts the media apps by itself; just
respring when your package manager asks. Uninstalling cleans up everything the
tweak wrote (settings and play history).

## Known issues

- The Lock Screen volume slider is **not yet verified on-device**, and it is off by
  default for that reason. See "Lock-screen volume row" below for what to expect and
  what to send back if it doesn't show up.
- Apple Podcasts is not yet verified on iOS 26 (every other app and surface is).
- Spotify and YouTube Music integrations are built against specific app versions
  (see table above); an app update can silently break them until the tweak is
  updated.

---

# For developers

NextUp 3 is a Theos tweak. One dylib is injected into six processes and behaves
differently per process:

- **Providers** (one per media app, inside `com.apple.Music`,
  `com.apple.podcasts`, `com.google.ios.youtubemusic`, `com.spotify.client`):
  read that app's live queue, serve the current "next up" (title / artist /
  artwork) over IPC, and perform skip / play-now / previous using the app's own
  in-process queue API.
- **Display side** (`com.apple.MediaRemoteUI` and `com.apple.springboard`):
  hooks the now-playing player per surface and iOS version, draws the row
  (`NUNextUpRowView`), and talks to whichever provider owns the current
  now-playing session (`NUNextUpManager`).

**IPC:** app sandboxes can't register bootstrap services, so each provider runs a
[LightMessaging](https://github.com/rpetrich/LightMessaging) (mach) server under
a [libSandy](https://github.com/opa334/libSandy) profile that grants the
mach-register/lookup extensions (`layout/Library/libSandy/com.yves.nextup3.plist`).
Darwin notifications signal "queue changed" (provider → display) and
skip / previous / jump (display → provider). Payload-free, sandbox-crossing,
instant.

## Repo structure

| Path | What it is |
|---|---|
| `hooks/*.x` | Logos hooks, split per process / surface / iOS version — each with its own `%ctor` gate. `NUHooksLockScreen{14,15,18}.x`, `NUHooksControlCenter{Legacy,18,26}.x`, `NUHooksDynamicIsland{16,17}.x`, `NUHooksNowPlaying.x` (shared player plumbing), `NUHooksSpringBoard.x` (swipe-vs-system-gesture arbitration), `NUHooksTCC.x` (iOS ≤ 16 usage-description shim), plus one `NUHooks<App>Provider.x` per app |
| `NU<App>Provider.{h,m}` | The four providers (`Music`, `Podcast`, `YouTubeMusic`, `Spotify`), all on `NUProviderBase` |
| `NUNextUpManager.{h,m}` | Display side: source tracking, per-source LightMessaging client, snapshot state |
| `NUNextUpRowView.{h,m}` | The row UI: artwork, labels, skip button, swipe carousel |
| `NUHooksShared.{h,m}` | Cross-hook helpers (process gates, view lookup, CC row layout) |
| `NUShared.h` | IPC service names, Darwin notification names, `NUApplySandbox()` |
| `NUPrefs.{h,m}` | Prefs: live state on a notify-state token, CFPreferences as persisted fallback |
| `NUVolumeControls.{h,m}` | Lock-screen volume row: runtime discovery of MediaRemoteUI's volume-availability gates, `NUVolumeStripView` (our own slider, AVSystemController-backed), and the DEBUG probe |
| `NUPrivate.h` | Private-API interface declarations (class-dump + Frida-verified) |
| `NULocalization.h` / `NULogFile.m` | String lookup; DEBUG-only file log sink |
| `prefs/` | PreferenceLoader settings pane + 27 localizations |
| `layout/` | libSandy sandbox profile |
| `vendor/` | Vendored LightMessaging / libSandy headers (see `vendor/README.md`) |

## Build & deploy

Requires [Theos](https://theos.dev) (roothide fork for the roothide variant)
and Xcode. The tweak builds against whatever recent iOS SDK your Xcode ships;
no patched SDK is needed because every private interface is declared in the
source itself (`NUPrivate.h` and the provider files). Only the Settings pane
needs one SDK from [theos/sdks](https://github.com/theos/sdks) in
`$THEOS/sdks` (any iOS 1x version works), since Xcode SDKs ship no linker stub
for the private Preferences framework. Set `NUPREFS_PRIVATE_SDK=` to pick a
specific one.

```sh
make package FINALPACKAGE=1              # roothide (default)
make package ROOTLESS=1 FINALPACKAGE=1   # rootless (palera1n / Dopamine)
make package ROOTFUL=1 FINALPACKAGE=1    # rootful — the iOS 14.2 build
make package DEBUG=1                     # dev build with NULog logging

# install the .deb from packages/ — its postinst restarts the media apps and
# MediaRemoteUI. SpringBoard hosts hooks too, so finish with a respring:
killall SpringBoard
```

## Lock-screen volume row

`MRUNowPlayingView` has a `volumeControlsView` and lays it out in Control Center on every
version we support. On the lock screen it does not, and that turned out to be
unrecoverable rather than merely gated. Forcing the availability gate — the discovered
selector is `-[MRUNowPlayingView showVolumeControlsView]`, found by walking MediaRemoteUI's
classes for volume-shaped `BOOL` getters — does make Apple create the view, but the
lock-screen layout has no slot for it: `-sizeThatFits:` never budgets for the row and the
view is laid out at exactly the transport row's `y`, so the two collide and the transport,
drawn after, swallows every touch aimed at the slider. Hand-placing it did not make it
behave either. That whole path is gone; the gate is no longer forced, so there is exactly
one slider and nothing overlapping the controls.

What ships is `NUVolumeStripView`: speaker glyph, capsule track, speaker glyph, drawn into a
band reserved exactly the way the Up Next row's is (`NUVolumeGrowthForView` →
`NUFitGrowthForView` → the `-bounds` clamp), directly above that row so the order reads like
Apple's player. One Settings switch, `showVolumeSlider`.

**Reading the volume works in MediaRemoteUI; writing it does not.** The row shows the right
level and follows the hardware buttons, and every local write path is refused — verified on
17.0, the slider tracked the finger perfectly and the output never moved. SpringBoard owns
the volume, draws the HUD, and can always write, and the tweak is already injected there, so
the row publishes a target level over a notify-state channel (`NUVolumeRequestPublish` in
NUShared.h) and `NUHooksSpringBoard` applies it. Throttled to 50ms during a drag, with the
final value always sent on release so letting go between ticks does not leave the level a
few percent short. The local write is still attempted too, since a double write of one level
is harmless and it costs nothing to let whichever side works, work.

**iOS keeps a separate level per audio category, and success is a read-back, not a return
value.** Both halves of that sentence were bugs. `-setVolumeTo:forCategory:@"Audio"` returns
YES, SpringBoard logged `applied 0.765 via setVolumeTo:forCategory:`, and the output did not
move — because media playback is not on that category. `"Audio"` is the legacy name and the
media one is `"Audio/Video"`, but rather than trust either string `NUVolumeApplyLocally` asks
`-getActiveCategoryVolume:andName:` which category is active (by definition the audible one)
and works down a list from there. And every attempt is verified by re-reading the level
afterwards, with a 1/16-step tolerance, so a selector that answers YES and does nothing no
longer terminates the chain. Reads take the same route, so the level the row displays is the
level you can hear.

Colours are **measured off Apple's own scrubber**, per appearance. Reading them at runtime
was tried first — walk `timeControlsView` for the bar-shaped views and copy their background
colours — and it picked the wrong views: it produced a fully transparent track and a 0.23
fill, matching neither Apple's numbers nor the built-in ones. With no way to read
MediaRemoteUI's log there is no way to debug that blind, so the values are pinned instead:

| | track | fill |
| --- | --- | --- |
| dark platter | white 0.16 | white 0.80 |
| light platter | black 0.13 | black 0.48 |

Those are composite alphas over the platter. Apple does not use one alpha for both
appearances — the track alphas are close, the fill alphas are nowhere near — which is why any
single number looks right in one appearance and wrong in the other. And since our fill is a
*subview* of the track it composites over it, so its own alpha is not the measured number:
for white over white, `af = (total - at) / (1 - at)`, giving 0.76 dark and 0.40 light. The
fill brightens while held; getting that backwards is what made the row look permanently
mid-drag.

Three things about the track are load-bearing, and each was a bug first:

- **It is not a `UISlider`.** Apple's now-playing sliders are a rounded capsule with no
  thumb that swells under the finger (7pt → 14pt, springing back on release); a `UISlider`
  is a thin track plus a round thumb by construction. `NUVolumeTrackView` draws the capsule
  itself.
- **It is driven by a gesture recognizer, not `UIControl` tracking.** `UIControl` tracking
  is view-level touch delivery, which an ancestor recognizer with `delaysTouchesBegan`
  withholds and then cancels if it wins — and the lock screen is full of those. Gesture
  recognizers are fed touches directly and are unaffected. This is the entire difference
  between Apple's scrubber registering a drag and this registering nothing: no begin, so no
  swell, so it read as a dead control that merely displayed the volume.
- **A drag claims the touch across the process boundary.** `NUVolumeTouchSet` raises a
  notify-state flag for the duration; `NUHooksSpringBoard` fails lock-screen paging and the
  notification-list scroll while it is up, on `touchesMoved` as well as `touchesBegan`,
  because those recognizers need movement to claim a touch and so are first reached on a
  move. Scoping that to the strip's geometry is not enough — the touch starts on the slider
  and then wanders, and the moment it leaves the band a geometry test stops protecting it,
  which is exactly when the volume would stop following the finger. The flag carries a
  timestamp rather than a bare 1, like the Dynamic Island's, so a process that dies
  mid-drag cannot leave paging broken until reboot.

Tracking is deliberately **relative**: touching down does not jump the volume to the
touch's x. Apple can afford jump-to-position on a scrubber, where a mistake costs you your
place in a song; on volume a stray tap near the right edge would blast the output. Reduce
Motion gates the swell, never the tracking.

Scope is the lock screen on iOS 16 and 17 — the versions whose lock-screen player is the
`MRUNowPlayingView` that Control Center shares. iOS 14/15 host it in-process behind
`CSMediaControlsViewController` (different height levers, see `NUHooksLockScreen14/15`) and
iOS 18 replaced it with `MRULockscreenView`, so the Settings row hides itself there rather
than offering a dead toggle. Control Center and the Dynamic Island already have Apple's
slider and are untouched.

Settings › Diagnostics has **Export Debug Log**, which collects `/var/mobile/nu/nextup3-*.log`
plus any recent crash reports and the device/OS/preference state into one text file and
opens the share sheet. Note that MediaRemoteUI — the process that draws the lock-screen
player, and so the one whose log matters most here — still writes into its own container
despite the libSandy read-write extension on that directory; its log is reachable only
through Filza.

## Building for arm64e off a Mac

The one that bites. clang signs the `class_ro` pointer of every Objective-C class on
arm64e, and the libobjc reading it back does not always authenticate that slot; when it
does not, the injected process dies the moment dyld maps the dylib — inside
`readClass()`, `EXC_BAD_ACCESS`/`SIGBUS`, ESR "Address size fault", `x0` holding one of
our classes. Nothing of ours has run at that point, so no log and no hook is implicated;
it looks like the tweak's code is at fault when the compile flags are.

`-fno-ptrauth-objc-class-ro` turns the signing off, and the Makefile used to probe for it
by running `$(TARGET_CC)` bare. That is correct only on macOS, where the compiler's
default target is already an Apple one. On a Linux Theos host the default target is the
build machine, the flag is rejected there, the probe silently yields nothing, and the
signing is emitted for the real arm64e compile regardless — a dylib that kills every
process it is injected into, built without a single warning. Verified on iPhone14,5 @
17.0: four identical reports, `x0 = OBJC_CLASS_$_NUProviderBase`, every media app.

So the probe now uses an explicit `arm64e-apple-ios` triple, an unsupported flag is a
hard `$(error)` rather than a silent omission whenever arm64e is in `ARCHS`
(`NU_ALLOW_SIGNED_CLASS_RO=1` overrides), and every safe outcome prints
`NextUp3: ptrauth-safe: …`. CI greps for that and refuses to publish a deb without it.

And the answer to the probe is now known: **the Theos Linux toolchain's clang does not
have the flag at all.** `theos/toolchain/linux/iphone/bin/clang` rejects it outright, so
Linux cannot produce a usable arm64e slice for this tweak — not with a better probe, not
with a different triple. CI therefore builds twice: on a macOS runner with Xcode's clang
for the real `arm64 arm64e` deb, and on Ubuntu with `ARCHS=arm64` as a fallback whose
worst case is a dylib that never gets loaded rather than one that kills its host.

## Adding support for another app

The design is table-driven, so a new source stays localized:

1. **`NUShared.h`** — add `kNUServiceName<X>` (+ `kNUSkipNotification<X>` /
   `kNUPrevNotification<X>` as needed), following the
   `com.yves.nextup3.<kind>.<source>` naming convention.
2. **`NUNextUpManager.m`** — add a `NUSource<X>` enum case and a case in each
   per-source table function: `NUSourceForBundleID`, `NUConnectionForSource`
   (+ a `gConn<X>`), `NUAppPrefKeyForSource`, `NUSkipNotificationForSource`,
   `NUPrevNotificationForSource`. The callers need no edits.
3. **`NUPrefs.h` + `NUPrefs.m`** — add `kNUStateApp<X>` (next free bit), its
   `NUStateBitForKey` case, and its `NUPrefsPublishState()` line. *Easy to miss
   and a silent failure*: without these the Settings switch looks right but
   never takes effect live.
4. **`prefs/Resources/Root.plist`** — one `PSSwitchCell` in the "Apps" group
   (`key` = the same `enabled<X>` string from `NUAppPrefKeyForSource`).
5. **Provider** — new `NU<X>Provider.{h,m}` on `NUProviderBase` plus
   `hooks/NUHooks<X>Provider.x` (its `%ctor` calls `NUApplySandbox()` before
   gating on `NUIs<X>()`), and add `NUIs<X>()` to `NUHooksShared.h`.
   **Don't forget the `NUIsDisplaySide()` exclusion**, or every display hook
   initializes inside the new app too.
6. **Plumbing** — `NextUp3.plist` (bundle id), `Makefile` (source files +
   `INSTALL_TARGET_PROCESSES`, which takes *executable* names, not bundle ids),
   the libSandy profile (register/lookup extensions for the new service name and
   the app's signing identifier in `AllowedProcesses`), and `control`'s
   description.

## Credits

- The original **[NextUp / NextUp 2](https://github.com/Nosskirneh/NextUp)**
  (iOS 11 – 13) by Andreas Henriksson, which this tweak revives.
- [LightMessaging](https://github.com/rpetrich/LightMessaging) by Ryan Petrich.
- [libSandy](https://github.com/opa334/libSandy) by opa334.

## License

[GPL-3.0](LICENSE). Vendored third-party headers remain under their original
terms (see `vendor/README.md`).

---

*AI agents / LLM tooling: see [AGENTS.md](AGENTS.md) (identical to
[CLAUDE.md](CLAUDE.md)) for an LLM-oriented map of this repo.*
