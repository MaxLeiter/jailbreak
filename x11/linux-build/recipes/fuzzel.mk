ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# Pinned to 1.12.0: >=1.13 hard-requires pixman >=0.46.0, which would force a churny pixman
# bump shared with foot/imv. 1.12.0's unversioned pixman-1 dependency is satisfied by our 0.40.0.
#
# Portability (fuzzel-compat.h force-included, plus a few seds):
#  - reallocarray/pipe2/mkostemp/struct itimerspec -> compat.h wrappers.
#  - char32.c's wchar_t-is-32-bit guard excludes only __FreeBSD__; Darwin's wchar_t is also
#    32-bit UTF-32, so __APPLE__ is added to the exclusion.
#  - match.c/render.c call the 2-arg glibc pthread_setname_np; Apple's takes 1 arg (names the
#    calling thread) — added an __APPLE__ branch, same fix as foot's render.c.
#  - shm.c already self-guards MAP_UNINITIALIZED/MFD_* and falls back to the mkostemp(/tmp)
#    path when memfd_create is absent.
#  - subdir('doc') hard-requires scdoc with no meson toggle; dropped since man pages aren't
#    needed on iOS.

SUBPROJECTS   += fuzzel
FUZZEL_VERSION := 1.12.0
DEB_FUZZEL_V   ?= $(FUZZEL_VERSION)+ios1

fuzzel-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://codeberg.org/dnkl/fuzzel/releases/download/$(FUZZEL_VERSION)/fuzzel-$(FUZZEL_VERSION).tar.gz)
	$(call EXTRACT_TAR,fuzzel-$(FUZZEL_VERSION).tar.gz,fuzzel-$(FUZZEL_VERSION),fuzzel)
	$(call DO_PATCH,fuzzel,fuzzel,-p1)
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
	# Point a native file at the version-matched wayland-scanner in WAYLAND_NATIVE_ROOT (same
	# trick as foot), and put its bin on PATH for find_program().
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
