#import "NUPrefsRootListController.h"
#import "NUPrefs.h"
#import <UIKit/UIKit.h>
#import <dlfcn.h>

// Renders another installed app's icon. Present and stable across the deployed iOS range
// (15–18) inside Preferences.app; guarded with -respondsToSelector: so a future rename
// just drops the icon rather than crashing Settings.
@interface UIImage (NUAppIcons)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bundleIdentifier
                                               format:(int)format
                                                scale:(CGFloat)scale;
@end

// LaunchServices, resolved via NSClassFromString so we don't link the private framework.
// LSApplicationProxy answers "is this app installed"; LSApplicationWorkspace lets us observe
// installs/uninstalls live so the pane can refresh without being reopened.
@interface LSApplicationProxy : NSObject
+ (instancetype)applicationProxyForIdentifier:(NSString *)identifier;
@property (nonatomic, readonly) NSString *shortVersionString;
@end

@protocol LSApplicationWorkspaceObserverProtocol <NSObject>
@optional
- (void)applicationsDidInstall:(NSArray *)apps;
- (void)applicationsDidUninstall:(NSArray *)apps;
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (void)addObserver:(id)observer;
- (void)removeObserver:(id)observer;
@end

// UIKit's model of the sensor housing: the cutout this panel has, in screen points. On iPhone
// the shape is a UISDisplaySingleRectShape, i.e. it also conforms to _UIDisplayInfoRectShape
// and answers -rect; a device without a cutout has no exclusion area at all. Present since
// iOS 16 and still there on 26, but guarded with -respondsToSelector: either way.
@interface UIScreen (NUDisplayInfo)
- (id)_exclusionArea;
- (unsigned long long)_artworkSubtype;
@end

@protocol NUDisplayInfoRectShape <NSObject>
- (CGRect)rect;
@end

// Per-app toggle key → its app's bundle id. The single source of truth for the app bundle
// ids. The master switch and the interface rows return nil (kept as-is, no icon, never hidden).
static NSString *NUBundleIDForKey(NSString *key) {
    if ([key isEqualToString:@"enabledMusic"])        return @"com.apple.Music";
    if ([key isEqualToString:@"enabledPodcasts"])     return @"com.apple.podcasts";
    if ([key isEqualToString:@"enabledYouTubeMusic"]) return @"com.google.ios.youtubemusic";
    if ([key isEqualToString:@"enabledSpotify"])      return @"com.spotify.client";
    return nil;
}

// The four app-toggle keys, in display order — the canonical iteration list for the
// install-state signature below.
static NSArray<NSString *> *NUAppToggleKeys(void) {
    return @[@"enabledMusic", @"enabledPodcasts", @"enabledYouTubeMusic", @"enabledSpotify"];
}

// YES if the app is installed on this device. Fails OPEN — if LaunchServices is unavailable
// we return YES so a real app's toggle is never hidden by mistake; only a definitive
// "not installed" hides a row. shortVersionString is the reliable indicator:
// applicationProxyForIdentifier: can hand back a placeholder proxy (no version) for an app
// that was previously installed. (Same check Hush uses.)
static BOOL NUAppInstalled(NSString *bundleID) {
    if (!bundleID) return YES;                               // non-app row: always keep
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    if (!proxyClass) return YES;                             // LS unavailable → fail open
    LSApplicationProxy *proxy = [proxyClass applicationProxyForIdentifier:bundleID];
    return [proxy respondsToSelector:@selector(shortVersionString)]
        && [proxy shortVersionString].length > 0;
}

// Order-stable signature (e.g. "1101") of which of our apps are installed right now, so a
// workspace callback can cheaply tell whether anything RELEVANT changed before reloading —
// installing/removing an unrelated app must not thrash the pane.
static NSString *NUInstalledSignature(void) {
    NSMutableString *sig = [NSMutableString string];
    for (NSString *key in NUAppToggleKeys())
        [sig appendFormat:@"%d", NUAppInstalled(NUBundleIDForKey(key)) ? 1 : 0];
    return sig;
}

// MobileGestalt's one-argument query, resolved via dlsym so this bundle links nothing
// private: libMobileGestalt is already loaded in every UIKit process, so RTLD_DEFAULT
// finds it. A missing symbol or an unanswerable question yields -1 below.
typedef CFTypeRef (*NUMGCopyAnswer)(CFStringRef);

// The display-artwork subtype — the panel's pixel height (2532 = iPhone 14, 2556 = 14 Pro …) —
// as MobileGestalt has it, or -1 if it won't answer.
//
// The question is "ArtworkTraits", NOT "ArtworkDeviceSubType": the answer is a dictionary that
// carries the subtype alongside idiom, scale and gamut. There is no scalar question named after
// the subtype — asking for one returns nothing at all, on every device.
//
// MobileGestalt is asked rather than UIKit or the panel geometry because this cache entry is
// what the tweaks that bring the island to older devices rewrite: VisibleIsland stores
// {ArtworkDeviceSubType = 2556} under the hashed ArtworkTraits key in CacheExtra. It is the only
// signal a spoofed island moves.
static NSInteger NUMobileGestaltArtworkSubType(void) {
    NUMGCopyAnswer copyAnswer = (NUMGCopyAnswer)dlsym(RTLD_DEFAULT, "MGCopyAnswer");
    if (!copyAnswer) return -1;
    CFTypeRef answer = copyAnswer(CFSTR("ArtworkTraits"));
    if (!answer) return -1;
    id traits = (__bridge id)answer;
    NSInteger subType = -1;
    if ([traits isKindOfClass:NSDictionary.class]) {
        id value = ((NSDictionary *)traits)[@"ArtworkDeviceSubType"];
        if ([value respondsToSelector:@selector(integerValue)]) subType = [value integerValue];
    }
    CFRelease(answer);
    return subType;
}

// The artwork subtype from whichever source will state it, or -1 if none will. MobileGestalt
// comes first because that is where a spoof is written; UIKit's resolved value is the same
// number read back out of the frameworks, and is equally spoof-aware — a spoofed cache is what
// UIKit resolved it from.
static NSInteger NUArtworkSubType(void) {
    NSInteger subType = NUMobileGestaltArtworkSubType();
    if (subType > 0) return subType;
    UIScreen *screen = UIScreen.mainScreen;
    if ([screen respondsToSelector:@selector(_artworkSubtype)]) {
        unsigned long long fromUIKit = [screen _artworkSubtype];
        if (fromUIKit > 0) return (NSInteger)fromUIKit;
    }
    return -1;
}

// YES if this device shows a Dynamic Island, i.e. whether the "Dynamic Island" row is worth
// offering at all. iOS 16 is the floor — that is where the system aperture arrived — and the
// rest takes three steps, because no single signal covers both real and spoofed islands:
//
//  1. An artwork subtype known to carry an island wins outright. This is the only step a spoof
//     can move, so it runs first — a notched phone or an iPad spoofed into an island keeps its
//     toggle, even though step 2 would call its panel islandless.
//  2. Otherwise the panel decides: a notch is cut into the top edge (exclusion area at y = 0),
//     an island floats below it (y = 14 on an iPhone 17), a home-button device has no exclusion
//     area at all. Physical, so it needs no table and stays right on unknown hardware.
//  3. Only if UIKit won't say either: fail open on phones, like NUAppInstalled does — a real
//     island must never lose its toggle — but never on iPad, which has no aperture to speak of.
static BOOL NUDeviceHasDynamicIsland(void) {
    static BOOL hasIsland = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion < 16) return;
        static const NSInteger islandSubTypes[] = {
            2556,   // 14 Pro / 15 / 15 Pro / 16 / 16e
            2622,   // 16 Pro / 17 / 17 Pro
            2796,   // 14 Pro Max / 15 Plus / 15 Pro Max / 16 Plus
            2868,   // 16 Pro Max / 17 Pro Max
        };
        NSInteger subType = NUArtworkSubType();
        for (size_t i = 0; i < sizeof(islandSubTypes) / sizeof(*islandSubTypes); i++)
            if (subType == islandSubTypes[i]) { hasIsland = YES; return; }

        UIScreen *screen = UIScreen.mainScreen;
        if ([screen respondsToSelector:@selector(_exclusionArea)]) {
            id<NUDisplayInfoRectShape> cutout = [screen _exclusionArea];
            if (!cutout) return;                                    // no cutout → no island
            if ([cutout respondsToSelector:@selector(rect)]) {
                hasIsland = [cutout rect].origin.y > 0.0;
                return;
            }
        }
        hasIsland = (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone);
    });
    return hasIsland;
}

// The lock-screen volume row only has an implementation on iOS 16 and 17 — the versions
// whose lock-screen player is the MRUNowPlayingView that Control Center shares. iOS 14/15
// host that player in-process behind CSMediaControlsViewController and iOS 18 replaced it
// with MRULockscreenView, so on those the switches would be dead controls. Hide them
// rather than ship a toggle that does nothing. (Keep in step with NUVolumeOSSupported()
// in NUVolumeControls.m — the two answer the same question on either side of the deb.)
static BOOL NUVolumeRowSupported(void) {
    NSInteger major = NSProcessInfo.processInfo.operatingSystemVersion.majorVersion;
    return major >= 16 && major <= 17;
}

// Fetch an app's icon and mask it to the classic Settings app-icon look (~29pt squircle).
// Returns nil if the artwork can't be produced, in which case the row just stays text-only.
static UIImage *NUAppIconImage(NSString *bundleID) {
    if (!bundleID) return nil;
    if (![UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:scale:)])
        return nil;

    CGFloat scale = UIScreen.mainScreen.scale;
    UIImage *raw = nil;
    // Variant 2 is the home-screen-sized (best quality) artwork; fall down the variants in
    // case a given iOS doesn't vend it, and downscale to the cell size for a crisp result.
    for (int variant = 2; variant >= 0 && !raw; variant--)
        raw = [UIImage _applicationIconImageForBundleIdentifier:bundleID format:variant scale:scale];
    if (!raw) return nil;

    CGFloat side = 29.0;   // classic Settings icon point size
    CGRect rect = CGRectMake(0, 0, side, side);
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:rect.size];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        // 0.2237 · side ≈ the iOS icon corner radius; a plain rounded rect is indistinguishable
        // from the true squircle at this size.
        [[UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:side * 0.2237] addClip];
        [raw drawInRect:rect];
    }];
}

@interface NUPrefsRootListController () <LSApplicationWorkspaceObserverProtocol> {
    NSString *_installedSignature;   // NUInstalledSignature() as of the last specifier build
}
@end

@implementation NUPrefsRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSArray *loaded = [self loadSpecifiersFromPlistName:@"Root" target:self];
        // Keep every row except the toggle of an app that isn't installed and the Dynamic
        // Island row on a device without one; give the surviving app rows their real icon.
        // Built once (the guard above keeps it from re-running until -reloadSpecifiers clears
        // the cache on an install/uninstall).
        NSMutableArray *kept = [NSMutableArray arrayWithCapacity:loaded.count];
        for (PSSpecifier *spec in loaded) {
            NSString *key = [spec propertyForKey:@"key"];
            if ([key isEqualToString:@"showDynamicIsland"] && !NUDeviceHasDynamicIsland())
                continue;                                          // no island → no toggle
            if ([key isEqualToString:@"showVolumeSlider"] && !NUVolumeRowSupported())
                continue;                                          // unimplemented on this iOS
            NSString *bundleID = NUBundleIDForKey(key);
            if (bundleID && !NUAppInstalled(bundleID)) continue;   // app not on device → drop it
            UIImage *icon = NUAppIconImage(bundleID);
            if (icon) [spec setProperty:icon forKey:@"iconImage"];
            [kept addObject:spec];
        }
        // If dropping apps emptied a section, remove its now-dangling header (a group cell with
        // no rows before the next group / end of list). Music + Podcasts are normally present so
        // the Apps group survives, but both are user-removable on iOS 14+, so handle it.
        for (NSInteger i = (NSInteger)kept.count - 1; i >= 0; i--) {
            if (((PSSpecifier *)kept[i]).cellType != PSGroupCell) continue;
            // A group cell that exists purely to carry explanatory footer text under the
            // LAST row is legitimate and must survive — it has no rows of its own by
            // design. Only a header whose section was emptied by the filtering above is
            // dangling, and that one is always followed by another group cell.
            if (i == (NSInteger)kept.count - 1
                && [(PSSpecifier *)kept[i] propertyForKey:@"footerText"]
                && ![(PSSpecifier *)kept[i] name]) continue;
            BOOL hasRows = (i + 1 < (NSInteger)kept.count) &&
                           ((PSSpecifier *)kept[i + 1]).cellType != PSGroupCell;
            if (!hasRows) [kept removeObjectAtIndex:i];
        }
        _specifiers = kept;
        _installedSignature = NUInstalledSignature();   // baseline for live change detection
    }
    return _specifiers;
}

// Observe app installs/uninstalls so the list updates live (e.g. installing YouTube Music from
// the App Store makes its toggle appear here without reopening the pane). addObserver: doesn't
// retain us, so -dealloc still runs and unregisters.
- (void)viewDidLoad {
    [super viewDidLoad];
    Class ws = NSClassFromString(@"LSApplicationWorkspace");
    if (ws) [[ws defaultWorkspace] addObserver:self];
}

- (void)dealloc {
    Class ws = NSClassFromString(@"LSApplicationWorkspace");
    if (ws) [[ws defaultWorkspace] removeObserver:self];
}

// Safety net for the common flow "leave to the App Store, install, come back": while
// Preferences is backgrounded its workspace callback can be deferred or dropped, so re-check
// on the way back in. Guarded on _specifiers so the very first appearance (pane not built
// yet) falls through to the normal lazy build instead of rebuilding twice.
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (_specifiers) [self _nuReloadIfRelevantAppsChanged];
}

// Rebuild the pane only when the install-state of one of OUR apps actually flipped — an
// unrelated app's install/uninstall leaves the signature unchanged and is ignored.
- (void)_nuReloadIfRelevantAppsChanged {
    NSString *now = NUInstalledSignature();
    if ([now isEqualToString:_installedSignature]) return;
    _installedSignature = now;
    _specifiers = nil;              // drop the cache so -specifiers re-runs the detection
    [self reloadSpecifiers];        // re-reads specifiers and reloads the table
}

// Workspace callbacks arrive off the main thread; hop before touching UIKit.
- (void)applicationsDidInstall:(NSArray *)apps {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf _nuReloadIfRelevantAppsChanged]; });
}

- (void)applicationsDidUninstall:(NSArray *)apps {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf _nuReloadIfRelevantAppsChanged]; });
}

// Write the value the normal way (CFPreferences, persisted), then publish the packed
// state token — the token, not CFPreferences, is the live channel (see NUPrefs.h).
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];
    NUPrefsPublishState();
}

#pragma mark - Debug log export

// Where NULogFile.m lands the per-process logs. SpringBoard and MediaRemoteUI — the
// two processes that draw the now-playing UI, so the two that matter for the volume
// row — can both write here. The media apps are container-redirected and write inside
// their own sandboxes instead, which Preferences cannot read; their logs are reachable
// only through Filza.
static NSString * const kNULogDirectory = @"/var/mobile/nu";
static const unsigned long long kNULogExportCap = 256 * 1024;   // keep the share sheet sane

// NULogResolvePath falls back to NSTemporaryDirectory() wherever /var/mobile/nu is not
// writable, which is every sandboxed process — the libSandy profile grants mach
// extensions only, no file access. So look in the plausible fallbacks too, and say
// which directories were searched so an empty result is not ambiguous.
static NSArray<NSString *> *NULogSearchDirectories(void) {
    return @[ kNULogDirectory, @"/var/tmp", @"/tmp", NSTemporaryDirectory() ?: @"/tmp" ];
}

// Crash reports. Collected automatically because the interesting ones belong to the
// media apps, whose own logs are sealed inside their containers — the crash report is
// the only view we get into a process that dies before it can write anything.
static NSString * const kNUCrashDirectory = @"/var/mobile/Library/Logs/CrashReporter";
static const NSInteger kNUCrashReportsToInclude = 4;
static const NSInteger kNUCrashHeadLines = 90;   // exception type + termination reason + first frames

static NSArray<NSString *> *NUCrashReportPrefixes(void) {
    return @[ @"Music", @"Podcasts", @"Spotify", @"YouTubeMusic",
              @"MediaRemoteUI", @"SpringBoard", @"Preferences" ];
}

// Every switch in the pane, so the export states what the tweak was actually
// configured to do rather than making it a question in the bug report.
static NSArray<NSString *> *NUAllPrefKeys(void) {
    return @[ @"Enabled", @"enabledMusic", @"enabledPodcasts", @"enabledYouTubeMusic",
              @"enabledSpotify", @"showLockScreen", @"showDynamicIsland",
              @"showControlCenter", @"showVolumeSlider", @"skipProviders" ];
}

- (NSString *)_nuBuildLogReport {
    NSMutableString *out = [NSMutableString string];
    NSProcessInfo *info = NSProcessInfo.processInfo;
    [out appendString:@"NextUp 3 — debug log export\n"];
    [out appendFormat:@"Exported: %@\n", [NSDate date]];
    [out appendFormat:@"iOS: %@\n", info.operatingSystemVersionString];
    [out appendFormat:@"Device: %@ (%@)\n", UIDevice.currentDevice.model,
                      UIDevice.currentDevice.systemVersion];
    [out appendFormat:@"Dynamic Island: %@\n", NUDeviceHasDynamicIsland() ? @"yes" : @"no"];
    [out appendFormat:@"Volume row supported on this iOS: %@\n\n",
                      NUVolumeRowSupported() ? @"yes" : @"no"];

    [out appendString:@"Settings\n"];
    for (NSString *key in NUAllPrefKeys()) {
        // Defaults here only matter for a key never written; the two volume keys
        // default off, everything else on — same as Root.plist.
        BOOL def = ![key isEqualToString:@"showVolumeSlider"]
                && ![key isEqualToString:@"skipProviders"];
        [out appendFormat:@"  %-22@ %@\n", key, NUPrefBool(key, def) ? @"on" : @"off"];
    }
    [out appendString:@"\n"];

    NSFileManager *fm = NSFileManager.defaultManager;
    NSInteger found = 0;
    [out appendString:@"Searched for logs in:\n"];
    for (NSString *dir in NULogSearchDirectories()) [out appendFormat:@"  %@\n", dir];
    [out appendString:@"\n"];

    for (NSString *dir in NULogSearchDirectories()) {
        NSArray<NSString *> *names = [[fm contentsOfDirectoryAtPath:dir error:NULL]
                                      sortedArrayUsingSelector:@selector(compare:)];
        for (NSString *name in names) {
            if (![name hasPrefix:@"nextup3-"] || ![name hasSuffix:@".log"]) continue;
            NSString *path = [dir stringByAppendingPathComponent:name];
            unsigned long long size = [[fm attributesOfItemAtPath:path error:NULL] fileSize];
            [out appendFormat:@"===== %@ (%llu bytes) =====\n", path, size];
            NSString *body = [NSString stringWithContentsOfFile:path
                                                      encoding:NSUTF8StringEncoding error:NULL];
            if (!body) { [out appendString:@"(unreadable)\n\n"]; continue; }
            found++;
            // Keep the tail: the interesting lines are the most recent ones.
            if (body.length > kNULogExportCap) {
                body = [@"...(truncated, showing the tail)...\n"
                        stringByAppendingString:[body substringFromIndex:body.length - kNULogExportCap]];
            }
            [out appendString:body];
            if (![body hasSuffix:@"\n"]) [out appendString:@"\n"];
            [out appendString:@"\n"];
        }
    }
    if (found == 0) {
        [out appendString:@"No nextup3-*.log files were readable from Preferences.\n\n"
             @"Two reasons this happens. The file log only exists in a DEBUG build —\n"
             @"the release (FINALPACKAGE) deb compiles NULog out entirely. And the\n"
             @"sandboxed processes (the media apps, and MediaRemoteUI, which draws the\n"
             @"Lock Screen player) fall back to their own container's tmp, which\n"
             @"Preferences cannot read; find those with a Filza search for nextup3-.\n\n"];
    }

    [self _nuAppendCrashReports:out];
    return out;
}

// Newest first, our processes only, header + first frames of each. That top section is
// what distinguishes a load-time rejection (a CODESIGNING / DYLD termination reason,
// with no frames of ours) from executing code that faulted (a real backtrace naming
// NextUp3.dylib).
- (void)_nuAppendCrashReports:(NSMutableString *)out {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSString *> *names = [fm contentsOfDirectoryAtPath:kNUCrashDirectory error:NULL];
    if (!names) {
        [out appendFormat:@"\n===== crash reports =====\nCould not read %@.\n", kNUCrashDirectory];
        return;
    }

    NSMutableArray<NSString *> *ours = [NSMutableArray array];
    for (NSString *name in names) {
        if (![name.pathExtension isEqualToString:@"ips"]) continue;
        for (NSString *prefix in NUCrashReportPrefixes()) {
            if ([name hasPrefix:prefix]) { [ours addObject:name]; break; }
        }
    }
    // Filenames carry the timestamp, so a plain descending sort is newest-first.
    [ours sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) { return [b compare:a]; }];

    [out appendFormat:@"\n===== crash reports (%ld matching, newest %ld shown) =====\n",
                      (long)ours.count, (long)MIN((NSInteger)ours.count, kNUCrashReportsToInclude)];
    NSInteger shown = 0;
    for (NSString *name in ours) {
        if (shown >= kNUCrashReportsToInclude) break;
        NSString *path = [kNUCrashDirectory stringByAppendingPathComponent:name];
        NSString *body = [NSString stringWithContentsOfFile:path
                                                  encoding:NSUTF8StringEncoding error:NULL];
        if (!body) continue;
        shown++;
        [out appendFormat:@"\n----- %@ -----\n", name];
        NSArray<NSString *> *lines = [body componentsSeparatedByString:@"\n"];
        NSInteger limit = MIN((NSInteger)lines.count, kNUCrashHeadLines);
        for (NSInteger i = 0; i < limit; i++) [out appendFormat:@"%@\n", lines[i]];
        if ((NSInteger)lines.count > limit)
            [out appendFormat:@"...(%ld more lines)...\n", (long)((NSInteger)lines.count - limit)];
    }
    if (shown == 0) [out appendString:@"None found for our processes.\n"];
}

// Writes the combined report into Preferences' own tmp (always writable, no matter
// what the log directory's permissions are) and hands it to the share sheet, so it
// can go to Files, Mail, AirDrop or anywhere else.
- (void)exportLog:(PSSpecifier *)specifier {
    NSString *report = [self _nuBuildLogReport];
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"nextup3-debug.txt"];
    NSError *err = nil;
    if (![report writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&err]) {
        [self _nuAlert:@"Export failed" message:err.localizedDescription ?: @"Could not write the file."];
        return;
    }
    UIActivityViewController *share =
        [[UIActivityViewController alloc] initWithActivityItems:@[ [NSURL fileURLWithPath:path] ]
                                         applicationActivities:nil];
    // iPad presents this as a popover and throws without an anchor.
    share.popoverPresentationController.sourceView = self.view;
    share.popoverPresentationController.sourceRect =
        CGRectMake(self.view.bounds.size.width / 2.0, self.view.bounds.size.height / 2.0, 1, 1);
    [self presentViewController:share animated:YES completion:nil];
}

- (void)clearLog:(PSSpecifier *)specifier {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSInteger removed = 0;
    for (NSString *name in [fm contentsOfDirectoryAtPath:kNULogDirectory error:NULL]) {
        if (![name hasSuffix:@".log"]) continue;
        if ([fm removeItemAtPath:[kNULogDirectory stringByAppendingPathComponent:name] error:NULL])
            removed++;
    }
    [self _nuAlert:@"Debug log cleared"
           message:[NSString stringWithFormat:@"Removed %ld log file(s). Reproduce the problem, "
                                              @"then export.", (long)removed]];
}

- (void)_nuAlert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                  message:message
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
