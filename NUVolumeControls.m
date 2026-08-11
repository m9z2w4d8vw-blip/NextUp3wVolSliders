#import "NUVolumeControls.h"
#import "NUPrefs.h"
#import "NUPrivate.h"
#import "NUShared.h"
#import "NULocalization.h"
#import <objc/message.h>
#import <stdlib.h>

#pragma mark - Feature gates

static const CGFloat kNUVolumeStripHeight = 36.0;   // 22pt control + 14pt bottom inset
static const CGFloat kNUVolumeHInset      = 14.0;   // iOS 16/17 lock-screen content inset
static const CGFloat kNUVolumeGap         = 10.0;   // glyph → slider
static const CGFloat kNUVolumeControlH    = 22.0;   // the slider's own band
static const CGFloat kNUVolumeGlyphPoint  = 13.0;

static NSInteger NUVolumeIOSMajor(void) {
    static NSInteger v = 0; static dispatch_once_t once;
    dispatch_once(&once, ^{ v = NSProcessInfo.processInfo.operatingSystemVersion.majorVersion; });
    return v;
}

// iOS 16/17 only — see the scope note in NUVolumeControls.h.
static BOOL NUVolumeOSSupported(void) {
    NSInteger v = NUVolumeIOSMajor();
    return v >= 16 && v <= 17;
}

BOOL NUVolumeFeatureEnabled(void) {
    return NUVolumeOSSupported() && NUMasterEnabled() && NUPrefBool(@"showVolumeSlider", NO);
}

CGFloat NUVolumeStripHeight(void) { return kNUVolumeStripHeight; }
CGFloat NUVolumeControlHeight(void) { return kNUVolumeControlH; }
CGFloat NUVolumeHorizontalInset(void) { return kNUVolumeHInset; }

#pragma mark - System volume (AVSystemController)

// Resolved at runtime so nothing private gets linked. Declared under our own name
// rather than AVSystemController's so the class symbol is never referenced — a
// hard reference would make dyld fail the whole tweak on a build that renamed it.
@interface NUAVSystemController : NSObject
+ (id)sharedAVSystemController;
- (BOOL)getVolume:(float *)outVolume forCategory:(NSString *)category;
- (BOOL)getActiveCategoryVolume:(float *)outVolume andName:(NSString **)outName;
- (BOOL)setVolumeTo:(float)volume forCategory:(NSString *)category;
- (BOOL)setActiveCategoryVolumeTo:(float)volume;
- (BOOL)setAttribute:(id)attribute forKey:(NSString *)key;
@end

// MPVolumeSlider, the control inside MPVolumeView. Last-resort write path: it is the
// system's own volume control, so if AVSystemController will not take a write this one
// still will. Declared locally for the same reason as everything else here.
@interface NUMPVolumeSlider : UIView
@property (nonatomic) float value;
- (void)_commitVolumeChange;
@end

// MPVolumeView's one property we touch. Declared locally for the same reason as
// NUAVSystemController above — importing MediaPlayer just for this would link the
// framework, and an `id` receiver can't type-check a selector nothing declares.
@interface NUMPVolumeView : UIView
@property (nonatomic) BOOL showsRouteButton;
@end

// The offscreen MPVolumeView the strip installs to suppress the volume HUD; reused as
// that last-resort write path. Weak — the strip owns it.
static __weak UIView *gNUHUDSuppressor = nil;

// iOS keeps a SEPARATE level per audio category, and this was the bug behind a slider that
// looked like it worked and changed nothing: -setVolumeTo:forCategory:@"Audio" happily
// returns YES, SpringBoard logged the write as successful, and the output never moved,
// because media playback is not on that category. "Audio" is the legacy name; the media one
// on modern iOS is "Audio/Video". Rather than trust either string, ask which category is
// active — by definition it is the one you can hear — and fall back only if it won't say.
static NSString * const kNUVolumeCategory = @"Audio/Video";
static NSString * const kNUVolumeLegacyCategory = @"Audio";

// How close a read-back has to be to count as applied. The system quantises to 1/16 steps,
// so a write of 0.765 legitimately reads back as 0.75.
static const float kNUVolumeAppliedTolerance = 0.09f;
static NSString * const kNUVolumeChangedNotification =
    @"AVSystemController_SystemVolumeDidChangeNotification";

// Typed rather than `id` so the compiler resolves these selectors against OUR
// declaration only — several frameworks in these processes declare a
// -getVolume:forCategory: or -setAttribute:forKey: of their own, and an `id`
// receiver picks one of them at random to type-check against. A cast to a
// never-implemented class emits no class reference, so nothing is linked either.
static NUAVSystemController *NUVolumeSystemController(void) {
    static NUAVSystemController *controller; static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = NSClassFromString(@"AVSystemController");
        if (![cls respondsToSelector:@selector(sharedAVSystemController)]) {
            NULog("volume: AVSystemController unavailable — our slider would be read-only");
            return;
        }
        controller = (NUAVSystemController *)((id (*)(id, SEL))objc_msgSend)(
            cls, @selector(sharedAVSystemController));
        // The volume-change notification is opt-in: without this subscription the
        // hardware buttons move the volume and our slider never hears about it.
        if ([controller respondsToSelector:@selector(setAttribute:forKey:)])
            [controller setAttribute:@[ kNUVolumeChangedNotification ]
                              forKey:@"AVSystemController_SubscribeToNotificationsAttribute"];
    });
    return controller;
}

// The category the audible output is on right now, or nil if the controller won't say.
static NSString *NUVolumeActiveCategory(void) {
    NUAVSystemController *sc = NUVolumeSystemController();
    if (![sc respondsToSelector:@selector(getActiveCategoryVolume:andName:)]) return nil;
    float v = 0.0f;
    NSString *name = nil;
    if (![sc getActiveCategoryVolume:&v andName:&name]) return nil;
    return name.length ? name : nil;
}

// The audible level. Asks for the ACTIVE category's level first, so what the row displays is
// what you can hear rather than whatever a hardcoded category happens to hold.
static float NUVolumeSystemGet(void) {
    NUAVSystemController *sc = NUVolumeSystemController();
    float v = 0.0f;
    if ([sc respondsToSelector:@selector(getActiveCategoryVolume:andName:)]) {
        NSString *name = nil;
        if ([sc getActiveCategoryVolume:&v andName:&name]) return MAX(0.0f, MIN(1.0f, v));
    }
    if (![sc respondsToSelector:@selector(getVolume:forCategory:)]) return 0.0f;
    for (NSString *category in @[ kNUVolumeCategory, kNUVolumeLegacyCategory ]) {
        if ([sc getVolume:&v forCategory:category]) return MAX(0.0f, MIN(1.0f, v));
    }
    return 0.0f;
}

// Walk the offscreen MPVolumeView for its MPVolumeSlider and drive that.
static BOOL NUVolumeSetViaMPVolumeSlider(float volume) {
    UIView *root = gNUHUDSuppressor;
    if (!root) return NO;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    while (queue.count) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([NSStringFromClass(v.class) containsString:@"MPVolumeSlider"]) {
            NUMPVolumeSlider *slider = (NUMPVolumeSlider *)v;
            slider.value = volume;
            if ([slider respondsToSelector:@selector(_commitVolumeChange)])
                [slider _commitVolumeChange];
            else if ([slider isKindOfClass:UIControl.class])
                [(UIControl *)slider sendActionsForControlEvents:UIControlEventValueChanged];
            return YES;
        }
        [queue addObjectsFromArray:v.subviews];
    }
    return NO;
}

// Which of the write paths actually took the value. Logged once so a device where none of
// them work says so plainly instead of presenting a slider that silently does nothing.
// Success is a read-back, not a return value. Every one of these can answer YES and change
// nothing audible — which is exactly what happened — so each attempt is checked against the
// level afterwards and the chain continues until the output has actually moved.
static BOOL NUVolumeApplied(float target) {
    return fabsf(NUVolumeSystemGet() - target) <= kNUVolumeAppliedTolerance;
}

NSString *NUVolumeApplyLocally(float volume) {
    float v = MAX(0.0f, MIN(1.0f, volume));
    NUAVSystemController *sc = NUVolumeSystemController();

    // Active category first: it is the one you can hear, by definition.
    if ([sc respondsToSelector:@selector(setActiveCategoryVolumeTo:)]) {
        [sc setActiveCategoryVolumeTo:v];
        if (NUVolumeApplied(v)) return @"setActiveCategoryVolumeTo:";
    }
    if ([sc respondsToSelector:@selector(setVolumeTo:forCategory:)]) {
        NSString *active = NUVolumeActiveCategory();
        NSMutableArray<NSString *> *categories = [NSMutableArray array];
        if (active) [categories addObject:active];
        [categories addObject:kNUVolumeCategory];
        [categories addObject:kNUVolumeLegacyCategory];
        for (NSString *category in categories) {
            [sc setVolumeTo:v forCategory:category];
            if (NUVolumeApplied(v))
                return [@"setVolumeTo:forCategory: " stringByAppendingString:category];
        }
    }
    if (NUVolumeSetViaMPVolumeSlider(v) && NUVolumeApplied(v)) return @"MPVolumeSlider";
    return nil;
}

// Informational only. The control is NEVER disabled on the strength of this: a missing
// -setVolumeTo:forCategory: used to set enabled=NO, which made the slider inert — no
// tracking, so no swell either — and indistinguishable from a touch that never arrived.
// Both failures looked the same from the outside, which cost a diagnostic round trip.
BOOL NUVolumeSystemIsWritable(void) {
    NUAVSystemController *sc = NUVolumeSystemController();
    return [sc respondsToSelector:@selector(setVolumeTo:forCategory:)]
        || [sc respondsToSelector:@selector(setActiveCategoryVolumeTo:)]
        || gNUHUDSuppressor != nil;
}

float NUVolumeSystemLevel(void) { return NUVolumeSystemGet(); }

// A single offscreen MPVolumeView per host, kept alive by the hierarchy. Resolved by name
// so MediaPlayer is never linked.
void NUVolumeInstallHUDSuppressor(UIView *host) {
    if (!host) return;
    Class MPV = NSClassFromString(@"MPVolumeView");
    if (!MPV) return;
    for (UIView *sub in host.subviews)
        if ([sub isKindOfClass:MPV]) { gNUHUDSuppressor = sub; return; }   // already installed
    NUMPVolumeView *suppressor =
        (NUMPVolumeView *)[[MPV alloc] initWithFrame:CGRectMake(-4000, -4000, 1, 1)];
    if ([suppressor respondsToSelector:@selector(setShowsRouteButton:)])
        suppressor.showsRouteButton = NO;
    suppressor.alpha = 0.001;   // must be in the hierarchy; must not be `hidden`
    suppressor.userInteractionEnabled = NO;
    [host addSubview:suppressor];
    gNUHUDSuppressor = suppressor;
}

#pragma mark - Matching the scrubber

// The scrubber is a track view with a fill view inside it, both plain background colours on
// every build checked. Rather than approximating them, read them: "the same colour as the
// slider that shows the song time" is then true by construction, in either appearance, and
// stays true if Apple restyles it.
//
// Identified by shape, not class name: within timeControlsView, the widest short-and-wide
// view with a real background colour is the track, and the widest such view INSIDE that is
// the fill. Anything unexpected simply fails the checks and the row keeps its own colours.
BOOL NUVolumeCopyScrubberColors(UIView *nowPlayingView, UIColor **outTrack, UIColor **outFill) {
    if (![nowPlayingView respondsToSelector:@selector(timeControlsView)]) return NO;
    UIView *time = [(MRUNowPlayingView *)nowPlayingView timeControlsView];
    if (!time) return NO;

    UIView *track = nil;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithArray:time.subviews];
    while (queue.count) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        [queue addObjectsFromArray:v.subviews];
        CGSize sz = v.bounds.size;
        BOOL barShaped = sz.width > 80.0 && sz.height > 1.0 && sz.height < 24.0;
        if (!barShaped || !v.backgroundColor) continue;
        if (CGColorGetAlpha(v.backgroundColor.CGColor) < 0.01) continue;
        if (!track || sz.width > track.bounds.size.width) track = v;
    }
    if (!track) return NO;

    UIView *fill = nil;
    for (UIView *v in track.subviews) {
        if (!v.backgroundColor || CGColorGetAlpha(v.backgroundColor.CGColor) < 0.01) continue;
        if (v.bounds.size.height < 1.0) continue;
        if (!fill || v.bounds.size.width > fill.bounds.size.width) fill = v;
    }
    if (!fill) return NO;

    if (outTrack) *outTrack = track.backgroundColor;
    if (outFill) *outFill = fill.backgroundColor;
    return YES;
}

#pragma mark - Our own strip

// Same adaptive foreground as NUNextUpRowView: the lock-screen player follows
// light/dark on every supported version, and Increase Contrast lifts translucent
// foregrounds toward opaque.
static UIColor *NUVolumeColor(CGFloat alpha) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        CGFloat w = (tc.userInterfaceStyle == UIUserInterfaceStyleDark) ? 1.0 : 0.0;
        CGFloat a = alpha;
        if (tc.accessibilityContrast == UIAccessibilityContrastHigh && a >= 0.4)
            a = a + (1.0 - a) * 0.5;
        return [UIColor colorWithWhite:w alpha:a];
    }];
}

#pragma mark The track

// Apple's now-playing sliders — the scrubber and, in the AirPlay case, the volume row —
// are not UISliders. They are a rounded capsule with no thumb, and they SWELL under the
// finger: the bar roughly doubles in thickness while held, then springs back. A UISlider
// cannot be made to look or behave like that (a thin track plus a round thumb is exactly
// what it is), so this is a small UIControl that draws the capsule itself.
//
// Tracking is RELATIVE, not absolute: touching down does not jump the volume to the
// touch's x. Apple can afford jump-to-position on a scrubber, where a mistake costs you
// your place in a song; on volume a stray tap near the right edge would blast the
// output. So the value follows how far the finger has MOVED from where it landed, which
// is also the "hold, then adjust" gesture people expect here.
static const CGFloat kNUVolumeTrackRestHeight = 7.0;    // measured off Apple's own bar
static const CGFloat kNUVolumeTrackHeldHeight = 14.0;   // swelled, while held
static const CGFloat kNUVolumeSwellDuration   = 0.30;
static const CGFloat kNUVolumeSwellDamping    = 0.85;
static const float   kNUVolumeAXStep          = 1.0f / 16.0f;   // iOS's own volume step

@interface NUVolumeTrackView : UIControl <UIGestureRecognizerDelegate>
@property (nonatomic) float value;                        // 0…1
@property (nonatomic, getter=isHeld) BOOL held;
// Rest colours; nil means use the built-in ones. Set from the scrubber when it will say.
@property (nonatomic, strong) UIColor *trackColor;
@property (nonatomic, strong) UIColor *fillColor;
@end

@implementation NUVolumeTrackView {
    UIView *_track;
    UIView *_fill;
    CGFloat _touchStartX;
    float _valueAtTouchStart;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    _value = 0.0f;

    _track = [[UIView alloc] initWithFrame:CGRectZero];
    _track.clipsToBounds = YES;                 // clips the fill's trailing cap
    _track.userInteractionEnabled = NO;
    [self addSubview:_track];

    _fill = [[UIView alloc] initWithFrame:CGRectZero];
    _fill.userInteractionEnabled = NO;
    [_track addSubview:_fill];
    [self nu_applyColors];

    // Driven by a gesture recognizer, NOT UIControl's own touch tracking, and this is
    // the whole reason the scrubber works where this did not.
    //
    // UIControl tracking is view-level touch delivery: -touchesBegan: on the view. An
    // ancestor recognizer with delaysTouchesBegan (the lock screen has several — paging,
    // notification-list pan, the CoverSheet's own) withholds that delivery until it
    // decides, and cancels it outright if it wins. Gesture recognizers are fed touches
    // directly and are unaffected by another recognizer's delay. Apple's scrubber lives on
    // recognizers, which is why a drag on it registers while an identical drag 40pt lower
    // reached nothing at all — no begin, so no swell, so it read as a dead control.
    //
    // minimumPressDuration 0 makes this fire on touch-down like a slider rather than after
    // a hold; allowableMovement is irrelevant at that duration but set wide so a drag that
    // starts immediately is not read as a failed press.
    UILongPressGestureRecognizer *press =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(nu_handlePress:)];
    press.minimumPressDuration = 0.0;
    press.allowableMovement = CGFLOAT_MAX;
    press.cancelsTouchesInView = NO;
    press.delegate = self;
    [self addGestureRecognizer:press];

    self.isAccessibilityElement = YES;
    self.accessibilityTraits = UIAccessibilityTraitAdjustable;
    self.accessibilityLabel = NULocalizedString(@"AX_VOLUME", @"Volume");
    return self;
}

// At rest the row matches the scrubber. HELD, it brightens — that is half of the swell,
// and it was the whole of the earlier mistake: the fill was pinned at the held brightness,
// so the row always looked like it was already being dragged.
- (void)nu_applyColors {
    UIColor *track = self.trackColor ?: NUVolumeColor(0.18);
    UIColor *fill = self.fillColor ?: NUVolumeColor(0.62);
    _track.backgroundColor = track;
    _fill.backgroundColor = self.held ? NUVolumeColor(0.95) : fill;
}

- (void)setTrackColor:(UIColor *)trackColor {
    if ([trackColor isEqual:_trackColor]) return;
    _trackColor = trackColor;
    [self nu_applyColors];
}

- (void)setFillColor:(UIColor *)fillColor {
    if ([fillColor isEqual:_fillColor]) return;
    _fillColor = fillColor;
    [self nu_applyColors];
}

- (void)setValue:(float)value {
    float clamped = MAX(0.0f, MIN(1.0f, value));
    if (fabsf(clamped - _value) < 0.0005f) return;
    _value = clamped;
    [self setNeedsLayout];
}

// The capsule is 7pt tall at rest inside a 22pt frame. Give the control the rest of the
// band vertically so a touch that lands slightly high or low still starts a drag —
// otherwise the visible target is thinner than a fingertip.
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    return CGRectContainsPoint(CGRectInset(self.bounds, 0, -7.0), point);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat h = self.held ? kNUVolumeTrackHeldHeight : kNUVolumeTrackRestHeight;
    CGFloat w = self.bounds.size.width;
    _track.frame = CGRectMake(0, (self.bounds.size.height - h) / 2.0, w, h);
    _track.layer.cornerRadius = h / 2.0;
    _track.layer.cornerCurve = kCACornerCurveContinuous;
    _fill.frame = CGRectMake(0, 0, w * self.value, h);
    _fill.layer.cornerRadius = h / 2.0;
    _fill.layer.cornerCurve = kCACornerCurveContinuous;
}

// Reduce Motion gates the swell (autonomous motion); the finger-tracking itself is
// direct manipulation and always stays live — same rule NUNextUpRowView follows.
- (void)nu_setHeld:(BOOL)held {
    if (self.held == held) return;
    self.held = held;
    [self nu_applyColors];
    [self setNeedsLayout];
    if (UIAccessibilityIsReduceMotionEnabled()) { [self layoutIfNeeded]; return; }
    [UIView animateWithDuration:kNUVolumeSwellDuration
                          delay:0
         usingSpringWithDamping:kNUVolumeSwellDamping
          initialSpringVelocity:0
                        options:UIViewAnimationOptionAllowUserInteraction |
                                UIViewAnimationOptionBeginFromCurrentState
                     animations:^{ [self layoutIfNeeded]; }
                     completion:nil];
}

#pragma mark Tracking

- (void)nu_handlePress:(UILongPressGestureRecognizer *)press {
    if (!self.enabled) return;
    CGPoint p = [press locationInView:self];
    switch (press.state) {
        case UIGestureRecognizerStateBegan:
            _touchStartX = p.x;
            _valueAtTouchStart = self.value;
            [self nu_setHeld:YES];
            // Claim the touch across the process boundary: SpringBoard fails its paging
            // and scroll gestures while this is raised, so a finger that wanders off the
            // platter keeps driving the volume instead of starting to scroll notifications.
            NUVolumeTouchSet(1);
            [self sendActionsForControlEvents:UIControlEventTouchDown];
            break;
        case UIGestureRecognizerStateChanged: {
            CGFloat width = MAX(1.0, self.bounds.size.width);
            self.value = _valueAtTouchStart + (float)((p.x - _touchStartX) / width);
            [self sendActionsForControlEvents:UIControlEventValueChanged];
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            [self nu_setHeld:NO];
            NUVolumeTouchSet(0);
            [self sendActionsForControlEvents:UIControlEventTouchUpInside];
            break;
        default:
            break;
    }
}

// Never lose to somebody else's recognizer, and never make anyone else lose to this one:
// the lock screen is thick with pans and swipes, and a volume drag has to coexist.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gr
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}

#pragma mark Accessibility

- (NSString *)accessibilityValue {
    return [NSString stringWithFormat:@"%d%%", (int)lroundf(self.value * 100.0f)];
}

- (void)accessibilityIncrement {
    self.value = self.value + kNUVolumeAXStep;
    [self sendActionsForControlEvents:UIControlEventValueChanged];
}

- (void)accessibilityDecrement {
    self.value = self.value - kNUVolumeAXStep;
    [self sendActionsForControlEvents:UIControlEventValueChanged];
}

@end

#pragma mark The strip

@interface NUVolumeStripView ()
@property (nonatomic, strong) UIImageView *lowGlyph;
@property (nonatomic, strong) UIImageView *highGlyph;
@property (nonatomic, strong) NUVolumeTrackView *track;
@property (nonatomic, assign) BOOL dragging;
@property (nonatomic, copy) NSString *lastWritePath;
@property (nonatomic, assign) CFAbsoluteTime lastPublish;
@end

@implementation NUVolumeStripView

+ (CGFloat)preferredHeight { return kNUVolumeStripHeight; }

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = UIColor.clearColor;

    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:kNUVolumeGlyphPoint
                                                       weight:UIImageSymbolWeightMedium];
    _lowGlyph = [self nu_glyphNamed:@"speaker.fill" configuration:cfg];
    _highGlyph = [self nu_glyphNamed:@"speaker.wave.3.fill" configuration:cfg];
    [self addSubview:_lowGlyph];
    [self addSubview:_highGlyph];

    _track = [[NUVolumeTrackView alloc] initWithFrame:CGRectZero];
    [_track addTarget:self action:@selector(nu_trackChanged:)
     forControlEvents:UIControlEventValueChanged];
    [_track addTarget:self action:@selector(nu_trackDown:) forControlEvents:UIControlEventTouchDown];
    [_track addTarget:self action:@selector(nu_trackUp:)
     forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside |
                      UIControlEventTouchCancel];
    [self addSubview:_track];

    // The HUD suppressor goes in FIRST: it doubles as the last-resort write path, and
    // NUVolumeSystemIsWritable consults it.
    NUVolumeInstallHUDSuppressor(self);
    NULog("volume: writable=%d in %{public}@", NUVolumeSystemIsWritable(),
          NSProcessInfo.processInfo.processName);

    [self refreshFromSystem];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                            selector:@selector(nu_systemVolumeChanged:)
                                                name:kNUVolumeChangedNotification
                                              object:nil];
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:kNUVolumeChangedNotification object:nil];
    // Belt and braces alongside the timestamp in NUVolumeTouchGet: a strip destroyed
    // mid-drag would otherwise leave lock-screen paging failed until the flag ages out.
    if (self.dragging) NUVolumeTouchSet(0);
}

- (UIImageView *)nu_glyphNamed:(NSString *)name configuration:(UIImageSymbolConfiguration *)cfg {
    UIImage *img = [[UIImage systemImageNamed:name withConfiguration:cfg]
                    imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    UIImageView *view = [[UIImageView alloc] initWithImage:img];
    view.contentMode = UIViewContentModeCenter;
    view.tintColor = NUVolumeColor(0.55);
    return view;
}

#pragma mark Value plumbing

- (void)refreshFromSystem {
    if (self.dragging) return;
    self.track.value = NUVolumeSystemGet();
}

- (void)nu_systemVolumeChanged:(NSNotification *)note {
    if (self.dragging) return;
    // No category filter: this used to drop anything not tagged "Audio", which silently
    // ignored the media category under its real name. Re-reading the active level is both
    // simpler and correct — a ringer change reads back the same media level and is a no-op.
    [self refreshFromSystem];
}

- (void)nu_trackChanged:(NUVolumeTrackView *)track {
    // Publish for SpringBoard to apply — the local write is refused in MediaRemoteUI — and
    // still attempt it locally, since whichever side succeeds writes the same value and a
    // double write of one level is harmless. Throttled: value-changed fires at touch-move
    // rate and each request costs SpringBoard an AVSystemController round trip.
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - self.lastPublish > 0.05) {
        self.lastPublish = now;
        NUVolumeRequestPublish(track.value);
    }
    NSString *path = NUVolumeApplyLocally(track.value)
                     ?: @"NONE locally — relying on the SpringBoard side";
    // Throttled to a change of path, because value-changed fires on every touch-move and
    // this would otherwise be the entire log. nil is normalised above so a total failure
    // logs once rather than on every move.
    if (![path isEqualToString:self.lastWritePath]) {
        self.lastWritePath = path;
        NULog("volume strip: write path = %{public}@ (value %.3f, system now %.3f)",
              path, track.value, NUVolumeSystemGet());
    }
}

- (void)nu_trackDown:(NUVolumeTrackView *)track {
    self.dragging = YES;
    NULog("volume strip: touch down at %.3f — tracking started", track.value);
}

- (void)nu_trackUp:(NUVolumeTrackView *)track {
    self.dragging = NO;
    // The final value always goes, throttle or no throttle: releasing between ticks would
    // otherwise leave the volume a few percent short of where the finger ended.
    NUVolumeRequestPublish(track.value);
    NULog("volume strip: released at %.3f (system %.3f)", track.value, NUVolumeSystemGet());
}

#pragma mark Touch instrumentation

// "The slider is there but I can't drag it" has two very different causes — the touch
// never arrives (something above is eating it, or the platter's remote scene isn't
// forwarding), or it arrives and the write is refused. These lines tell the two apart in
// the log rather than by guesswork.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    NULog("volume strip: hitTest %{public}@ -> %{public}@ (trackEnabled=%d)",
          NSStringFromCGPoint(point),
          hit ? NSStringFromClass(hit.class) : @"(nil)", self.track.enabled);
    return hit;
}

#pragma mark Layout

- (void)layoutSubviews {
    [super layoutSubviews];

    // Match the song-time slider. Done here rather than at init because the scrubber has not
    // been laid out yet when the strip is created, and colours cannot be read off a
    // zero-sized view.
    UIColor *trackColor = nil, *fillColor = nil;
    if (NUVolumeCopyScrubberColors(self.superview, &trackColor, &fillColor)) {
        self.track.trackColor = trackColor;
        self.track.fillColor = fillColor;
    }

    // The control band is the TOP kNUVolumeControlH points; the rest of the strip is the
    // platter's own bottom inset, which has to stay empty because Apple's copy of it is
    // above us (it was laid out inside the clamped height).
    CGFloat w = self.bounds.size.width;
    CGSize lowSize = self.lowGlyph.image.size;
    CGSize highSize = self.highGlyph.image.size;

    self.lowGlyph.frame = CGRectMake(kNUVolumeHInset, 0, lowSize.width, kNUVolumeControlH);
    self.highGlyph.frame = CGRectMake(w - kNUVolumeHInset - highSize.width, 0,
                                      highSize.width, kNUVolumeControlH);

    CGFloat trackX = CGRectGetMaxX(self.lowGlyph.frame) + kNUVolumeGap;
    CGFloat trackW = CGRectGetMinX(self.highGlyph.frame) - kNUVolumeGap - trackX;
    self.track.frame = CGRectMake(trackX, 0, MAX(1.0, trackW), kNUVolumeControlH);
}

@end
