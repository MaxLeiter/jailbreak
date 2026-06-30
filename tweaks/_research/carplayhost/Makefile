TARGET := iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = SpringBoard
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk
TWEAK_NAME = carplayhost
carplayhost_FILES = Tweak.xm
carplayhost_CFLAGS = -fobjc-arc
carplayhost_FRAMEWORKS = UIKit IOSurface CoreGraphics QuartzCore
include $(THEOS_MAKE_PATH)/tweak.mk
