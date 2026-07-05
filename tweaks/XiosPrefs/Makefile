TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = XiosPrefs
XiosPrefs_FILES = XiosRootListController.m
XiosPrefs_INSTALL_PATH = /Library/PreferenceBundles
XiosPrefs_FRAMEWORKS = UIKit
XiosPrefs_CFLAGS = -fobjc-arc
XiosPrefs_LDFLAGS = -undefined dynamic_lookup

include $(THEOS_MAKE_PATH)/bundle.mk
