ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# libpixman.mk — pixman bumped to 0.42.2 (meson) for mutter 46, which needs pixman-1 >= 0.42.
# Procursus mainline ships 0.40.0 (autotools, too old). 0.42+ is meson-only; ABI-compatible
# soname (libpixman-1.0), so already-built consumers (cairo/gtk4) keep working. Overrides the
# mainline recipe build-locally for the mutter build (build-mutter.sh copies this in).

SUBPROJECTS       += libpixman
LIBPIXMAN_VERSION := 0.42.2
DEB_LIBPIXMAN_V   ?= $(LIBPIXMAN_VERSION)

libpixman-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://cairographics.org/releases/pixman-$(LIBPIXMAN_VERSION).tar.gz)
	$(call EXTRACT_TAR,pixman-$(LIBPIXMAN_VERSION).tar.gz,pixman-$(LIBPIXMAN_VERSION),libpixman)
	rm -rf $(BUILD_WORK)/libpixman/build && mkdir -p $(BUILD_WORK)/libpixman/build
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
	[binaries]\n \
	c = '$(CC)'\n \
	cpp = '$(CXX)'\n \
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n \
	exe_wrapper = '/bin/true'\n" > $(BUILD_WORK)/libpixman/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/libpixman/.build_complete),)
libpixman:
	@echo "Using previously built libpixman."
else
libpixman: libpixman-setup
	cd $(BUILD_WORK)/libpixman/build && meson \
		--cross-file cross.txt \
		-Dgtk=disabled \
		-Dlibpng=disabled \
		-Darm-simd=disabled \
		-Dneon=disabled \
		-Da64-neon=disabled \
		-Diwmmxt=disabled \
		.. ; \
		DESTDIR="$(BUILD_STAGE)/libpixman" ninja install
	# meson already bakes LC_RPATH /var/jb/usr/lib into the dylib; AFTER_BUILD adds it again and
	# install_name_tool errors on the duplicate. Strip it first so AFTER_BUILD re-adds cleanly.
	for f in $$(find $(BUILD_STAGE)/libpixman -name '*.dylib' 2>/dev/null); do \
		$(I_N_T) -delete_rpath /var/jb/usr/lib $$f 2>/dev/null || true; \
	done
	$(call AFTER_BUILD,copy)
endif

libpixman-package: libpixman-stage
	rm -rf $(BUILD_DIST)/libpixman-1-0 $(BUILD_DIST)/libpixman-1-dev
	mkdir -p $(BUILD_DIST)/libpixman-1-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libpixman-1-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/{include,lib}
	cp -a $(BUILD_STAGE)/libpixman/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libpixman-1.0.dylib $(BUILD_DIST)/libpixman-1-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib 2>/dev/null || true
	cp -a $(BUILD_STAGE)/libpixman/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/libpixman-1-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX) 2>/dev/null || true
	cp -a $(BUILD_STAGE)/libpixman/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig $(BUILD_DIST)/libpixman-1-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib 2>/dev/null || true
	$(call SIGN,libpixman-1-0,general.xml)
	$(call PACK,libpixman-1-0,DEB_LIBPIXMAN_V)
	$(call PACK,libpixman-1-dev,DEB_LIBPIXMAN_V)
	rm -rf $(BUILD_DIST)/libpixman-1-0 $(BUILD_DIST)/libpixman-1-dev

.PHONY: libpixman libpixman-package
