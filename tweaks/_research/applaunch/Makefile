TARGET := iphone:clang:latest:14.0
ARCHS = arm64
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TOOL_NAME = applaunch
applaunch_FILES = main.m
applaunch_FRAMEWORKS = Foundation CoreFoundation
applaunch_CFLAGS = -fobjc-arc
applaunch_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/tool.mk
