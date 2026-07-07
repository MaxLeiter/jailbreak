ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# kwin.mk — KWin first-light for rootless iOS (nested Wayland/QPainter bias).
# This recipe intentionally disables the Linux DRM/libinput/native-shell surface and most
# effect plugins. The first goal is a linkable kwin_wayland on top of the KF6 + QtWayland
# stack; native IOSurface/Plasma Mobile polish comes after this binary exists.

SUBPROJECTS += kwin
KWIN_VERSION = $(PLASMA_VERSION)
DEB_KWIN_V ?= $(KWIN_VERSION)+ios2
# First-light keeps KWin's effects/QuickView GL paths disabled even when the
# staged QtGui is ANGLE-capable: Qt's iOS OpenGLES headers and libepoxy's gl*
# macro layer collide in KWin core. The private QPA plugin is still built.
KWIN_IOS_COMPAT_DEFS := -DKWIN_IOS_QT_NO_OPENGL=1

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
		-DKWIN_BUILD_KCMS=OFF \
		-DKWIN_BUILD_SCREENLOCKER=OFF \
		-DKWIN_BUILD_RUNNERS=OFF \
		-DKWIN_BUILD_EIS=OFF \
		-DKWIN_BUILD_NOTIFICATIONS=OFF \
		-DKWIN_BUILD_TABBOX=OFF \
		-DKWIN_BUILD_ACTIVITIES=OFF \
		-DKWIN_BUILD_DECORATIONS=ON \
		-DKWIN_BUILD_GLOBALSHORTCUTS=ON \
		-DQTWAYLANDSCANNER_KDE_EXECUTABLE=$(BUILD_WORK)/kwin/host-tools-build/qtwaylandscanner_kde \
		-DCMAKE_DISABLE_FIND_PACKAGE_KPipeWire=TRUE \
		-DCMAKE_DISABLE_FIND_PACKAGE_QAccessibilityClient6=TRUE
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
