ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# Shared Apple/Darwin flags for the Qt 6 module cross builds (qtshadertools, qtdeclarative,
# qtwayland, qtsvg, qtimageformats); qtbase.mk documents the WHY of each flag. Variables
# use recursive (=) assignment so include order never matters.

QT6_VERSION = 6.6.3
QT6_MINOR   = 6.6

# Host Qt tree (build-qt.sh stage 1 + build-qt-modules.sh stage 1). Same prefix as
# qtbase.mk's QT_HOST_PATH; distinct name to avoid cross-recipe variable collisions.
QT6_HOST_PATH = $(BUILD_TOOLS)/host-qt-$(QT6_VERSION)

# $(call QT6_MODULE_URL,qtsvg) -> official 6.6.3 submodule tarball URL.
# EXTRACT_TAR silently skips extraction when build_work/<name> already exists — on a
# version bump, rm -rf the build_work tree first or you rebuild a stale tree.
QT6_MODULE_URL = https://download.qt.io/archive/qt/$(QT6_MINOR)/$(QT6_VERSION)/submodules/$(1)-everywhere-src-$(QT6_VERSION).tar.xz

# build_base's staged stdlib.h/unistd.h force-include libiosexec.h, whose `#define system
# ie_system` mangles C++ members named system() (QRandomGenerator64::system,
# QLocale::system) — qtdeclarative hits both. This fixup is force-included in every
# C++/ObjC++ TU (see CMAKE_CXX/OBJCXX in QT6_MODULE_CMAKE_FLAGS below): C TUs keep the
# full interposition, C++ TUs keep the exec* reroute (QProcess needs it) but drop the
# `system` macro. Usage in a -setup recipe: $(call QT6_WRITE_IOSEXEC_FIXUP)
# The `\#` escapes are mandatory: an unescaped `#` inside a make variable value starts a
# comment; \# expands to a literal # that the recipe shell then sees.
QT6_IOSEXEC_FIXUP_H = $(BUILD_TOOLS)/qt-ios-iosexec-fixup.h
QT6_WRITE_IOSEXEC_FIXUP = \
	printf '%s\n' \
		'\#include <stdlib.h>' \
		'\#include <unistd.h>' \
		'\#ifdef __cplusplus' \
		'\#ifdef __APPLE__' \
		'\#include <_xlocale.h>' \
		'\#include <xlocale/_stdlib.h>' \
		'\#endif' \
		'\#undef system' \
		'\#endif' > $(QT6_IOSEXEC_FIXUP_H)

# Each module is an independent cmake project and re-runs the same probing as qtbase.mk,
# so each needs the full flag set. Notable ones beyond the obvious feature flags:
#   - *_LINKER_FLAGS include the iOS stand-in frameworks: ObjC++ sources compile fine but
#     their UIKit/objc link deps hide behind `CONDITION IOS` blocks that are false under
#     the Darwin masquerade — qtdeclarative's QtQuick Controls iOS style (qquickiostheme.mm)
#     died on _OBJC_CLASS_$$_UIColor + _objc_msgSend without -lobjc.
QT6_IOS_FRAMEWORKS = -framework UIKit -framework CoreServices -framework MobileCoreServices -framework Security -lobjc
QT6_MODULE_CMAKE_FLAGS = \
	$(DEFAULT_CMAKE_FLAGS) \
	-DCMAKE_SHARED_LINKER_FLAGS="$(LDFLAGS) $(QT6_IOS_FRAMEWORKS)" \
	-DCMAKE_MODULE_LINKER_FLAGS="$(LDFLAGS) $(QT6_IOS_FRAMEWORKS)" \
	-DCMAKE_EXE_LINKER_FLAGS="$(LDFLAGS) $(QT6_IOS_FRAMEWORKS)" \
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

# Staged libxpc/os_log headers shadow the 16.4 SDK (see qtbase.mk step 4). Procursus
# `setup` re-stages both on every make, so every module -setup must call this — a
# driver-level cleanup gets undone by the next module's make (qtdeclarative's
# qsgrhisupport_mac.mm proved it). Idempotent. Usage: $(call QT6_RM_SHADOW_HEADERS)
QT6_RM_SHADOW_HEADERS = \
	rm -rf $(BUILD_BASE)$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/xpc; \
	rm -f $(BUILD_BASE)$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/os/log.h

# The core Darwin-vs-iOS fix from qtbase.mk, as a callable for module source trees: disable
# `CONDITION MACOS` blocks only (APPLE/UIKIT/NOT MACOS stay untouched; `MACOS([^X])` spares
# MACOSX). Usage: $(call QT6_DISABLE_MACOS_CONDITIONS,<build_work dir name>)
QT6_DISABLE_MACOS_CONDITIONS = \
	find $(BUILD_WORK)/$(1)/src -name CMakeLists.txt -exec \
		sed -i -E 's/CONDITION MACOS([^X])/CONDITION MACOS AND FALSE\1/g; s/CONDITION MACOS$$/CONDITION MACOS AND FALSE/' {} +
