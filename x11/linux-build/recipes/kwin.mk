ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# Linux DRM/libinput/native backends stay disabled; the nested backend renders through
# ANGLE/Metal into IOSurfaces and imports IOSurface client buffers without a CPU copy.

SUBPROJECTS += kwin
KWIN_VERSION = $(PLASMA_VERSION)
DEB_KWIN_V ?= $(KWIN_VERSION)+ios34
# The epoxy vs QtGui-iOS-GLES header collision once forced -DKWIN_IOS_QT_NO_OPENGL=1 here.
# The gl-coexist shim in kwin-ios-compat.h fixed the collision (epoxy included first, then
# OpenGLES.framework guards pre-defined so Qt's qopengl.h defers to epoxy's Khronos
# definitions), so nothing needs to set it by hand any more and this stays empty.
#
# KWIN_IOS_QT_NO_OPENGL itself is NOT dead: kwin-ios-compat.h now defines it automatically
# when it sees `QT_FEATURE_opengl < 0`, i.e. when KWin is built against a Qt that has no
# OpenGL. The guards it drives (offscreenquickview.cpp et al. in kwin-ios-fixes.sh) are the
# fallback for that Qt, and they are inert against our Qt because qtbase.mk configures
# FEATURE_opengl=ON / INPUT_opengl=es2. Do not delete them as "unused" — they cost nothing
# on this Qt and they are what keeps a no-OpenGL Qt compiling.
KWIN_IOS_COMPAT_DEFS :=
KWIN_ANGLE_PREFIX := $(BUILD_BASE)$(MEMO_PREFIX)
KWIN_ANGLE_LIB := $(KWIN_ANGLE_PREFIX)/lib/angle

kwin-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),$(call PLASMA_URL,kwin))
	$(call EXTRACT_TAR,kwin-$(PLASMA_VERSION).tar.xz,kwin-$(PLASMA_VERSION),kwin)
	bash $(BUILD_INFO)/kwin-ios-fixes.sh $(BUILD_WORK)/kwin
	$(call QT6_WRITE_IOSEXEC_FIXUP)
	$(call QT6_RM_SHADOW_HEADERS)

ifneq ($(wildcard $(BUILD_WORK)/kwin/.build_complete),)
kwin:
	@echo "Using previously built kwin."
else
kwin: kwin-setup
	rm -rf $(BUILD_WORK)/kwin/host-tools-build
	env -u CC -u CXX -u CFLAGS -u CXXFLAGS -u CPPFLAGS -u LDFLAGS \
	cmake -S $(BUILD_WORK)/kwin/src/wayland/tools -B $(BUILD_WORK)/kwin/host-tools-build \
		-G Ninja \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_CXX_COMPILER=/usr/bin/c++ \
		-DCMAKE_PREFIX_PATH="$(QT6_HOST_PATH);$(BUILD_TOOLS)/kf6-host" \
		-DECM_DIR=$(BUILD_TOOLS)/kf6-host/share/ECM/cmake \
		-DQT_MAJOR_VERSION=6
	ninja -C $(BUILD_WORK)/kwin/host-tools-build qtwaylandscanner_kde
	rm -rf $(BUILD_WORK)/kwin/build
	mkdir -p $(BUILD_WORK)/kwin/build
	cd $(BUILD_WORK)/kwin/build && cmake .. \
		-G Ninja \
		$(KF6_CMAKE_FLAGS) \
		-DCMAKE_CXX_FLAGS="$(CXXFLAGS) $(KWIN_IOS_COMPAT_DEFS) -include $(QT6_IOSEXEC_FIXUP_H) -include $(BUILD_WORK)/kwin/src/kwin-ios-compat.h" \
		-DCMAKE_OBJCXX_FLAGS="$(CXXFLAGS) $(KWIN_IOS_COMPAT_DEFS) -include $(QT6_IOSEXEC_FIXUP_H) -include $(BUILD_WORK)/kwin/src/kwin-ios-compat.h" \
		-DCMAKE_SHARED_LINKER_FLAGS="$(LDFLAGS) $(QT6_IOS_FRAMEWORKS) -framework IOSurface -framework CoreFoundation -lepoll-shim" \
		-DCMAKE_MODULE_LINKER_FLAGS="$(LDFLAGS) $(QT6_IOS_FRAMEWORKS) -framework IOSurface -framework CoreFoundation -lepoll-shim" \
		-DCMAKE_EXE_LINKER_FLAGS="$(LDFLAGS) $(QT6_IOS_FRAMEWORKS) -framework IOSurface -framework CoreFoundation -lepoll-shim" \
		-DKWIN_BUILD_X11=OFF \
		-DKWIN_BUILD_KCMS=ON \
		-DKWIN_BUILD_SCREENLOCKER=OFF \
		-DKWIN_BUILD_RUNNERS=OFF \
		-DKWIN_BUILD_EIS=OFF \
		-DKWIN_BUILD_NOTIFICATIONS=OFF \
		-DKWIN_BUILD_TABBOX=OFF \
		-DKWIN_BUILD_ACTIVITIES=OFF \
		-DKWIN_BUILD_DECORATIONS=ON \
		-DKWIN_BUILD_GLOBALSHORTCUTS=ON \
		-DEGL_LIBRARY=$(KWIN_ANGLE_LIB)/libEGL.dylib \
		-DQTWAYLANDSCANNER_KDE_EXECUTABLE=$(BUILD_WORK)/kwin/host-tools-build/qtwaylandscanner_kde \
		-DCMAKE_DISABLE_FIND_PACKAGE_KPipeWire=TRUE \
		-DCMAKE_DISABLE_FIND_PACKAGE_QAccessibilityClient6=TRUE
	# CMake's parallel autogen can start moc before creating this include leaf.
	mkdir -p $(BUILD_WORK)/kwin/build/src/kwin_autogen/include
	+ninja -C $(BUILD_WORK)/kwin/build
	+DESTDIR="$(BUILD_STAGE)/kwin" ninja -C $(BUILD_WORK)/kwin/build install
	$(call AFTER_BUILD,copy)
endif

kwin-package: kwin-stage
	rm -rf $(BUILD_DIST)/kwin $(BUILD_DIST)/kwin-dev
	$(call KF6_COPY_RUNTIME,kwin,kwin)
	if [ -e "$(BUILD_STAGE)/kwin/Applications" ]; then \
		mkdir -p $(BUILD_DIST)/kwin$(MEMO_PREFIX)/Applications; \
		cp -a $(BUILD_STAGE)/kwin/Applications/. $(BUILD_DIST)/kwin$(MEMO_PREFIX)/Applications/; \
	fi
	$(call KF6_COPY_DEV,kwin,kwin)
	# kwin_wayland is the compositor side of the ANGLE/IOSurface path. It needs the
	# iosc GL/platform entitlement set and must not merge general.xml/no-container.
	$(call SIGN,kwin,iosc-gl-ent.xml,,,nogeneral)
	for dir in $(BUILD_DIST)/kwin$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin \
		$(BUILD_DIST)/kwin$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec; do \
		if [ -d "$$dir" ]; then \
			for f in $$(find "$$dir" -type f); do \
				if file "$$f" | grep -q 'Mach-O'; then \
					ldid -Sbuild_misc/entitlements/iosc-gl-ent.xml "$$f"; \
				fi; \
			done; \
		fi; \
	done
	$(call SIGN,kwin-dev,general.xml)
	$(call PACK,kwin,DEB_KWIN_V)
	$(call PACK,kwin-dev,DEB_KWIN_V)
	rm -rf $(BUILD_DIST)/kwin $(BUILD_DIST)/kwin-dev

.PHONY: kwin kwin-package
