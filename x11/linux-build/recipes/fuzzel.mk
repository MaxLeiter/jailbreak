ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# fuzzel.mk — fuzzel, a Wayland application launcher / dmenu replacement (codeberg.org/dnkl/fuzzel).
# Same author (dnkl) and build idioms as foot: pure C, no toolkit — it rasterises glyphs itself via
# fcft into pixman buffers and presents through wl_shm on a wlr-layer-shell overlay surface. SVG
# icons use the bundled nanosvg (no librsvg/cairo); PNG icons use libpng. Cairo is disabled.
#
# VERSION: pinned to 1.12.0 — the newest fuzzel that builds against the volume's pixman 0.40.0.
# fuzzel >=1.13 hard-requires pixman >=0.46.0 (dependency('pixman-1', version:'>=0.46.0')), which
# would force a churny pixman bump shared with foot/imv; 1.12.0's `dependency('pixman-1')` (no
# version) is satisfied by 0.40.0. fcft 3.3.3 and tllist 1.1.0 (already staged) satisfy its pins.
#
# PORTABILITY (all in fuzzel-compat.h, force-included, + a few seds):
#   - reallocarray / pipe2 / mkostemp / struct itimerspec  -> fuzzel-compat.h wrappers.
#   - char32.c's `#error "wchar_t does not use UTF-32"` guard excludes only __FreeBSD__; Darwin's
#     wchar_t IS 32-bit UTF-32 too, so add __APPLE__ to the exclusion (sed).
#   - match.c/render.c call the 2-arg glibc pthread_setname_np; Apple's takes 1 arg (sets the
#     calling thread) -> add an __APPLE__ branch mapping to the 1-arg form (blue-paint stops the
#     macro self-recursing), same as foot's render.c fix.
#   - shm.c self-guards MAP_UNINITIALIZED/MFD_* and picks the mkostemp(/tmp) path when memfd_create
#     is absent (Darwin). <threads.h>/<uchar.h>/<linux/input-event-codes.h> shims come from
#     build-wayland-apps.sh (staged into build_base).
#   - subdir('doc') hard-requires scdoc (no meson toggle); man pages aren't needed on iOS -> drop it.
#
# BUILD-HOST TOOLS (from build-wayland-apps.sh): wayland-scanner (protocol codegen, native),
# python3 (srgb.py), env. Protocols: wlr-layer-shell (vendored in external/) + xdg-shell/xdg-output/
# xdg-activation/cursor-shape/tablet-v2/viewporter/fractional-scale/primary-selection from
# wayland-protocols 1.44. All served by the iosc compositor.
#
# DEPENDS (target): wayland(+cursor), wayland-protocols, libxkbcommon, fcft, tllist(build/static),
# pixman, fontconfig, utf8proc, epoll-shim, libpng.

SUBPROJECTS   += fuzzel
FUZZEL_VERSION := 1.12.0
DEB_FUZZEL_V   ?= $(FUZZEL_VERSION)+ios1

fuzzel-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://codeberg.org/dnkl/fuzzel/releases/download/$(FUZZEL_VERSION)/fuzzel-$(FUZZEL_VERSION).tar.gz)
	$(call EXTRACT_TAR,fuzzel-$(FUZZEL_VERSION).tar.gz,fuzzel-$(FUZZEL_VERSION),fuzzel)
	# Darwin's wchar_t is 32-bit UTF-32 (like the BSDs) but doesn't advertise __STDC_ISO_10646__;
	# exclude __APPLE__ from foot^Wfuzzel's compile-time UTF-32 guard (currently __FreeBSD__-only).
	sed -i 's/&& !defined(__FreeBSD__)/\&\& !defined(__FreeBSD__) \&\& !defined(__APPLE__)/' $(BUILD_WORK)/fuzzel/char32.c
	# macOS/iOS pthread_setname_np takes only the name (sets the calling thread). Add an __APPLE__
	# branch to match.c and render.c mapping to the 1-arg call.
	for f in match.c render.c; do \
		if ! grep -q 'defined(__APPLE__)' $(BUILD_WORK)/fuzzel/$$f; then \
			sed -i 's|#elif defined(__NetBSD__)|#elif defined(__APPLE__)\n#define pthread_setname_np(thread, name) pthread_setname_np(name)\n#elif defined(__NetBSD__)|' $(BUILD_WORK)/fuzzel/$$f; \
		fi; \
	done
	# doc/ hard-requires scdoc (no meson toggle); man pages aren't needed on iOS.
	sed -i "/subdir('doc')/d" $(BUILD_WORK)/fuzzel/meson.build
	# Darwin/iOS libc portability shim, force-included into every fuzzel TU via c_args below.
	cp $(BUILD_INFO)/fuzzel-compat.h $(BUILD_WORK)/fuzzel/fuzzel-compat.h
	rm -rf $(BUILD_WORK)/fuzzel/build && mkdir -p $(BUILD_WORK)/fuzzel/build
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
	c_args = ['-include', '$(BUILD_WORK)/fuzzel/fuzzel-compat.h', '-Wno-error']\n \
	[binaries]\n \
	c = '$(CC)'\n \
	cpp = '$(CXX)'\n \
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/fuzzel/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/fuzzel/.build_complete),)
fuzzel:
	@echo "Using previously built fuzzel."
else
fuzzel: fuzzel-setup wayland wayland-protocols libxkbcommon fcft tllist libpixman fontconfig libutf8proc epoll-shim libpng16
	# fuzzel resolves `dependency('wayland-scanner', native:true)` via pkg-config; point a native
	# file at the version-matched native scanner the wayland build left in WAYLAND_NATIVE_ROOT
	# (same trick as foot), and put its bin on PATH for find_program().
	cd $(BUILD_WORK)/fuzzel/build && \
		printf "[binaries]\npkgconfig = 'pkg-config'\n[built-in options]\npkg_config_path = ['$(WAYLAND_NATIVE_ROOT)/lib/pkgconfig']\n" > native.txt && \
		PATH="$(WAYLAND_NATIVE_ROOT)/bin:$$PATH" meson \
		--cross-file cross.txt \
		--native-file native.txt \
		--buildtype=release \
		-Denable-cairo=disabled \
		-Dpng-backend=libpng \
		-Dsvg-backend=nanosvg \
		-Dsystem-nanosvg=disabled \
		..
	+PATH="$(WAYLAND_NATIVE_ROOT)/bin:$$PATH" ninja -C $(BUILD_WORK)/fuzzel/build
	+DESTDIR="$(BUILD_STAGE)/fuzzel" ninja -C $(BUILD_WORK)/fuzzel/build install
	$(call AFTER_BUILD,copy)
endif

fuzzel-package: fuzzel-stage
	rm -rf $(BUILD_DIST)/fuzzel
	mkdir -p $(BUILD_DIST)/fuzzel/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/fuzzel/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin $(BUILD_DIST)/fuzzel/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	if [ -d "$(BUILD_STAGE)/fuzzel/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share" ]; then \
		cp -a $(BUILD_STAGE)/fuzzel/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share $(BUILD_DIST)/fuzzel/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
	fi
	if [ -d "$(BUILD_STAGE)/fuzzel/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/etc" ]; then \
		cp -a $(BUILD_STAGE)/fuzzel/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/etc $(BUILD_DIST)/fuzzel/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
	fi

	$(call SIGN,fuzzel,iosc-gpu-client-ent.xml,,,nogeneral)
	$(call PACK,fuzzel,DEB_FUZZEL_V)
	rm -rf $(BUILD_DIST)/fuzzel

.PHONY: fuzzel fuzzel-package
