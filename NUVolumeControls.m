#import "NUVolumeControls.h"
#import "NUPrefs.h"
#import "NUPrivate.h"
#import "NUShared.h"
#import "NULocalization.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdlib.h>
#import <string.h>

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

BOOL NUVolumeCustomPreferred(void) {
    return NUPrefBool(@"volumeSliderCustom", NO);
}

CGFloat NUVolumeStripHeight(void) { return kNUVolumeStripHeight; }
CGFloat NUVolumeControlHeight(void) { return kNUVolumeControlH; }

#pragma mark - System volume (AVSystemController)

// Resolved at runtime so nothing private gets linked. Declared under our own name
// rather than AVSystemController's so the class symbol is never referenced — a
// hard reference would make dyld fail the whole tweak on a build that renamed it.
@interface NUAVSystemController : NSObject
+ (id)sharedAVSystemController;
- (BOOL)getVolume:(float *)outVolume forCategory:(NSString *)category;
- (BOOL)setVolumeTo:(float)volume forCategory:(NSString *)category;
- (BOOL)setAttribute:(id)attribute forKey:(NSString *)key;
@end

static NSString * const kNUVolumeCategory = @"Audio";   // media playback volume
static NSString * const kNUVolumeChangedNotification =
    @"AVSystemController_SystemVolumeDidChangeNotification";
static NSString * const kNUVolumeParamKey =
    @"AVSystemController_AudioVolumeNotificationParameter";
static NSString * const kNUVolumeCategoryKey =
    @"AVSystemController_AudioCategoryNotificationParameter";

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

static float NUVolumeSystemGet(void) {
    NUAVSystemController *sc = NUVolumeSystemController();
    if (![sc respondsToSelector:@selector(getVolume:forCategory:)]) return 0.0f;
    float v = 0.0f;
    if (![sc getVolume:&v forCategory:kNUVolumeCategory]) return 0.0f;
    return MAX(0.0f, MIN(1.0f, v));
}

static void NUVolumeSystemSet(float volume) {
    NUAVSystemController *sc = NUVolumeSystemController();
    if (![sc respondsToSelector:@selector(setVolumeTo:forCategory:)]) return;
    [sc setVolumeTo:MAX(0.0f, MIN(1.0f, volume)) forCategory:kNUVolumeCategory];
}

BOOL NUVolumeSystemIsWritable(void) {
    return [NUVolumeSystemController() respondsToSelector:@selector(setVolumeTo:forCategory:)];
}

float NUVolumeSystemLevel(void) { return NUVolumeSystemGet(); }

#pragma mark - Native gate discovery

// Which way a discovered gate has to answer for the row to appear. Names are matched
// case-insensitively on the selector, because the selector itself differs between
// builds — MediaRemoteUI has carried volume availability as a property on the view, on
// the view controller and on the session controller at various points, and hard-coding
// one of them is how this feature silently stops working after an update.
typedef NS_ENUM(NSInteger, NUVolumeGate) {
    NUVolumeGateNone = 0,
    NUVolumeGateForceYES,
    NUVolumeGateForceNO,
};

static NUVolumeGate NUVolumeGateForSelectorName(NSString *name) {
    NSString *n = name.lowercaseString;
    if (![n containsString:@"volume"]) return NUVolumeGateNone;

    // Live interaction state and measurements: forcing these fights the slider
    // instead of revealing it (a pinned "is dragging" never lets go of the thumb).
    for (NSString *veto in @[ @"dragging", @"tracking", @"changing", @"animat",
                              @"warning", @"limit", @"mute", @"pending", @"step" ])
        if ([n containsString:veto]) return NUVolumeGateNone;

    // Inverted senses first, so volumeControlsHidden is not read as "…Controls".
    for (NSString *no in @[ @"hidden", @"disabled", @"suppress", @"collaps" ])
        if ([n containsString:no]) return NUVolumeGateForceNO;

    for (NSString *yes in @[ @"available", @"supports", @"support", @"shouldshow", @"shoulddisplay",
                             @"shouldpresent", @"showsvolume", @"showvolume", @"displaysvolume",
                             @"canshow", @"cancontrol", @"controllable", @"capable",
                             @"wants", @"enabled", @"allowed", @"visible" ])
        if ([n containsString:yes]) return NUVolumeGateForceYES;

    return NUVolumeGateNone;
}

// A zero-argument method returning BOOL. `B` is arm64's bool; `c` is the legacy
// signed char that older headers still encode BOOL as.
static BOOL NUVolumeIsBoolGetter(Method m) {
    if (method_getNumberOfArguments(m) != 2) return NO;   // self + _cmd only
    char *encoding = method_copyReturnType(m);            // allocates
    if (!encoding) return NO;
    char ret = encoding[0];
    free(encoding);
    return ret == 'B' || ret == 'c';
}

// Every replacement re-reads the preference, so the Settings switch takes effect on
// the next layout pass with no respring — same contract as the rest of the tweak.
static BOOL NUVolumeOverrideActive(void) {
    return NUVolumeFeatureEnabled() && !NUVolumeCustomPreferred();
}

static void NUVolumeSwizzleGatesOnClass(Class cls) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    if (!methods) return;
    for (unsigned int i = 0; i < count; i++) {
        Method m = methods[i];
        SEL sel = method_getName(m);
        NUVolumeGate gate = NUVolumeGateForSelectorName(NSStringFromSelector(sel));
        if (gate == NUVolumeGateNone) continue;
        if (!NUVolumeIsBoolGetter(m)) continue;

        IMP orig = method_getImplementation(m);
        BOOL forced = (gate == NUVolumeGateForceYES);
        IMP replacement = imp_implementationWithBlock(^BOOL(__unsafe_unretained id obj) {
            if (NUVolumeOverrideActive()) return forced;
            return ((BOOL (*)(id, SEL))orig)(obj, sel);
        });
        method_setImplementation(m, replacement);
        NULog("volume: gate forced %{public}@ -[%{public}@ %{public}@]",
              forced ? @"YES" : @"NO", NSStringFromClass(cls), NSStringFromSelector(sel));
    }
    free(methods);
}

void NUVolumeForceNativeGates(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Only MediaRemoteUI's own classes, found through the image that vends the
        // now-playing view — enumerating the whole runtime would swizzle UIKit and
        // MediaPlayer gates that have nothing to do with this player.
        Class anchor = objc_getClass("MRUNowPlayingView");
        const char *image = anchor ? class_getImageName(anchor) : NULL;
        if (!image) { NULog("volume: MediaRemoteUI image not found — native gates skipped"); return; }

        unsigned int count = 0;
        const char **names = objc_copyClassNamesForImage(image, &count);
        if (!names) return;
        NSInteger touched = 0;
        for (unsigned int i = 0; i < count; i++) {
            Class cls = objc_getClass(names[i]);
            if (!cls) continue;
            NUVolumeSwizzleGatesOnClass(cls);
            touched++;
        }
        free((void *)names);
        NULog("volume: scanned %ld MediaRemoteUI classes for volume gates", (long)touched);
    });
}

#pragma mark - Native row

UIView *NUVolumeNativeView(UIView *nowPlayingView) {
    if (!nowPlayingView) return nil;
    if ([nowPlayingView respondsToSelector:@selector(volumeControlsView)]) {
        UIView *v = [(MRUNowPlayingView *)nowPlayingView volumeControlsView];
        if (v) return v;
    }
    // A renamed accessor still leaves the view in the tree under a volume-ish class
    // name; one shallow pass over the player's own children finds it without walking
    // the whole hierarchy on every layout.
    for (UIView *sub in nowPlayingView.subviews) {
        NSString *cls = NSStringFromClass(sub.class);
        if ([cls containsString:@"Volume"]) return sub;
        for (UIView *inner in sub.subviews)
            if ([NSStringFromClass(inner.class) containsString:@"Volume"]) return inner;
    }
    return nil;
}

BOOL NUVolumeRevealNative(UIView *nowPlayingView) {
    UIView *native = NUVolumeNativeView(nowPlayingView);
    if (!native) return NO;
    // Apple hides rather than removes it in some states; both are cheap to undo, and
    // neither is what keeps it out of the layout (that is the gate above) — this only
    // covers the case where the row is measured but drawn invisible.
    if (native.hidden) native.hidden = NO;
    if (native.alpha < 0.01) native.alpha = 1.0;
    return native.bounds.size.height > 1.0;
}

// Consecutive layout passes in which the native row stayed unlaid-out. Three is
// enough to outlast the pass that runs before the forced gates are first consulted,
// while still flipping to our own strip within a single appearance.
static void * const kNUVolumeMissCountKey = (void *)&kNUVolumeMissCountKey;
static void * const kNUVolumeMissedKey    = (void *)&kNUVolumeMissedKey;
static const NSInteger kNUVolumeMissLimit = 3;

BOOL NUVolumeNoteNativeMiss(UIView *nowPlayingView) {
    if ([objc_getAssociatedObject(nowPlayingView, kNUVolumeMissedKey) boolValue]) return NO;
    NSInteger misses = [objc_getAssociatedObject(nowPlayingView, kNUVolumeMissCountKey) integerValue] + 1;
    objc_setAssociatedObject(nowPlayingView, kNUVolumeMissCountKey, @(misses),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (misses < kNUVolumeMissLimit) return NO;
    objc_setAssociatedObject(nowPlayingView, kNUVolumeMissedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NULog("volume: native row never laid out after %ld passes — using our own strip",
          (long)misses);
    return YES;
}

void NUVolumeClearNativeMiss(UIView *nowPlayingView) {
    objc_setAssociatedObject(nowPlayingView, kNUVolumeMissCountKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(nowPlayingView, kNUVolumeMissedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - Probe

// DEBUG-only. Reads every volume-shaped gate MediaRemoteUI declares and its current
// answer on the live player, so the exact selector this build uses can be read off
// the log rather than guessed at. Only zero-argument BOOL getters are invoked.
void NUVolumeProbeOnce(UIView *nowPlayingView) {
#ifdef DEBUG
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NULog("volume probe: iOS %ld, view=%{public}@", (long)NUVolumeIOSMajor(),
              NSStringFromClass(nowPlayingView.class));

        UIView *native = NUVolumeNativeView(nowPlayingView);
        NULog("volume probe: native row=%{public}@ frame=%{public}@ hidden=%d alpha=%.2f super=%{public}@",
              native ? NSStringFromClass(native.class) : @"(nil)",
              NSStringFromCGRect(native.frame), native.hidden, native.alpha,
              native.superview ? NSStringFromClass(native.superview.class) : @"(nil)");
        if ([nowPlayingView respondsToSelector:@selector(layout)])
            NULog("volume probe: MRUNowPlayingView.layout = %lld",
                  [(MRUNowPlayingView *)nowPlayingView layout]);

        // The player view, its controller and the session controller are where the
        // gate has lived historically; anything else in MediaRemoteUI with "Volume"
        // in the class name is worth reading too.
        NSMutableArray<Class> *classes = [NSMutableArray array];
        for (NSString *name in @[ @"MRUNowPlayingView", @"MRUNowPlayingViewController",
                                  @"MRUNowPlayingController", @"MRUControlCenterViewController" ]) {
            Class c = objc_getClass(name.UTF8String);
            if (c) [classes addObject:c];
        }
        Class anchor = objc_getClass("MRUNowPlayingView");
        const char *image = anchor ? class_getImageName(anchor) : NULL;
        if (image) {
            unsigned int count = 0;
            const char **names = objc_copyClassNamesForImage(image, &count);
            for (unsigned int i = 0; names && i < count; i++) {
                if (!strstr(names[i], "Volume")) continue;
                Class c = objc_getClass(names[i]);
                if (c && ![classes containsObject:c]) [classes addObject:c];
            }
            if (names) free((void *)names);
        }

        for (Class cls in classes) {
            unsigned int count = 0;
            Method *methods = class_copyMethodList(cls, &count);
            for (unsigned int i = 0; methods && i < count; i++) {
                SEL sel = method_getName(methods[i]);
                NSString *name = NSStringFromSelector(sel);
                if (![name.lowercaseString containsString:@"volume"]) continue;
                char *ret = method_copyReturnType(methods[i]);
                BOOL boolGetter = NUVolumeIsBoolGetter(methods[i]);
                NSString *value = @"-";
                if (boolGetter && [nowPlayingView isKindOfClass:cls])
                    value = ((BOOL (*)(id, SEL))objc_msgSend)(nowPlayingView, sel) ? @"YES" : @"NO";
                NULog("volume probe: -[%{public}@ %{public}@] ret=%s args=%u on-view=%{public}@ gate=%ld",
                      NSStringFromClass(cls), name, ret ?: "?",
                      method_getNumberOfArguments(methods[i]) - 2, value,
                      (long)NUVolumeGateForSelectorName(name));
                if (ret) free(ret);
            }
            if (methods) free(methods);
        }
        NULog("volume probe: AVSystemController writable=%d current=%.2f",
              NUVolumeSystemIsWritable(), NUVolumeSystemGet());
    });
#else
    (void)nowPlayingView;
#endif
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

// MPVolumeView's one property we touch. Declared locally for the same reason as
// NUAVSystemController above — importing MediaPlayer just for this would link the
// framework, and an `id` receiver can't type-check a selector nothing declares.
@interface NUMPVolumeView : UIView
@property (nonatomic) BOOL showsRouteButton;
@end

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

@interface NUVolumeTrackView : UIControl
@property (nonatomic) float value;                        // 0…1
@property (nonatomic, getter=isHeld) BOOL held;
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
    _track.backgroundColor = NUVolumeColor(0.18);
    _track.clipsToBounds = YES;                 // clips the fill's trailing cap
    _track.userInteractionEnabled = NO;
    [self addSubview:_track];

    _fill = [[UIView alloc] initWithFrame:CGRectZero];
    _fill.backgroundColor = NUVolumeColor(0.95);
    _fill.userInteractionEnabled = NO;
    [_track addSubview:_fill];

    self.isAccessibilityElement = YES;
    self.accessibilityTraits = UIAccessibilityTraitAdjustable;
    self.accessibilityLabel = NULocalizedString(@"AX_VOLUME", @"Volume");
    return self;
}

- (void)setValue:(float)value {
    float clamped = MAX(0.0f, MIN(1.0f, value));
    if (fabsf(clamped - _value) < 0.0005f) return;
    _value = clamped;
    [self setNeedsLayout];
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

- (BOOL)beginTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    _touchStartX = [touch locationInView:self].x;
    _valueAtTouchStart = self.value;
    [self nu_setHeld:YES];
    return YES;
}

- (BOOL)continueTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    CGFloat width = MAX(1.0, self.bounds.size.width);
    CGFloat dx = [touch locationInView:self].x - _touchStartX;
    self.value = _valueAtTouchStart + (float)(dx / width);
    [self sendActionsForControlEvents:UIControlEventValueChanged];
    return YES;
}

- (void)endTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    [self nu_setHeld:NO];
    [self sendActionsForControlEvents:UIControlEventValueChanged];
}

- (void)cancelTrackingWithEvent:(UIEvent *)event { [self nu_setHeld:NO]; }

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

    if (!NUVolumeSystemIsWritable()) {
        // Read-only: leave it visible (it still reflects the hardware buttons) but don't
        // pretend it can be dragged.
        _track.enabled = NO;
        NULog("volume: system volume not writable in %{public}@ — strip is display-only",
              NSProcessInfo.processInfo.processName);
    }

    [self nu_installHUDSuppressor];
    [self refreshFromSystem];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                            selector:@selector(nu_systemVolumeChanged:)
                                                name:kNUVolumeChangedNotification
                                              object:nil];
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:kNUVolumeChangedNotification object:nil];
}

- (UIImageView *)nu_glyphNamed:(NSString *)name configuration:(UIImageSymbolConfiguration *)cfg {
    UIImage *img = [[UIImage systemImageNamed:name withConfiguration:cfg]
                    imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    UIImageView *view = [[UIImageView alloc] initWithImage:img];
    view.contentMode = UIViewContentModeCenter;
    view.tintColor = NUVolumeColor(0.55);
    return view;
}

// A volume change we make ourselves still raises SpringBoard's volume HUD, which on the
// lock screen lands right on top of the platter. An MPVolumeView in the window is the
// long-standing way to tell the system a slider is already on screen. Resolved by name so
// MediaPlayer is not linked, and entirely optional — if it misbehaves on some build,
// deleting this method only brings the HUD back.
- (void)nu_installHUDSuppressor {
    Class MPV = NSClassFromString(@"MPVolumeView");
    if (!MPV) return;
    NUMPVolumeView *suppressor =
        (NUMPVolumeView *)[[MPV alloc] initWithFrame:CGRectMake(-4000, -4000, 1, 1)];
    if ([suppressor respondsToSelector:@selector(setShowsRouteButton:)])
        suppressor.showsRouteButton = NO;
    suppressor.alpha = 0.001;   // must be in the hierarchy; must not be `hidden`
    suppressor.userInteractionEnabled = NO;
    [self addSubview:suppressor];
}

#pragma mark Value plumbing

- (void)refreshFromSystem {
    if (self.dragging) return;
    self.track.value = NUVolumeSystemGet();
}

- (void)nu_systemVolumeChanged:(NSNotification *)note {
    NSString *category = note.userInfo[kNUVolumeCategoryKey];
    if (category && ![category isEqualToString:kNUVolumeCategory]) return;  // ringer, not media
    if (self.dragging) return;
    NSNumber *value = note.userInfo[kNUVolumeParamKey];
    if (value) self.track.value = value.floatValue;
    else [self refreshFromSystem];
}

- (void)nu_trackChanged:(NUVolumeTrackView *)track {
    NUVolumeSystemSet(track.value);
    NULog("volume strip: track -> %.3f (system now %.3f)", track.value, NUVolumeSystemGet());
}

- (void)nu_trackDown:(NUVolumeTrackView *)track {
    self.dragging = YES;
    NULog("volume strip: touch down, value %.3f", track.value);
}

- (void)nu_trackUp:(NUVolumeTrackView *)track {
    self.dragging = NO;
    NULog("volume strip: released at %.3f", track.value);
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
