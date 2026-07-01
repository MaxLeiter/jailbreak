ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# qtbase.mk — cross-build Qt 6 qtbase for rootless iOS, OFF-DEVICE (the KDE Plasma Mobile track's
# foundation; parallels build-mutter.sh for GNOME). This is deliberately Qt's DARWIN (macOS-style)
# platform, NOT the iOS/UIKit platform:
#   - Qt's official iOS port is STATIC + UIKit (QIOSIntegration). We want DYLIBS + a headless/Wayland
#     QPA so Plasma clients render through iosc/KWin, so we build the macx-clang platform (shared libs
#     OK, no forced UIKit) against the iPhoneOS SDK via the Procursus cctools toolchain — exactly the
#     Procursus premise (build "macOS-ish" software for the iOS ABI).
#   - FEATURE_framework=OFF: Qt on Apple defaults to .framework bundles; we need plain .dylib in
#     /var/jb/usr/lib (same reason ANGLE ships dylibs not frameworks). MUST be off.
#   - The cocoa platform plugin needs AppKit (absent on iOS) -> not built; default QPA = offscreen.
#   - GL/ICU/OpenSSL OFF for the first build (offscreen needs none; GL comes later via ANGLE, the
#     GTK4/Cogl path). Enable incrementally.
# HOST tools: cross-building qtbase needs moc/rcc/uic/syncqt from a host Qt of the IDENTICAL version
# via QT_HOST_PATH. Target is 6.6.3 (Plasma 6.0/6.1 era), which no Debian release ships, so
# build-qt.sh bootstraps a native host qtbase 6.6.3 from the same tarball into build_tools/ (one-time,
# persisted in the volume).

SUBPROJECTS    += qtbase
QTBASE_VERSION := 6.6.3
QT_MINOR       := 6.6
# Round 2 (-2): dbus + printsupport + xkbcommon + atspi bridge flipped ON (KF6/a11y need
# them). See the FEATURE_* block below and docs/kde-plasma-plan.md Q3. Round 1 was 6.6.3.
# dbus is RUNTIME (dlopen) not linked: Qt's QtDBus loader uses QLibrary("dbus-1",3) which on a
# Darwin target resolves libdbus-1.dylib/libdbus-1.3.dylib (both shipped) — deterministic on iOS,
# so the finicky WrapDBus1/DBus1Config linked path isn't needed. xkbcommon needs an X11-off
# un-gate (setup patch 7).
# printsupport is ON but its DIALOGS are OFF: the printer/QPrinter/PDF backend builds, but
# QPrintDialog/QPageSetupDialog have NO iOS impl — qprintdialog_unix.cpp hard-needs CUPS
# (QCUPSSupport, cups=OFF) and qprintdialog_mac.mm needs AppKit. The feature turns ON (all the
# widget deps are present) but links dead (vtable, no impl), so force printdialog +
# printpreviewdialog OFF. kxmlgui wants the module for QPrinter, not the picker UI; nobody prints
# from the iPad desktop. If a KF6 unit references QPrintDialog, patch it out KF6-side (plan Q3).
DEB_QTBASE_V   ?= $(QTBASE_VERSION)-2

# Host Qt (QT_HOST_PATH) — built by build-qt.sh stage 1 from the same source tarball.
QT_HOST_PATH      := $(BUILD_TOOLS)/host-qt-$(QTBASE_VERSION)
QT_HOST_CMAKE_DIR := $(QT_HOST_PATH)/lib/cmake

# Staged sysroot prefix (build_base/.../var/jb/usr) — round-2 cache seeds + FindATSPI2 synth
# point here for the libs pkg-config would have located (pkg_config feature is OFF cross).
QT_SYSROOT := $(BUILD_BASE)$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

# iOS stand-ins for the frameworks the disabled CONDITION-MACOS blocks would have linked
# (CoreServices/MobileCoreServices carry UTType*, Security; UIKit for qcore_mac.mm's Q_OS_IOS
# UIApplication refs). Injected into EVERY dylib/plugin/exe link via *_LINKER_FLAGS — they all
# live in the dyld shared cache, so linking them where unused costs nothing.
QTBASE_IOS_FRAMEWORKS := -framework UIKit -framework CoreServices -framework MobileCoreServices -framework Security

qtbase-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.qt.io/archive/qt/$(QT_MINOR)/$(QTBASE_VERSION)/submodules/qtbase-everywhere-src-$(QTBASE_VERSION).tar.xz)
	$(call EXTRACT_TAR,qtbase-everywhere-src-$(QTBASE_VERSION).tar.xz,qtbase-everywhere-src-$(QTBASE_VERSION),qtbase)
	# --- iOS/Darwin portability patches (accreting; the "why" documented above) ---
	# 1) Don't add the cocoa platform plugin (needs AppKit, absent on iOS). Guard the add_subdirectory.
	if grep -q "add_subdirectory(cocoa)" $(BUILD_WORK)/qtbase/src/plugins/platforms/CMakeLists.txt; then \
		sed -i 's/add_subdirectory(cocoa)/# add_subdirectory(cocoa)  # iOS: no AppKit/' \
			$(BUILD_WORK)/qtbase/src/plugins/platforms/CMakeLists.txt ; \
	fi
	# 2) THE core Darwin-vs-iOS fix. CMAKE_SYSTEM_NAME=Darwin makes Qt's cmake set MACOS=1 (see
	#    cmake/QtPlatformSupport.cmake: MACOS = APPLE AND NOT UIKIT; UIKIT needs CMAKE_SYSTEM_NAME
	#    =="iOS", which Procursus can't use — its toolchain is osxcross-style Darwin). So Qt tries to
	#    LINK the macOS-only frameworks (AppKit/Carbon/DiskArbitration/ApplicationServices) + compile
	#    macOS-desktop-only sources (qcocoanativeinterface, qmacgesturerecognizer). But the COMPILER
	#    already defines TARGET_OS_IPHONE (iPhoneOS sysroot + -miphoneos-version-min) so every .cpp/.mm
	#    compiles its Q_OS_IOS path. The mismatch is ONLY in the `CONDITION MACOS` cmake blocks. Disable
	#    them across ALL of src/ (their CONDITION APPLE siblings — CoreFoundation/CoreGraphics/CoreText/
	#    Foundation, all on iOS — stay, which is exactly the iOS framework set). `MACOS([^X])` keeps
	#    `CONDITION NOT MACOS`/`CONDITION APPLE`/`CONDITION UIKIT` untouched. Left-to-right cmake
	#    condition evaluation makes `MACOS AND FALSE OR X` == X, so mixed conditions stay correct.
	find $(BUILD_WORK)/qtbase/src -name CMakeLists.txt -exec \
		sed -i -E 's/CONDITION MACOS([^X])/CONDITION MACOS AND FALSE\1/g; s/CONDITION MACOS$$/CONDITION MACOS AND FALSE/' {} +
	# 3) libiosexec macro vs C++ members. build_base's staged stdlib.h/unistd.h force-include
	#    libiosexec.h, whose `#define system ie_system` mangles C++ members named system()
	#    (QRandomGenerator64::system, QLocale::system, ...). Force-include this fixup in every
	#    C++/ObjC++ TU (see the extra CMAKE_(OBJ)CXX_FLAGS below): C TUs keep the full interposition
	#    (exec*/posix_spawn/system -> ie_*, -liosexec still links); C++ TUs keep the exec* reroute
	#    (QProcess wants it) but drop the `system` macro. A C++ call to ::system() would then hit the
	#    __IOS_PROHIBITED libc declaration and fail loudly at compile time — none in these modules.
	printf '%s\n' \
		'#include <stdlib.h>' \
		'#include <unistd.h>' \
		'#ifdef __cplusplus' \
		'#undef system' \
		'#endif' > $(BUILD_WORK)/qtbase/qt-ios-iosexec-fixup.h
	# 4) drop the SDK-shadowing Apple system headers. Procursus `setup` (our prerequisite) RE-STAGES
	#    private copies into build_base on every run; the -isystem build_base include path puts them
	#    BEFORE the 16.4 SDK's:
	#      - xpc/: iOS-17-era (xpc_session API) — any Foundation.h include (-> NSXPCConnection.h ->
	#        <xpc/xpc.h>) dies on OS_OBJECT_DECL_SENDABLE_CLASS.
	#      - os/log.h: a trimmed private copy with NO os_log_type_enabled — qcore_mac.mm dies.
	#    Must happen HERE (after `setup`), not in build-qt.sh — a driver-level parking gets undone by
	#    the next make. Nothing in the Qt stack needs the staged copies.
	rm -rf $(BUILD_BASE)$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/xpc
	rm -f $(BUILD_BASE)$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/os/log.h
	# 5) re-add the Darwin-GENERIC pieces the MACOS-block disable (patch 2) also dropped:
	#    a QCollator backend — NOT qcollator_macx.cpp (Carbon UCCollate, truly macOS-only; learned
	#    in attempt 7) but qcollator_posix.cpp (strcoll; upstream gates it "UNIX AND NOT MACOS AND
	#    NOT ICU", false here because MACOS=1) — and the kqueue filesystem watcher
	#    (qfilesystemwatcher.cpp's Darwin engine chooser calls it; the fsevents alternative is
	#    genuinely macOS-only). The frameworks the dropped MACOS LIBRARIES block carried
	#    (CoreServices for UTType*, Security) plus UIKit (qcore_mac.mm's Q_OS_IOS path references
	#    UIApplication) are injected globally via *_LINKER_FLAGS below. The trailing sed corrects
	#    a tree that already carries the earlier macx-flavored append (idempotent otherwise).
	if ! grep -q "xios iOS re-adds" $(BUILD_WORK)/qtbase/src/corelib/CMakeLists.txt; then \
		printf '%s\n' \
			'# xios iOS re-adds (see qtbase.mk patch 5)' \
			'qt_internal_extend_target(Core' \
			'    SOURCES text/qcollator_posix.cpp io/qfilesystemwatcher_kqueue.cpp io/qfilesystemwatcher_kqueue_p.h' \
			')' >> $(BUILD_WORK)/qtbase/src/corelib/CMakeLists.txt ; \
	fi
	sed -i 's|SOURCES text/qcollator_macx.cpp io/qfilesystemwatcher_kqueue|SOURCES text/qcollator_posix.cpp io/qfilesystemwatcher_kqueue|' \
		$(BUILD_WORK)/qtbase/src/corelib/CMakeLists.txt
	# 6) fontconfig implementation on Darwin. FEATURE_fontconfig=ON resolves (sysroot ships
	#    fontconfig, and the KDE flavor wants it: desktop fonts live in fontconfig paths, and
	#    qtwayland's QGenericUnixFontDatabase = QFontconfigDatabase when the feature is on). But
	#    src/gui gates the implementation — qfontconfigdatabase.cpp + the qgenericunixfontdatabase_p.h
	#    header sync — behind UNIX AND NOT APPLE, so the feature is advertised with nothing behind it
	#    and the minimal QPA plugin dies including the unsynced header (attempt 8). Un-gate both
	#    blocks; they are the only two extend_target uses of the condition in gui, and the freetype
	#    engine they need already builds (QT_FEATURE_freetype=1).
	sed -i -e 's/CONDITION UNIX AND NOT APPLE$$/CONDITION UNIX/' \
		-e 's/CONDITION QT_FEATURE_fontconfig AND QT_FEATURE_freetype AND UNIX AND NOT APPLE$$/CONDITION QT_FEATURE_fontconfig AND QT_FEATURE_freetype AND UNIX/' \
		$(BUILD_WORK)/qtbase/src/gui/CMakeLists.txt
	# 7) xkbcommon on a headless (X11-off) build. Two problems: (a) Qt gates qt_find_package(XKB)
	#    behind `if((X11_SUPPORTED) OR QT_FIND_ALL_PACKAGES_ALWAYS)` — X11_SUPPORTED is false here
	#    (no xcb), so XKB is never searched; (b) the stock FindXKB is pkg-config-driven, but Qt's
	#    pkg_config feature is OFF in this cross build (everything else uses find_library), so even
	#    un-gated it gets an empty XKB_VERSION and the `XKB 0.5.0` version check fails. Fix both:
	#    un-gate ONLY the plain-xkbcommon find (XKB::XKB), and replace FindXKB with a synth target
	#    from the staged libxkbcommon (mirrors patch 8's FindATSPI2). Leave the xcb/xkbcommon-x11
	#    blocks gated (we don't want X11). NOTE the make-escaped $$1 — a bare $1 is eaten by make
	#    and would delete the captured qt_find_package line.
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
	# 8) ATSPI2 for the accessibility bridge. FindATSPI2.cmake is pkg-config-ONLY
	#    (pkg_check_modules atspi-2, no find_library fallback), but Qt's pkg_config feature is OFF
	#    in this cross build (everything else uses find_library), so ATSPI2_FOUND is always 0 and
	#    FEATURE_accessibility_atspi_bridge can't enable. Replace the module with a synthesized
	#    INTERFACE target built from the staged at-spi2-core-dev headers — the Qt AT-SPI bridge is a
	#    pure QtDBus adaptor (Gui pulls PkgConfig::ATSPI2 include dirs only, never links libatspi).
	printf '%s\n' \
		'if(NOT TARGET PkgConfig::ATSPI2)' \
		'  add_library(PkgConfig::ATSPI2 INTERFACE IMPORTED)' \
		'  set_target_properties(PkgConfig::ATSPI2 PROPERTIES INTERFACE_INCLUDE_DIRECTORIES' \
		'    "$(QT_SYSROOT)/include/at-spi-2.0;$(QT_SYSROOT)/include/dbus-1.0;$(QT_SYSROOT)/lib/dbus-1.0/include;$(QT_SYSROOT)/include/glib-2.0;$(QT_SYSROOT)/lib/glib-2.0/include;$(QT_SYSROOT)/include")' \
		'endif()' \
		'set(ATSPI2_FOUND 1)' > $(BUILD_WORK)/qtbase/cmake/FindATSPI2.cmake

ifneq ($(wildcard $(BUILD_WORK)/qtbase/.build_complete),)
qtbase:
	@echo "Using previously built qtbase."
else
# NOTE: base libs (zlib/libpng/freetype/fontconfig/harfbuzz/pcre2) are already staged in build_base
# (warm volume) — do NOT list them as prereqs (would trigger unpatched rebuilds, per mutter.mk).
# cmake finds them via CMAKE_FIND_ROOT_PATH=build_base. double-conversion/md4c/b2 are bundled by Qt.
# ROUND-2 PREREQ (dbus/xkbcommon/atspi features below): libdbus-1 + libxkbcommon are already in
# build_base; ATSPI2 is NOT staged by any earlier track, so the round-2 rebuild needs the
# at-spi2-core-dev + libatspi2.0-0 debs (from out/, GNOME track) unpacked into build_base first:
#   for d in libatspi2.0-0 at-spi2-core-dev; do dpkg-deb -x out/$${d}_*.deb tmp && \
#     cp -a tmp/var/jb/usr/* $(BUILD_BASE)$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/; done
# Only atspi-2.pc + headers are consumed (FindATSPI2 = pkg_check_modules; the bridge is a pure
# QtDBus adaptor, so libatspi is not linked — staging the runtime dylib is belt-and-suspenders).
# INSTALL_* dirs follow Debian's layout (plugins/qml/mkspecs under lib/qt6, data under share/qt6) so
# packaging and later Qt/KF6 modules have one canonical archdatadir.
# CMAKE_OSX_DEPLOYMENT_TARGET is defined-but-EMPTY on purpose: Qt would otherwise default it to its
# macOS minimum and cmake would emit -mmacosx-version-min, which clang rejects next to the
# -miphoneos-version-min already in $(CFLAGS). Defined-empty skips both.
# QT_NO_APPLE_SDK_AND_XCODE_CHECK + the two QT_INTERNAL_*_VERSION cache seeds keep Qt's Apple SDK
# probing from exec'ing the hardcoded /usr/bin/xcrun (absent on the Linux host; the sysroot is
# iPhoneOS 16.4, so seed that).
# CMAKE_OBJC(XX)_FLAGS: qtbase enables the OBJC/OBJCXX languages on Apple and DEFAULT_CMAKE_FLAGS
# only covers C/CXX — without these the .mm/PCH compiles miss the libc++ -isystem paths and
# -stdlib=libc++ ('type_traits' not found).
# No `rm -rf build`: iterating on this recipe relies on incremental cmake/ninja reruns. Wipe the
# build dir manually when the toolchain or cache-poisoning flags change.
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
		-DFEATURE_sql=OFF \
		-DFEATURE_testlib=OFF \
		-DFEATURE_printsupport=ON \
		-DFEATURE_cups=OFF \
		-DFEATURE_printdialog=OFF \
		-DFEATURE_printpreviewdialog=OFF \
		-DFEATURE_opengl=OFF \
		-DINPUT_opengl=no \
		-DFEATURE_egl=OFF \
		-DFEATURE_vulkan=OFF \
		-DFEATURE_icu=OFF \
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
	+ninja -C $(BUILD_WORK)/qtbase/build
	+DESTDIR="$(BUILD_STAGE)/qtbase" ninja -C $(BUILD_WORK)/qtbase/build install
	$(call AFTER_BUILD,copy)
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
