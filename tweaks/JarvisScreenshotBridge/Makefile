TARGET := iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = SpringBoard
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = JarvisScreenshotBridge

JarvisScreenshotBridge_FILES = Tweak.xm
JarvisScreenshotBridge_CFLAGS = -fobjc-arc
JarvisScreenshotBridge_FRAMEWORKS = UIKit CoreGraphics ImageIO MobileCoreServices AVFoundation

include $(THEOS_MAKE_PATH)/tweak.mk
