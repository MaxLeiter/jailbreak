TARGET := iphone:clang:latest:14.0
ARCHS = arm64
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TOOL_NAME = cpprobe
cpprobe_FILES = main.m
cpprobe_FRAMEWORKS = UIKit Foundation
cpprobe_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
cpprobe_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/tool.mk
