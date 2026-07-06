ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# imv.mk — imv, a Wayland/X11 image viewer (git.sr.ht/~exec64/imv). We build both window
# backends: Wayland is the native target, while X11 gives iOS a practical fallback through
# Xwayland/glamor because imv's renderer is fixed-function desktop OpenGL. libpng +
# libjpeg-turbo image backends are enabled (the heavier optional
# ones — tiff/rsvg/heif/jxl/webp/nsgif/nsbmp — are left off). Text overlay is rendered with
# pangocairo; the Unicode segmentation backend is libgrapheme (statically linked) instead of ICU.
#
# PORTABILITY: imv is clean on Darwin except for `cc.find_library('rt')` (no librt on iOS —
# clock_gettime lives in libc); the -setup sed makes that lookup non-required. Protocol code
# (xdg-shell, pointer-gestures-v1) is generated at build time by the host wayland-scanner via
# meson's unstable-wayland module, from the wayland-protocols data staged in build_base.
#
# DEPENDS (target): pango(cairo)/glib/cairo, wayland(+egl), egl/gl (mesa), X11/xcb, libxkbcommon,
# libpng, libjpeg-turbo, libgrapheme (build-only, static). inih is shipped inside the imv deb
# because the current build base has the dylib but no standalone runtime package.

SUBPROJECTS  += imv
IMV_VERSION  := 5.0.1
DEB_IMV_V    ?= $(IMV_VERSION)+ios2

imv-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://git.sr.ht/~exec64/imv/archive/v$(IMV_VERSION).tar.gz)
	$(call EXTRACT_TAR,v$(IMV_VERSION).tar.gz,imv-v$(IMV_VERSION),imv)
	# iOS has no librt and Darwin spells the stat mtime field differently.
	$(call DO_PATCH,imv,imv,-p1)
	# Darwin/iOS portability shim (st_mtim -> st_mtimespec, minimal wordexp replacing the
	# iOS-unavailable one), force-included into every imv C TU via c_args below.
	cp $(BUILD_INFO)/imv-compat.h $(BUILD_WORK)/imv/imv-compat.h
	rm -rf $(BUILD_WORK)/imv/build && mkdir -p $(BUILD_WORK)/imv/build
	echo -e "[host_machine]\n \
	system = 'darwin'\n \
	cpu_family = '$(shell echo $(GNU_HOST_TRIPLE) | cut -d- -f1)'\n \
	cpu = '$(MEMO_ARCH)'\n \
	endian = 'little'\n \
	[properties]\n \
	root = '$(BUILD_BASE)'\n \
	needs_exe_wrapper = true\n \
	[built-in options]\n \
	prefix ='$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)'\n \
	c_args = ['-include', '$(BUILD_WORK)/imv/imv-compat.h', '-Wno-error']\n \
	[binaries]\n \
	c = '$(CC)'\n \
	cpp = '$(CXX)'\n \
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/imv/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/imv/.build_complete),)
imv:
	@echo "Using previously built imv."
else
imv: imv-setup pango wayland wayland-protocols libxkbcommon libx11 libxcb libpng16 libjpeg-turbo libgrapheme mesa
	# find_protocol/scan_xml need the host wayland-scanner on PATH (from libwayland-bin) and a
	# native pkg-config pointed at the version-matched scanner .pc (same trick as foot).
	cd $(BUILD_WORK)/imv/build && \
		printf "[binaries]\npkgconfig = 'pkg-config'\n[built-in options]\npkg_config_path = ['$(WAYLAND_NATIVE_ROOT)/lib/pkgconfig']\n" > native.txt && \
		PATH="$(WAYLAND_NATIVE_ROOT)/bin:$$PATH" meson \
		--cross-file cross.txt \
		--native-file native.txt \
		-Dwindows=all \
		-Dunicode=grapheme \
		-Dtest=disabled \
		-Dman=disabled \
		-Dlibpng=enabled \
		-Dlibjpeg=enabled \
		-Dlibtiff=disabled \
		-Dlibrsvg=disabled \
		-Dlibnsgif=disabled \
		-Dlibnsbmp=disabled \
		-Dlibheif=disabled \
		-Dlibjxl=disabled \
		-Dlibwebp=disabled \
		-Dqoi=disabled \
		-Dfarbfeld=disabled \
		-Dcontrib-commands=false \
		..
	+PATH="$(WAYLAND_NATIVE_ROOT)/bin:$$PATH" ninja -C $(BUILD_WORK)/imv/build
	+DESTDIR="$(BUILD_STAGE)/imv" ninja -C $(BUILD_WORK)/imv/build install
	$(call AFTER_BUILD,copy)
endif

imv-package: imv-stage
	rm -rf $(BUILD_DIST)/imv
	mkdir -p $(BUILD_DIST)/imv/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/imv/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin $(BUILD_DIST)/imv/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	if [ -d "$(BUILD_STAGE)/imv/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share" ]; then \
		cp -a $(BUILD_STAGE)/imv/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share $(BUILD_DIST)/imv/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
	fi
	# inih is linked as @rpath/libinih.0.dylib, but this build base has no
	# standalone libinih runtime package. Ship the dylib inside imv's own deb.
	if ls $(BUILD_STAGE)/imv/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libinih*.dylib >/dev/null 2>&1; then \
		mkdir -p $(BUILD_DIST)/imv/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib; \
		cp -a $(BUILD_STAGE)/imv/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libinih*.dylib $(BUILD_DIST)/imv/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib; \
	elif ls $(BUILD_BASE)$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libinih*.dylib >/dev/null 2>&1; then \
		mkdir -p $(BUILD_DIST)/imv/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib; \
		cp -a $(BUILD_BASE)$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libinih*.dylib $(BUILD_DIST)/imv/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib; \
	fi

	$(call SIGN,imv,iosc-gpu-client-ent.xml,,,nogeneral)
	$(call PACK,imv,DEB_IMV_V)
	rm -rf $(BUILD_DIST)/imv

.PHONY: imv imv-package
