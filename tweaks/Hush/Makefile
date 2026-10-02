TARGET := iphone:clang:latest:15.0
# Deliberately empty: installing Hush must not restart wifid or UserEventAgent.
# Both modules take effect the next time their daemon starts.
INSTALL_TARGET_PROCESSES =
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = HushBFUWake HushWiFiScan

# Module 1: UserEventAgent. Plain C, no ObjC.
HushBFUWake_FILES = HushBFUWake.c
HushBFUWake_FRAMEWORKS = CoreFoundation

# Module 2: wifid.
HushWiFiScan_FILES = HushWiFiScan.x
HushWiFiScan_CFLAGS = -fobjc-arc
HushWiFiScan_FRAMEWORKS = Foundation CoreFoundation

include $(THEOS_MAKE_PATH)/tweak.mk
