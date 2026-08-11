// NUVolumeControls — the lock-screen volume row.
//
// Apple's now-playing player has a volume row of its own
// (MRUNowPlayingView.volumeControlsView, declared in NUPrivate.h) and lays it out in
// Control Center on every version we support. On the LOCK SCREEN it does not: the
// layout has no slot for that row, so even with the availability gate forced YES the
// view is created but never given a height, and placing it by hand lands it on top of
// the transport row. That path was tried at length and abandoned — see the README.
//
// So this draws the row itself: NUVolumeStripView, a speaker glyph, a capsule track and
// a speaker glyph, placed into a band the tweak reserves in the platter exactly the way
// it reserves one for the Up Next row (NUVolumeGrowthForView → NUFitGrowthForView → the
// -bounds clamp in NUHooksNowPlaying), directly above that row so the order reads like
// Apple's own player: transport, volume, Up Next.
//
// Two details that are not obvious and were each a bug:
//
//   * The track is a UIControl driven by a GESTURE RECOGNIZER, not by UIControl's own
//     touch tracking. UIControl tracking is view-level touch delivery, which an ancestor
//     recognizer with delaysTouchesBegan withholds and then cancels if it wins — and the
//     lock screen is full of those. Gesture recognizers are fed touches directly and are
//     unaffected. This is the difference between Apple's scrubber working and this not.
//
//   * While a drag is in progress the row raises a cross-process flag
//     (NUVolumeTouchSet in NUShared.h) that SpringBoard reads to fail its own paging and
//     scroll gestures, so a finger that strays off the platter keeps controlling the
//     volume instead of handing the touch to the notification list. Same mechanism the
//     Dynamic Island swipe already uses.
//
// SCOPE: the lock screen on iOS 16 and 17 — the versions whose lock-screen player is the
// MRUNowPlayingView that Control Center shares. iOS 14/15 host that player in-process
// behind CSMediaControlsViewController (different height levers, see
// NUHooksLockScreen14/15) and iOS 18+ replaced it with MRULockscreenView, so neither is
// wired up here and the Settings row hides itself there.
#import <UIKit/UIKit.h>

#pragma mark - Feature gate

// Master + "showVolumeSlider" + an iOS whose lock screen we handle (16/17).
BOOL NUVolumeFeatureEnabled(void);

#pragma mark - Geometry

// Height the volume row reserves in the platter.
CGFloat NUVolumeStripHeight(void);

// The control's own height within that band; the remainder is the platter's bottom
// inset, which has to stay empty.
CGFloat NUVolumeControlHeight(void);

// The platter's horizontal content inset.
CGFloat NUVolumeHorizontalInset(void);

#pragma mark - Writing the volume

// Apply a level in THIS process, walking the write paths in order. Returns the name of the
// one that took it, or nil if none did. SpringBoard calls this on the far side of
// NUVolumeRequestPublish; the row calls it too, in case the local write does work.
NSString *NUVolumeApplyLocally(float volume);

// Best-effort suppression of SpringBoard's volume HUD, which otherwise pops up over the
// player on every drag. An MPVolumeView in a window is the long-standing way to tell the
// system a slider is already on screen. Safe to call repeatedly.
void NUVolumeInstallHUDSuppressor(UIView *host);

#pragma mark - Backend state (for the layout diagnostics)

// Can the system volume be written at all in this process, and what does it read as.
BOOL NUVolumeSystemIsWritable(void);
float NUVolumeSystemLevel(void);

// Copy the scrubber's own track and fill colours, so the volume row matches the row that
// shows the song time instead of approximating it. Returns NO if this build's scrubber
// doesn't expose them, in which case the row keeps its built-in colours.
BOOL NUVolumeCopyScrubberColors(UIView *nowPlayingView,
                                UIColor **outTrack, UIColor **outFill);

#pragma mark - The row

@interface NUVolumeStripView : UIView
+ (CGFloat)preferredHeight;
// Pull the current system volume into the track (no-op while the user is dragging).
- (void)refreshFromSystem;
@end
