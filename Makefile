# The three variants differ only in deployment target and package scheme; hooks
# are gated at runtime (NUIOSMajor()), so the sources are identical in all three.
ifeq ($(ROOTFUL),1)
# Classic jailbreak (libhooker). No package scheme — Theos then emits iphoneos-arm.
export TARGET := iphone:clang:latest:14.2
export ARCHS  := arm64 arm64e
else ifeq ($(ROOTLESS),1)
# palera1n / Dopamine Procursus bootstrap, ElleKit.
export TARGET := iphone:clang:latest:15.0
export ARCHS  := arm64 arm64e
export THEOS_PACKAGE_SCHEME := rootless
else
export TARGET := iphone:clang:latest:15.0
export ARCHS  := arm64 arm64e
export THEOS_PACKAGE_SCHEME := roothide
endif

INSTALL_TARGET_PROCESSES = MediaRemoteUI Music Podcasts SpringBoard YouTubeMusic Spotify

include $(THEOS)/makefiles/common.mk

# arm64e: clang signs the class_ro pointer of every Objective-C class, and the
# libobjc that reads it back does not always authenticate that slot. When it does not,
# the injected process dies the instant dyld maps this dylib — inside
# libobjc's readClass(), EXC_BAD_ACCESS / SIGBUS, ESR "Address size fault", with x0
# holding one of our classes. Verified on iPhone14,5 @ iOS 17.0: every media app died
# that way, four identical reports, x0 = OBJC_CLASS_$_NUProviderBase.
#
# This probe used to run $(TARGET_CC) BARE. That is only correct on macOS, where the
# compiler's default target is already an Apple one. On a Linux Theos host the default
# target is the build machine, the flag is rejected there, the probe silently yields
# nothing — and the signing is emitted for the real arm64e compile anyway. A dylib that
# kills every process it is injected into, produced without one warning.
#
# So: probe with a real Apple triple, and treat an unsupported flag as a BUILD FAILURE
# rather than a silent omission. NU_ALLOW_SIGNED_CLASS_RO=1 overrides, for a toolchain
# that rejects the flag and a runtime known to authenticate the slot properly.
NU_PTRAUTH_FLAG := -fno-ptrauth-objc-class-ro
NU_PTRAUTH_SUPPORTED := $(shell $(TARGET_CC) -target arm64e-apple-ios15.0 -x objective-c \
	-fsyntax-only $(NU_PTRAUTH_FLAG) /dev/null >/dev/null 2>&1 && echo yes)

# The three safe outcomes all print "ptrauth-safe", which is what CI asserts on. The
# override branch deliberately does not.
ifeq ($(NU_PTRAUTH_SUPPORTED),yes)
NU_PTRAUTH_CFLAGS := $(NU_PTRAUTH_FLAG)
$(info NextUp3: ptrauth-safe: class_ro signing disabled via $(NU_PTRAUTH_FLAG) [ARCHS=$(ARCHS)])
else ifeq ($(filter arm64e,$(ARCHS)),)
# No arm64e slice, so nothing signs a class_ro and the flag is moot.
NU_PTRAUTH_CFLAGS :=
$(info NextUp3: ptrauth-safe: no arm64e slice, nothing to disable [ARCHS=$(ARCHS)])
else ifeq ($(NU_ALLOW_SIGNED_CLASS_RO),1)
NU_PTRAUTH_CFLAGS :=
$(warning NextUp3: class_ro signing left ENABLED by NU_ALLOW_SIGNED_CLASS_RO=1 — expect \
every injected process to die in libobjc readClass() unless this runtime authenticates \
that slot.)
else
$(error $(NU_PTRAUTH_FLAG) is not accepted by $(TARGET_CC), but arm64e is in ARCHS. \
Building anyway emits signed class_ro pointers and produces a dylib that crashes every \
process it is injected into (verified: iOS 17.0, libobjc readClass, SIGBUS). The Theos \
LINUX toolchain does not have this flag — build on macOS with Xcode's clang, which does, \
or pass ARCHS=arm64 to ship an arm64-only slice. NU_ALLOW_SIGNED_CLASS_RO=1 forces it.)
endif

export NU_PTRAUTH_CFLAGS

TWEAK_NAME = NextUp3
NextUp3_FILES = \
	hooks/NUHooksMusicProvider.x \
	hooks/NUHooksPodcastProvider.x \
	hooks/NUHooksYouTubeMusicProvider.x \
	hooks/NUHooksSpotifyProvider.x \
	hooks/NUHooksNowPlaying.x \
	hooks/NUHooksControlCenterLegacy.x \
	hooks/NUHooksControlCenter18.x \
	hooks/NUHooksControlCenter26.x \
	hooks/NUHooksDynamicIsland17.x \
	hooks/NUHooksDynamicIsland16.x \
	hooks/NUHooksSpringBoard.x \
	hooks/NUHooksLockScreen15.x \
	hooks/NUHooksLockScreen14.x \
	hooks/NUHooksLockScreen18.x \
	hooks/NUHooksTCC.x \
	NUHooksShared.m NULogFile.m NUProviderBase.m NUMusicProvider.m NUPodcastProvider.m NUYouTubeMusicProvider.m NUSpotifyProvider.m NUNextUpManager.m NUNextUpRowView.m NUVolumeControls.m NUPrefs.m
# LIGHTMESSAGING_TIMEOUT (ms) bounds the sync mach round-trip in
# LMConnectionSendTwoWay. Without it the display's main-thread query blocks
# forever against a suspended app, whose runloop never services the port, and
# SpringBoard hangs until the watchdog resprings.
NextUp3_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Ivendor/LightMessaging -DLIGHTMESSAGING_USE_ROCKETBOOTSTRAP=0 -DLIGHTMESSAGING_TIMEOUT=250 $(NU_PTRAUTH_CFLAGS)
NextUp3_FRAMEWORKS = UIKit CoreGraphics QuartzCore ImageIO

include $(THEOS_MAKE_PATH)/tweak.mk

# Settings pane; inherits TARGET and the package scheme from the variant block.
SUBPROJECTS += prefs
include $(THEOS_MAKE_PATH)/aggregate.mk
