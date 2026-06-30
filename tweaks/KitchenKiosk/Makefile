TARGET := iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = SpringBoard
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = KitchenKiosk
KitchenKiosk_FILES = Tweak.x
KitchenKiosk_CFLAGS = -fobjc-arc
KitchenKiosk_FRAMEWORKS = Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
