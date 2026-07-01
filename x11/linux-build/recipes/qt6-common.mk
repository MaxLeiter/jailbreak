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
# NOTE (qtbase attempt-1 lesson): EXTRACT_TAR silently SKIPS extraction when
# build_work/<name> already exists — on any version bump, rm -rf the build_work tree
# first or you rebuild a stale tree.
QT6_MODULE_URL = https://download.qt.io/archive/qt/$(QT6_MINOR)/$(QT6_VERSION)/submodules/$(1)-everywhere-src-$(QT6_VERSION).tar.xz

# libiosexec macro vs C++ members (qtbase.mk fix #3, attempt-3 lesson): build_base's staged
# stdlib.h/unistd.h force-include libiosexec.h, whose `#define system ie_system` mangles
# C++ members named system() (QRandomGenerator64::system, QLocale::system, ...) —
# qtdeclarative hits both. The fixup is force-included in every C++/ObjC++ TU (see the
# CMAKE_CXX/OBJCXX overrides in QT6_MODULE_CMAKE_FLAGS below): C TUs keep the full
# interposition (exec*/posix_spawn/system -> ie_*, -liosexec still links); C++ TUs keep the
# exec* reroute (QProcess wants it) but drop the `system` macro. A C++ call to ::system()
# would then hit the __IOS_PROHIBITED libc declaration and fail loudly at compile time.
# ONE shared header in BUILD_TOOLS (content identical for every module); each module-setup
# (re)writes it, idempotently. Usage in a -setup recipe: $(call QT6_WRITE_IOSEXEC_FIXUP)
# The `\#` escapes are mandatory: an unescaped `#` inside a make VARIABLE value starts a
# comment (qtbase.mk dodges this by inlining the printf in a recipe line, where `#` is
# literal); \# expands to a literal # that the recipe shell then sees.
QT6_IOSEXEC_FIXUP_H = $(BUILD_TOOLS)/qt-ios-iosexec-fixup.h
QT6_WRITE_IOSEXEC_FIXUP = \
	printf '%s\n' \
		'\#include <stdlib.h>' \
		'\#include <unistd.h>' \
		'\#ifdef __cplusplus' \
		'\#undef system' \
		'\#endif' > $(QT6_IOSEXEC_FIXUP_H)

# Everything a module's cmake invocation needs beyond its own feature flags. Recap of the
# qtbase.mk gotchas (each module is an independent cmake project and re-runs the same
# probing, so each needs the full set):
#   - CMAKE_OSX_DEPLOYMENT_TARGET defined-but-EMPTY: skip both -mmacosx-version-min (clang
#     rejects it next to the -miphoneos-version-min already in CFLAGS) and Qt's default.
#   - QT_NO_APPLE_SDK_AND_XCODE_CHECK + the two QT_INTERNAL_* seeds: Qt's SDK probing would
#     exec the hardcoded /usr/bin/xcrun, absent on the Linux host (sysroot is iPhoneOS 16.4).
#   - CMAKE_OBJC(XX)_FLAGS: qtbase enables OBJC/OBJCXX on Apple and DEFAULT_CMAKE_FLAGS only
#     covers C/CXX; without these, .mm compiles miss the libc++ -isystem paths.
#   - CMAKE_CXX/OBJCXX re-passed WITH the iosexec fixup -include: the later -D wins over the
#     plain one inside DEFAULT_CMAKE_FLAGS (same trick qtbase.mk uses).
#   - QT_HOST_PATH(+_CMAKE_DIR): where find_package(Qt6 ... ) resolves host *Tools packages.
QT6_MODULE_CMAKE_FLAGS = \
	$(DEFAULT_CMAKE_FLAGS) \
	-DCMAKE_OSX_DEPLOYMENT_TARGET= \
	-DQT_NO_APPLE_SDK_AND_XCODE_CHECK=ON \
	-DQT_INTERNAL_APPLE_SDK_VERSION=16.4 \
	-DQT_INTERNAL_XCODE_VERSION=15.0 \
	-DCMAKE_OBJC_FLAGS="$(CFLAGS)" \
	-DCMAKE_CXX_FLAGS="$(CXXFLAGS) -include $(QT6_IOSEXEC_FIXUP_H)" \
	-DCMAKE_OBJCXX_FLAGS="$(CXXFLAGS) -include $(QT6_IOSEXEC_FIXUP_H)" \
	-DQT_HOST_PATH=$(QT6_HOST_PATH) \
	-DQT_HOST_PATH_CMAKE_DIR=$(QT6_HOST_PATH)/lib/cmake \
	-DBUILD_SHARED_LIBS=ON \
	-DQT_BUILD_EXAMPLES=OFF \
	-DQT_BUILD_TESTS=OFF \
	-DQT_BUILD_BENCHMARKS=OFF

# Staged libxpc/os_log headers shadow the 16.4 SDK (qtbase.mk step 4: xpc/ is the
# iOS-17-era xpc_session API that dies on OS_OBJECT_DECL_SENDABLE_CLASS from any
# Foundation.h include; os/log.h is a trimmed private copy). Procursus `setup`
# RE-STAGES both on EVERY make, so a driver-level parking is undone by the next
# module's make (qtdeclarative's qsgrhisupport_mac.mm proved it) — every module
# -setup must call this. Idempotent. Usage: $(call QT6_RM_SHADOW_HEADERS)
QT6_RM_SHADOW_HEADERS = \
	rm -rf $(BUILD_BASE)$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/xpc; \
	rm -f $(BUILD_BASE)$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/os/log.h

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
