# Research-only tweak: runtime class-dump of the Auto-Lock controller.
# Injects into Settings, dumps DBSAutoLockViewController via the ObjC runtime.
TARGET := iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = Preferences
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DBSDump
DBSDump_FILES = Tweak.x
DBSDump_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
