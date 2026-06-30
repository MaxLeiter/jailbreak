TARGET := iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = SpringBoard
THEOS_PACKAGE_SCHEME = rootless
include $(THEOS)/makefiles/common.mk
TWEAK_NAME = injtest
injtest_FILES = Tweak.x
injtest_CFLAGS = -fobjc-arc
include $(THEOS_MAKE_PATH)/tweak.mk
