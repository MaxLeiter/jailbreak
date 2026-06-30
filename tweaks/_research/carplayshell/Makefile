TARGET := iphone:clang:latest:14.0
ARCHS = arm64
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = carplayshell
carplayshell_FILES = main.m AppDelegate.m RootViewController.m
carplayshell_FRAMEWORKS = UIKit CoreGraphics QuartzCore
carplayshell_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
carplayshell_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/application.mk
