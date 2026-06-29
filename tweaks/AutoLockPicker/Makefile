TARGET := iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = Preferences
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AutoLockPicker

AutoLockPicker_FILES = Tweak.x
AutoLockPicker_CFLAGS = -fobjc-arc
AutoLockPicker_FRAMEWORKS = UIKit

include $(THEOS_MAKE_PATH)/tweak.mk
