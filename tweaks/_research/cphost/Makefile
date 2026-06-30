TARGET := iphone:clang:latest:14.0
ARCHS = arm64
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TOOL_NAME = cphost
cphost_FILES = main.m
cphost_FRAMEWORKS = Foundation CoreFoundation
cphost_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tool.mk
