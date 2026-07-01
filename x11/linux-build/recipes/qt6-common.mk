ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# qt6-common.mk — shared definitions for the Qt 6 MODULE cross builds (qtshadertools,
# qtdeclarative, qtwayland, qtsvg, qtimageformats). qtbase.mk documents the WHY of every
# Apple/Darwin flag; this file only factors those flags out so the module recipes stay in
# sync. All variables use recursive (=) assignment so include order (main Makefile's
# `include makefiles/*.mk` glob) never matters.
#
# A Qt 6 module cross build = HOST tools (moc/rcc/syncqt from qtbase, plus per-module host
# tools: qsb from qtshadertools, qmlcachegen/qmltyperegistrar for QML, qtwaylandscanner)
# resolved through QT_HOST_PATH, + TARGET libs/cmake-packages of the modules lower in the
# ladder, found in build_base (each recipe's AFTER_BUILD copy stages its install there,
# where CMAKE_FIND_ROOT_PATH picks it up). build-qt-modules.sh stage 1 extends the host Qt
# with qtshadertools/qtdeclarative/qtwayland so the per-module host tools exist.

QT6_VERSION = 6.6.3
QT6_MINOR   = 6.6

# Host Qt tree (build-qt.sh stage 1 + build-qt-modules.sh stage 1). Same prefix as
# qtbase.mk's QT_HOST_PATH; distinct name to avoid cross-recipe variable collisions.
QT6_HOST_PATH = $(BUILD_TOOLS)/host-qt-$(QT6_VERSION)

# $(call QT6_MODULE_URL,qtsvg) -> official 6.6.3 submodule tarball URL.
QT6_MODULE_URL = https://download.qt.io/archive/qt/$(QT6_MINOR)/$(QT6_VERSION)/submodules/$(1)-everywhere-src-$(QT6_VERSION).tar.xz

# Everything a module's cmake invocation needs beyond its own feature flags. Recap of the
# qtbase.mk gotchas (each module is an independent cmake project and re-runs the same
# probing, so each needs the full set):
#   - CMAKE_OSX_DEPLOYMENT_TARGET defined-but-EMPTY: skip both -mmacosx-version-min (clang
#     rejects it next to the -miphoneos-version-min already in CFLAGS) and Qt's default.
#   - QT_NO_APPLE_SDK_AND_XCODE_CHECK + the two QT_INTERNAL_* seeds: Qt's SDK probing would
#     exec the hardcoded /usr/bin/xcrun, absent on the Linux host (sysroot is iPhoneOS 16.4).
#   - CMAKE_OBJC(XX)_FLAGS: qtbase enables OBJC/OBJCXX on Apple and DEFAULT_CMAKE_FLAGS only
#     covers C/CXX; without these, .mm compiles miss the libc++ -isystem paths.
#   - QT_HOST_PATH(+_CMAKE_DIR): where find_package(Qt6 ... ) resolves host *Tools packages.
QT6_MODULE_CMAKE_FLAGS = \
	$(DEFAULT_CMAKE_FLAGS) \
	-DCMAKE_OSX_DEPLOYMENT_TARGET= \
	-DQT_NO_APPLE_SDK_AND_XCODE_CHECK=ON \
	-DQT_INTERNAL_APPLE_SDK_VERSION=16.4 \
	-DQT_INTERNAL_XCODE_VERSION=15.0 \
	-DCMAKE_OBJC_FLAGS="$(CFLAGS)" \
	-DCMAKE_OBJCXX_FLAGS="$(CXXFLAGS)" \
	-DQT_HOST_PATH=$(QT6_HOST_PATH) \
	-DQT_HOST_PATH_CMAKE_DIR=$(QT6_HOST_PATH)/lib/cmake \
	-DBUILD_SHARED_LIBS=ON \
	-DQT_BUILD_EXAMPLES=OFF \
	-DQT_BUILD_TESTS=OFF \
	-DQT_BUILD_BENCHMARKS=OFF

# THE core Darwin-vs-iOS fix from qtbase.mk, as a callable for module source trees:
# CMAKE_SYSTEM_NAME=Darwin makes Qt's cmake set MACOS=1, so `CONDITION MACOS` blocks would
# link macOS-only frameworks (AppKit et al) / compile macOS-desktop-only sources, while the
# COMPILER already targets iPhoneOS (TARGET_OS_IPHONE -> every .cpp/.mm takes its Q_OS_IOS
# path). Disable exactly the MACOS conditions; APPLE / UIKIT / NOT MACOS stay untouched
# (`MACOS([^X])` spares MACOSX; left-to-right evaluation keeps mixed conditions correct).
# Usage: $(call QT6_DISABLE_MACOS_CONDITIONS,<build_work dir name>)
QT6_DISABLE_MACOS_CONDITIONS = \
	find $(BUILD_WORK)/$(1)/src -name CMakeLists.txt -exec \
		sed -i -E 's/CONDITION MACOS([^X])/CONDITION MACOS AND FALSE\1/g; s/CONDITION MACOS$$/CONDITION MACOS AND FALSE/' {} +
