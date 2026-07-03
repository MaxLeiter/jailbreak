TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = JarvisPrefs
JarvisPrefs_FILES = JarvisRootListController.m
JarvisPrefs_INSTALL_PATH = /Library/PreferenceBundles
JarvisPrefs_FRAMEWORKS = UIKit
JarvisPrefs_CFLAGS = -fobjc-arc
JarvisPrefs_LDFLAGS = -undefined dynamic_lookup

include $(THEOS_MAKE_PATH)/bundle.mk
