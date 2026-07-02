TARGET := iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = SpringBoard Preferences
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = PullToRespring2

PullToRespring2_FILES = Tweak.xm
PullToRespring2_CFLAGS = -fobjc-arc
PullToRespring2_FRAMEWORKS = UIKit

include $(THEOS_MAKE_PATH)/tweak.mk
