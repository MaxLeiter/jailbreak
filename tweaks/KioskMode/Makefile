TARGET := iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = SpringBoard
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = KioskMode
KioskMode_FILES = Tweak.x
KioskMode_CFLAGS = -fobjc-arc
KioskMode_FRAMEWORKS = Foundation AudioToolbox

include $(THEOS_MAKE_PATH)/tweak.mk
