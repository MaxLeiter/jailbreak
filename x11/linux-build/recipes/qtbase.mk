ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# Deliberately builds Qt's DARWIN (macOS-style) platform, not iOS/UIKit: Qt's official iOS
# port is static + UIKit (QIOSIntegration), but we want dylibs + a headless/Wayland QPA so
# Plasma clients render through iosc/KWin. So this builds the macx-clang platform (shared
# libs OK, no forced UIKit) against the iPhoneOS SDK via the Procursus cctools toolchain.
#   - FEATURE_framework=OFF: Qt on Apple defaults to .framework bundles; we need plain
#     .dylib in /var/jb/usr/lib. Must stay off.
#   - cocoa platform plugin needs AppKit (absent on iOS) -> not built; default QPA = offscreen.
#   - ICU is ON: the libicu-dev_74.2+ios1 repackage adds the missing unicode/*.h headers
#     (original deb had only .pc + symlinks). Do NOT bump to the also-published ICU 78.3 —
#     ICU bakes U_ICU_VERSION_MAJOR_NUM into exported symbols at header-compile-time, so
#     78-headers-over-74-runtime builds clean and fails to resolve on device.
#   - OpenSSL stays OFF (separate, untouched track). GL/EGL is ON via ANGLE/Metal; default
#     QPA stays offscreen so non-Wayland tools don't accidentally require a compositor.
#
# Cross-building qtbase needs moc/rcc/uic/syncqt from a host Qt of the IDENTICAL version via
# QT_HOST_PATH. Target is 6.6.3, which no Debian release ships, so build-qt.sh bootstraps a
# native host qtbase 6.6.3 into build_tools/ once, persisted in the volume.

SUBPROJECTS    += qtbase
QTBASE_VERSION := 6.6.3
QT_MINOR       := 6.6
# dbus is RUNTIME (dlopen), not linked: QtDBus's loader uses QLibrary("dbus-1",3), which on
# a Darwin target deterministically resolves libdbus-1.dylib — the finicky
# WrapDBus1/DBus1Config linked path isn't needed.
# printsupport is ON but its DIALOGS are OFF: QPrintDialog/QPageSetupDialog have no iOS impl
# (qprintdialog_unix.cpp needs CUPS, qprintdialog_mac.mm needs AppKit), so the feature turns
# on but links dead — force printdialog + printpreviewdialog OFF. kxmlgui only wants the
# module for QPrinter, not the picker UI.
DEB_QTBASE_V   ?= $(QTBASE_VERSION)-5+ios1
QTBASE_NINJA_JOBS ?= 4

# Host Qt (QT_HOST_PATH) — built by build-qt.sh stage 1 from the same source tarball.
QT_HOST_PATH      := $(BUILD_TOOLS)/host-qt-$(QTBASE_VERSION)
QT_HOST_CMAKE_DIR := $(QT_HOST_PATH)/lib/cmake

# Staged sysroot prefix — FindATSPI2 synth and other cache seeds point here for the libs
# pkg-config would have located (pkg_config feature is OFF cross).
QT_SYSROOT := $(BUILD_BASE)$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
QT_ANGLE_PREFIX := $(BUILD_BASE)$(MEMO_PREFIX)
QT_ANGLE_INC    := $(QT_ANGLE_PREFIX)/include
QT_ANGLE_LIB    := $(QT_ANGLE_PREFIX)/lib/angle

# iOS stand-ins for the frameworks the disabled CONDITION-MACOS blocks would have linked
# (CoreServices/MobileCoreServices carry UTType*, Security; UIKit for qcore_mac.mm's Q_OS_IOS
# UIApplication refs). Injected into EVERY dylib/plugin/exe link via *_LINKER_FLAGS — they all
# live in the dyld shared cache, so linking them where unused costs nothing.
QTBASE_IOS_FRAMEWORKS := -framework UIKit -framework CoreServices -framework MobileCoreServices -framework Security

qtbase-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.qt.io/archive/qt/$(QT_MINOR)/$(QTBASE_VERSION)/submodules/qtbase-everywhere-src-$(QTBASE_VERSION).tar.xz)
	$(call EXTRACT_TAR,qtbase-everywhere-src-$(QTBASE_VERSION).tar.xz,qtbase-everywhere-src-$(QTBASE_VERSION),qtbase)
	# --- iOS/Darwin portability patches (accreting) ---
	# 1) cocoa platform plugin needs AppKit (absent on iOS) — guard it out.
	if grep -q "add_subdirectory(cocoa)" $(BUILD_WORK)/qtbase/src/plugins/platforms/CMakeLists.txt; then \
		sed -i 's/add_subdirectory(cocoa)/# add_subdirectory(cocoa)  # iOS: no AppKit/' \
			$(BUILD_WORK)/qtbase/src/plugins/platforms/CMakeLists.txt ; \
	fi
	# 2) CMAKE_SYSTEM_NAME=Darwin makes Qt's cmake set MACOS=1 (UIKIT would need
	#    CMAKE_SYSTEM_NAME=="iOS", which the osxcross-style Procursus toolchain can't use), so Qt
	#    tries to link macOS-only frameworks and compile macOS-desktop-only sources even though the
	#    compiler already targets iPhoneOS. Disable exactly the `CONDITION MACOS` blocks across src/
	#    — their CONDITION APPLE siblings (CoreFoundation/CoreGraphics/CoreText/Foundation) stay,
	#    which is the correct iOS framework set. `MACOS([^X])` spares MACOSX/NOT MACOS/UIKIT.
	find $(BUILD_WORK)/qtbase/src -name CMakeLists.txt -exec \
		sed -i -E 's/CONDITION MACOS([^X])/CONDITION MACOS AND FALSE\1/g; s/CONDITION MACOS$$/CONDITION MACOS AND FALSE/' {} +
	# 3) build_base's staged stdlib.h/unistd.h force-include libiosexec.h, whose `#define system
	#    ie_system` mangles C++ members named system() (QRandomGenerator64::system, QLocale::system).
	#    Force-include this fixup in every C++/ObjC++ TU (see CMAKE_(OBJ)CXX_FLAGS below): C TUs keep
	#    the full interposition, C++ TUs keep the exec* reroute (QProcess needs it) but drop the
	#    `system` macro.
	printf '%s\n' \
		'#include <stdlib.h>' \
		'#include <unistd.h>' \
		'#ifdef __cplusplus' \
		'#ifdef __APPLE__' \
		'#include <_xlocale.h>' \
		'#include <xlocale/_stdlib.h>' \
		'#endif' \
		'#undef system' \
		'#endif' > $(BUILD_WORK)/qtbase/qt-ios-iosexec-fixup.h
	# 4) drop SDK-shadowing Apple system headers: Procursus `setup` re-stages private copies into
	#    build_base on every run, and the -isystem build_base path puts them before the 16.4 SDK's.
	#    xpc/ is the iOS-17-era xpc_session API — any Foundation.h include dies on
	#    OS_OBJECT_DECL_SENDABLE_CLASS. os/log.h is a trimmed private copy missing
	#    os_log_type_enabled — qcore_mac.mm dies. Must run here (after `setup`), not in
	#    build-qt.sh: a driver-level cleanup gets undone by the next make.
	rm -rf $(BUILD_BASE)$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/xpc
	rm -f $(BUILD_BASE)$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/os/log.h
	# 5) re-add what the patch-2 MACOS-block disable also dropped: qcollator_posix.cpp (not
	#    qcollator_macx.cpp — that's Carbon UCCollate, truly macOS-only) and the kqueue filesystem
	#    watcher (the fsevents alternative is genuinely macOS-only). With ICU on, the posix collator
	#    must be gated CONDITION NOT QT_FEATURE_icu — upstream's icu block already compiles
	#    qcollator_icu.cpp and switches CollatorKeyType to QByteArray, so an unconditional re-add
	#    fails to compile against the ICU key type.
	if ! grep -q "xios iOS re-adds" $(BUILD_WORK)/qtbase/src/corelib/CMakeLists.txt; then \
		printf '%s\n' \
			'# xios iOS re-adds (see qtbase.mk patch 5)' \
			'qt_internal_extend_target(Core' \
			'    CONDITION NOT QT_FEATURE_icu' \
			'    SOURCES text/qcollator_posix.cpp' \
			')' \
			'qt_internal_extend_target(Core' \
			'    SOURCES io/qfilesystemwatcher_kqueue.cpp io/qfilesystemwatcher_kqueue_p.h' \
			')' >> $(BUILD_WORK)/qtbase/src/corelib/CMakeLists.txt ; \
	fi
	sed -i 's|SOURCES text/qcollator_macx.cpp io/qfilesystemwatcher_kqueue|SOURCES text/qcollator_posix.cpp io/qfilesystemwatcher_kqueue|' \
		$(BUILD_WORK)/qtbase/src/corelib/CMakeLists.txt
	# 6) FEATURE_fontconfig resolves, but src/gui gates the actual implementation
	#    (qfontconfigdatabase.cpp + the qgenericunixfontdatabase_p.h header sync) behind
	#    UNIX AND NOT APPLE, so the feature is advertised with nothing behind it and the minimal
	#    QPA plugin dies including the unsynced header. Un-gate both blocks (the only two
	#    extend_target uses of that condition in gui).
	sed -i -e 's/CONDITION UNIX AND NOT APPLE$$/CONDITION UNIX/' \
		-e 's/CONDITION QT_FEATURE_fontconfig AND QT_FEATURE_freetype AND UNIX AND NOT APPLE$$/CONDITION QT_FEATURE_fontconfig AND QT_FEATURE_freetype AND UNIX/' \
		$(BUILD_WORK)/qtbase/src/gui/CMakeLists.txt
	# 7) xkbcommon on a headless (X11-off) build hits two problems: Qt gates
	#    qt_find_package(XKB) behind `X11_SUPPORTED`, which is false here (no xcb); and the stock
	#    FindXKB is pkg-config-only, but Qt's pkg_config feature is OFF cross, so even un-gated it
	#    gets an empty XKB_VERSION and fails the version check. Un-gate only the plain-xkbcommon
	#    find and replace FindXKB with a synth target from the staged libxkbcommon; leave the
	#    xcb/xkbcommon-x11 blocks gated. NOTE the make-escaped $$1 — a bare $1 is eaten by make.
	perl -0pi -e 's{if\(\(X11_SUPPORTED\) OR QT_FIND_ALL_PACKAGES_ALWAYS\)\n(\s*qt_find_package\(XKB 0\.5\.0 PROVIDED_TARGETS XKB::XKB[^\n]*\n)\s*endif\(\)}{if(TRUE)  # xios: xkbcommon without X11\n$$1endif()}g' \
		$(BUILD_WORK)/qtbase/src/gui/configure.cmake
	printf '%s\n' \
		'if(NOT TARGET XKB::XKB)' \
		'  add_library(XKB::XKB UNKNOWN IMPORTED)' \
		'  set_target_properties(XKB::XKB PROPERTIES IMPORTED_LOCATION "$(QT_SYSROOT)/lib/libxkbcommon.dylib"' \
		'    INTERFACE_INCLUDE_DIRECTORIES "$(QT_SYSROOT)/include")' \
		'endif()' \
		'set(XKB_LIBRARY "$(QT_SYSROOT)/lib/libxkbcommon.dylib")' \
		'set(XKB_INCLUDE_DIR "$(QT_SYSROOT)/include")' \
		'set(XKB_VERSION 1.7.0)' \
		'include(FindPackageHandleStandardArgs)' \
		'find_package_handle_standard_args(XKB REQUIRED_VARS XKB_LIBRARY XKB_INCLUDE_DIR VERSION_VAR XKB_VERSION)' \
		> $(BUILD_WORK)/qtbase/cmake/3rdparty/kwin/FindXKB.cmake
	# 8) FindATSPI2.cmake is pkg-config-only (no find_library fallback), but Qt's pkg_config
	#    feature is OFF cross, so ATSPI2_FOUND is always 0 and the a11y bridge can't enable.
	#    Replace it with a synthesized INTERFACE target from the staged at-spi2-core-dev headers —
	#    the Qt AT-SPI bridge is a pure QtDBus adaptor and never links libatspi.
	printf '%s\n' \
		'if(NOT TARGET PkgConfig::ATSPI2)' \
		'  add_library(PkgConfig::ATSPI2 INTERFACE IMPORTED)' \
		'  set_target_properties(PkgConfig::ATSPI2 PROPERTIES INTERFACE_INCLUDE_DIRECTORIES' \
		'    "$(QT_SYSROOT)/include/at-spi-2.0;$(QT_SYSROOT)/include/dbus-1.0;$(QT_SYSROOT)/lib/dbus-1.0/include;$(QT_SYSROOT)/include/glib-2.0;$(QT_SYSROOT)/lib/glib-2.0/include;$(QT_SYSROOT)/include")' \
		'endif()' \
		'set(ATSPI2_FOUND 1)' > $(BUILD_WORK)/qtbase/cmake/FindATSPI2.cmake
	# 9) ANGLE's ES3 headers provide the functions Qt wants, but this staged header set can omit
	#    GLDEBUGPROC. Upstream only typedefs it for the non-ES3.2 path; make the fallback depend on
	#    the typedef actually being present so the ES3.2 build can keep going.
	if grep -q "QT_CONFIG(opengles2) && !QT_CONFIG(opengles32)" $(BUILD_WORK)/qtbase/src/gui/opengl/qopenglextrafunctions.h; then \
		perl -0pi -e 's{#if QT_CONFIG\(opengles2\) && !QT_CONFIG\(opengles32\)\ntypedef void \(QOPENGLF_APIENTRY  \*GLDEBUGPROC\)\(GLenum source,GLenum type,GLuint id,GLenum severity,GLsizei length,const GLchar \*message,const void \*userParam\);\n#endif}{#if QT_CONFIG(opengles2)\n#ifndef GLDEBUGPROC\ntypedef void (QOPENGLF_APIENTRY  *GLDEBUGPROC)(GLenum source,GLenum type,GLuint id,GLenum severity,GLsizei length,const GLchar *message,const void *userParam);\n#endif\n#endif}g' \
			$(BUILD_WORK)/qtbase/src/gui/opengl/qopenglextrafunctions.h ; \
	fi

ifneq ($(wildcard $(BUILD_WORK)/qtbase/.build_complete),)
qtbase:
	@echo "Using previously built qtbase."
else
# Base libs (zlib/libpng/freetype/fontconfig/harfbuzz/pcre2) are already staged in build_base
# — do NOT list them as prereqs (triggers unpatched rebuilds). ATSPI2 is not staged by any
# earlier track, so a fresh build_base needs at-spi2-core-dev + libatspi2.0-0 unpacked first:
#   for d in libatspi2.0-0 at-spi2-core-dev; do dpkg-deb -x out/$${d}_*.deb tmp && \
#     cp -a tmp/var/jb/usr/* $(BUILD_BASE)$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/; done
# (only atspi-2.pc + headers are consumed; the bridge is a pure QtDBus adaptor).
#
# CMAKE_OSX_DEPLOYMENT_TARGET is defined-but-EMPTY on purpose: Qt would otherwise default it
# to its macOS minimum and cmake would emit -mmacosx-version-min, which clang rejects next to
# the -miphoneos-version-min already in $(CFLAGS).
# QT_NO_APPLE_SDK_AND_XCODE_CHECK + the two QT_INTERNAL_*_VERSION seeds keep Qt's Apple SDK
# probing from exec'ing the hardcoded /usr/bin/xcrun, absent on the Linux host.
# CMAKE_OBJC(XX)_FLAGS: qtbase enables OBJC/OBJCXX on Apple and DEFAULT_CMAKE_FLAGS only covers
# C/CXX — without these the .mm/PCH compiles miss the libc++ -isystem paths.
# No `rm -rf build`: iteration relies on incremental cmake/ninja reruns; wipe manually when the
# toolchain or cache-poisoning flags change.
#
# Remaining OFF flags without inline prose (can't comment inside the backslash-continued args):
#   - FEATURE_rpath=OFF: LC_RPATH would bake this Docker build's throwaway DESTDIR path into
#     every dylib/exe; the shipped layout resolves libs via plain install names instead.
#   - FEATURE_glib=OFF: keeps this KDE/Qt track's event loop independent of the parallel
#     GNOME/GTK track (the switchable-flavor "distribution chooser" premise).
#   - FEATURE_zstd=OFF: no libzstd is built anywhere in this repo.
#   - FEATURE_brotli=OFF: libbrotli1 is built only on the separate Ladybird volume, not staged
#     into this build's sysroot.
qtbase: qtbase-setup
	mkdir -p $(BUILD_WORK)/qtbase/build
	cd $(BUILD_WORK)/qtbase/build && cmake .. \
		-G Ninja \
		$(DEFAULT_CMAKE_FLAGS) \
		-DCMAKE_OSX_DEPLOYMENT_TARGET= \
		-DQT_NO_APPLE_SDK_AND_XCODE_CHECK=ON \
		-DQT_INTERNAL_APPLE_SDK_VERSION=16.4 \
		-DQT_INTERNAL_XCODE_VERSION=15.0 \
		-DCMAKE_OBJC_FLAGS="$(CFLAGS)" \
		-DCMAKE_CXX_FLAGS="$(CXXFLAGS) -include $(BUILD_WORK)/qtbase/qt-ios-iosexec-fixup.h" \
		-DCMAKE_OBJCXX_FLAGS="$(CXXFLAGS) -include $(BUILD_WORK)/qtbase/qt-ios-iosexec-fixup.h" \
		-DCMAKE_SHARED_LINKER_FLAGS="$(LDFLAGS) $(QTBASE_IOS_FRAMEWORKS)" \
		-DCMAKE_MODULE_LINKER_FLAGS="$(LDFLAGS) $(QTBASE_IOS_FRAMEWORKS)" \
		-DCMAKE_EXE_LINKER_FLAGS="$(LDFLAGS) $(QTBASE_IOS_FRAMEWORKS)" \
		-DQT_HOST_PATH=$(QT_HOST_PATH) \
		-DQT_HOST_PATH_CMAKE_DIR=$(QT_HOST_CMAKE_DIR) \
		-DBUILD_SHARED_LIBS=ON \
		-DFEATURE_framework=OFF \
		-DFEATURE_shared=ON \
		-DFEATURE_static=OFF \
		-DFEATURE_rpath=OFF \
		-DQT_BUILD_EXAMPLES=OFF \
		-DQT_BUILD_TESTS=OFF \
		-DQT_BUILD_BENCHMARKS=OFF \
		-DFEATURE_gui=ON \
		-DFEATURE_widgets=ON \
		-DFEATURE_style_mac=OFF \
		-DFEATURE_network=ON \
		-DFEATURE_sql=ON \
		-DFEATURE_sql_sqlite=ON \
		-DFEATURE_system_sqlite=ON \
		-DFEATURE_testlib=OFF \
		-DFEATURE_printsupport=ON \
		-DFEATURE_cups=OFF \
		-DFEATURE_printdialog=OFF \
		-DFEATURE_printpreviewdialog=OFF \
		-DFEATURE_opengl=ON \
		-DFEATURE_opengles2=ON \
		-DINPUT_opengl:STRING=es2 \
		-DFEATURE_egl=ON \
		-DEGL_INCLUDE_DIR=$(QT_ANGLE_INC) \
		-DEGL_LIBRARY=$(QT_ANGLE_LIB)/libEGL.dylib \
		-DGLESv2_INCLUDE_DIR=$(QT_ANGLE_INC) \
		-DGLESv2_LIBRARY=$(QT_ANGLE_LIB)/libGLESv2.dylib \
		-DFEATURE_vulkan=OFF \
		-DFEATURE_icu=ON \
		-DICU_ROOT=$(QT_SYSROOT) \
		-DFEATURE_openssl=OFF \
		-DINPUT_openssl=no \
		-DFEATURE_dbus=ON \
		-DFEATURE_xkbcommon=ON \
		-DFEATURE_accessibility=ON \
		-DFEATURE_accessibility_atspi_bridge=ON \
		-DFEATURE_glib=OFF \
		-DFEATURE_zstd=OFF \
		-DFEATURE_brotli=OFF \
		-DFEATURE_system_zlib=ON \
		-DFEATURE_system_libpng=ON \
		-DFEATURE_system_png=ON \
		-DFEATURE_system_jpeg=ON \
		-DFEATURE_system_freetype=ON \
		-DFEATURE_fontconfig=ON \
		-DFEATURE_system_harfbuzz=ON \
		-DFEATURE_system_pcre2=ON \
		-DFEATURE_system_doubleconversion=OFF \
		-DINSTALL_ARCHDATADIR=lib/qt6 \
		-DINSTALL_DATADIR=share/qt6 \
		-DINSTALL_DOCDIR=share/qt6/doc \
		-DINSTALL_MKSPECSDIR=lib/qt6/mkspecs \
		-DINSTALL_PLUGINSDIR=lib/qt6/plugins \
		-DINSTALL_QMLDIR=lib/qt6/qml \
		-DINSTALL_LIBEXECDIR=lib/qt6/libexec \
		-DQT_QPA_DEFAULT_PLATFORM=offscreen
	+ninja -j$(QTBASE_NINJA_JOBS) -C $(BUILD_WORK)/qtbase/build
	+DESTDIR="$(BUILD_STAGE)/qtbase" ninja -j$(QTBASE_NINJA_JOBS) -C $(BUILD_WORK)/qtbase/build install
	$(call AFTER_BUILD,copy,qtbase,/var/jb/lib/angle)
endif

qtbase-package: qtbase-stage
	rm -rf $(BUILD_DIST)/qt6-base $(BUILD_DIST)/qt6-base-dev
	mkdir -p $(BUILD_DIST)/qt6-base/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/qt6-base-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	# runtime: the Qt6 dylibs + the plugin dir + target libexec (if any)
	cp -a $(BUILD_STAGE)/qtbase/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libQt6*.dylib \
		$(BUILD_DIST)/qt6-base/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib 2>/dev/null || true
	for d in lib/qt6/plugins lib/qt6/libexec; do \
		if [ -d "$(BUILD_STAGE)/qtbase/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d" ]; then \
			mkdir -p $(BUILD_DIST)/qt6-base/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$(dirname $$d); \
			cp -a $(BUILD_STAGE)/qtbase/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d \
				$(BUILD_DIST)/qt6-base/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d; fi; \
	done

	# dev: headers + cmake package files + .pc + mkspecs (needed to cross-build the rest of Qt/KF6)
	for d in include lib/cmake lib/pkgconfig lib/metatypes lib/qt6/mkspecs lib/qt6/modules bin; do \
		if [ -e "$(BUILD_STAGE)/qtbase/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d" ]; then \
			mkdir -p $(BUILD_DIST)/qt6-base-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$(dirname $$d); \
			cp -a $(BUILD_STAGE)/qtbase/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d \
				$(BUILD_DIST)/qt6-base-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d; fi; \
	done

	$(call SIGN,qt6-base,general.xml)
	$(call PACK,qt6-base,DEB_QTBASE_V)
	$(call PACK,qt6-base-dev,DEB_QTBASE_V)
	rm -rf $(BUILD_DIST)/qt6-base $(BUILD_DIST)/qt6-base-dev

.PHONY: qtbase qtbase-package
