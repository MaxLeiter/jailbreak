TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = MosaicPrefs
MosaicPrefs_FILES = MosaicRootListController.m
MosaicPrefs_INSTALL_PATH = /Library/PreferenceBundles
MosaicPrefs_FRAMEWORKS = UIKit
MosaicPrefs_CFLAGS = -fobjc-arc
# PSListController is provided by Preferences.app at load time → resolve it dynamically
# rather than linking the private framework stub (not on the default search path here).
MosaicPrefs_LDFLAGS = -undefined dynamic_lookup

include $(THEOS_MAKE_PATH)/bundle.mk
