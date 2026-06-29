# --- Build target -----------------------------------------------------------
# iphone:clang:<sdk>:<min-ios>
#   latest = use the newest SDK installed in $THEOS/sdks (currently 16.5)
#   15.0   = minimum iOS we deploy to (rootless requires iOS 15+; iPad is 17.6.1)
TARGET := iphone:clang:latest:15.0

# Restart these processes automatically after `make install`.
INSTALL_TARGET_PROCESSES = SpringBoard

# palera1n (iOS 16+) is a ROOTLESS jailbreak: install under /var/jb, arch
# iphoneos-arm64. This one line makes Theos do all the rootless rewiring.
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = HelloWorld

HelloWorld_FILES = Tweak.x
HelloWorld_CFLAGS = -fobjc-arc          # use ARC so we don't hand-manage memory
# (no extra frameworks needed — NSLog is in Foundation, linked by default)

include $(THEOS_MAKE_PATH)/tweak.mk
