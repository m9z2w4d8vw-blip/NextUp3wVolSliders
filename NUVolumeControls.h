// NUVolumeControls — the lock-screen volume row.
//
// Apple's now-playing player has a volume row (MRUNowPlayingView.volumeControlsView,
// declared in NUPrivate.h) and lays it out in Control Center on every version we
// support, but on the LOCK SCREEN it only appears while the session is routed to a
// device whose volume MediaRemote can control (AirPlay). For local playback the
// player decides the hardware buttons suffice and the row is never laid out, so the
// platter has no slider at all.
//
// Two ways to get it back, and this file implements both because which one works is
// an on-device question:
//
//   NATIVE  — force MediaRemoteUI's own "this session's volume is controllable"
//             gates to YES so Apple builds, wires and lays out its own row. Nothing
//             to style and nothing to size: the row is inside Apple's own
//             -sizeThatFits:, so the existing platter-height plumbing in
//             NUHooksNowPlaying already carries it across the process boundary.
//             The gate selector is not the same on every build, so the gates are
//             DISCOVERED at runtime rather than named (NUVolumeForceNativeGates).
//
//   CUSTOM  — draw NUVolumeStripView into a strip we reserve ourselves, exactly the
//             way NUNextUpRowView is placed, and drive the system volume through
//             AVSystemController. Used when the user asks for it, and automatically
//             when the native row refuses to materialise.
//
// SCOPE: the lock screen on iOS 16 and 17 — the versions whose lock-screen player is
// the MRUNowPlayingView that Control Center shares. iOS 14/15 host that player
// in-process behind CSMediaControlsViewController (different height levers,
// see NUHooksLockScreen14/15) and iOS 18+ replaced it with MRULockscreenView, so
// neither is wired up here and the Settings rows hide themselves there.
#import <UIKit/UIKit.h>

#pragma mark - Feature gates

// Master + "showVolumeSlider" + an iOS whose lock screen we handle (16/17).
BOOL NUVolumeFeatureEnabled(void);

// "volumeSliderCustom": draw our own strip instead of unhiding Apple's.
BOOL NUVolumeCustomPreferred(void);

// Height the volume row reserves in the platter — for OUR strip and for Apple's own
// row alike, because Apple's lock-screen layout turns out not to budget for it (see
// NULayoutVolumeRow): with the gate forced it lays the view out at the transport's own
// y, so the two collide and the transport, drawn after, swallows the touches. We
// therefore reserve the band ourselves in both modes and place the row into it.
CGFloat NUVolumeStripHeight(void);

// The control's own height within that band; the remainder is the platter's bottom
// inset, which has to stay empty. Used to centre either slider in the band.
CGFloat NUVolumeControlHeight(void);

#pragma mark - Native row

// Discover and force MediaRemoteUI's volume-availability gates. Idempotent — the
// swizzle happens once per process, and each replacement re-reads the preference on
// every call, so toggling the switch in Settings takes effect without a respring.
// Call from a point where MediaRemoteUI's classes are loaded (a hooked method body),
// not from a %ctor.
void NUVolumeForceNativeGates(void);

// Apple's own volume row inside a now-playing view, or nil if this build doesn't
// vend one.
UIView *NUVolumeNativeView(UIView *nowPlayingView);

// Un-hide Apple's row. Returns YES once it is genuinely laid out (non-zero height),
// which is the signal that the native path is working on this device.
BOOL NUVolumeRevealNative(UIView *nowPlayingView);

// Apple's row stayed empty for several layout passes: give up on it for this view and
// let the custom strip take over. Returns YES the pass the decision flips, so the
// caller can re-sync the platter height once.
BOOL NUVolumeNoteNativeMiss(UIView *nowPlayingView);

// Forget a recorded miss (the native row turned up after all, e.g. AirPlay engaged).
void NUVolumeClearNativeMiss(UIView *nowPlayingView);

// State of the system-volume backend, for the layout diagnostics: can we write the
// volume at all in this process, and what does it currently read as.
BOOL NUVolumeSystemIsWritable(void);
float NUVolumeSystemLevel(void);

// One-shot dump of every volume-related gate, ivar and view state MediaRemoteUI
// exposes, so an unknown build can be read off the log instead of guessed at.
// DEBUG builds only — NULog compiles out of FINALPACKAGE.
void NUVolumeProbeOnce(UIView *nowPlayingView);

#pragma mark - Our own strip

// Speaker glyph + slider + speaker glyph, styled like the player's own controls and
// backed by the system volume. Self-refreshing: it follows the hardware buttons and
// any other volume change while it is on screen.
@interface NUVolumeStripView : UIView
+ (CGFloat)preferredHeight;
// Pull the current system volume into the slider (no-op while the user is dragging).
- (void)refreshFromSystem;
@end
