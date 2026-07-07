ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# pangomm 2.46 / ABI 1.4: C++ bindings for Pango used by gtkmm3.

SUBPROJECTS       += pangomm
PANGOMM_MAJOR_V   := 2.46
PANGOMM_VERSION   := $(PANGOMM_MAJOR_V).4
DEB_LIBPANGOMM_V  ?= $(PANGOMM_VERSION)+ios1

pangomm-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/pangomm/$(PANGOMM_MAJOR_V)/pangomm-$(PANGOMM_VERSION).tar.xz)
	$(call EXTRACT_TAR,pangomm-$(PANGOMM_VERSION).tar.xz,pangomm-$(PANGOMM_VERSION),pangomm)
	rm -rf $(BUILD_WORK)/pangomm/build
	mkdir -p $(BUILD_WORK)/pangomm/build
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
	cpp_args = ['-D_DARWIN_C_SOURCE', '-Wno-error', '-stdlib=libc++', '-isysroot', '$(TARGET_SYSROOT)', '$(PLATFORM_VERSION_MIN)', '-arch', '$(MEMO_ARCH)', '-isystem$(TARGET_SYSROOT)/usr/include/c++/v1', '-isystem$(BUILD_BASE)$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/c++/v1', '-isystem$(BUILD_BASE)$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include']\n \
	cpp_link_args = ['-stdlib=libc++', '-isysroot', '$(TARGET_SYSROOT)', '$(PLATFORM_VERSION_MIN)', '-arch', '$(MEMO_ARCH)', '-L$(BUILD_BASE)$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib', '-Wl,-not_for_dyld_shared_cache', '-liosexec']\n \
	[binaries]\n \
	c = '$(CC)'\n \
	cpp = '$(CXX)'\n \
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/pangomm/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/pangomm/.build_complete),)
pangomm:
	@echo "Using previously built pangomm."
else
pangomm: pangomm-setup pango cairomm glibmm
	cd $(BUILD_WORK)/pangomm/build && meson \
		--cross-file cross.txt \
		-Dmaintainer-mode=false \
		-Dwarnings=min \
		-Dbuild-documentation=false \
		..
	+ninja -C $(BUILD_WORK)/pangomm/build
	+DESTDIR="$(BUILD_STAGE)/pangomm" ninja -C $(BUILD_WORK)/pangomm/build install
	for f in $$(find $(BUILD_STAGE)/pangomm/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib -type f 2>/dev/null); do \
		$(I_N_T) -change @rpath/libintl.dylib @rpath/libgtkintl.dylib $$f 2>/dev/null || true; \
	done
	$(call AFTER_BUILD,copy)
endif

pangomm-package: pangomm-stage
	rm -rf $(BUILD_DIST)/libpangomm-1.4-1v5 $(BUILD_DIST)/libpangomm-1.4-dev
	mkdir -p $(BUILD_DIST)/libpangomm-1.4-1v5/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libpangomm-1.4-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	cp -a $(BUILD_STAGE)/pangomm/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libpangomm-1.4.*.dylib \
		$(BUILD_DIST)/libpangomm-1.4-1v5/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	cp -a $(BUILD_STAGE)/pangomm/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libpangomm-1.4-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/pangomm/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/!(libpangomm-1.4.*.dylib) \
		$(BUILD_DIST)/libpangomm-1.4-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	if [ -d "$(BUILD_STAGE)/pangomm/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share" ]; then \
		cp -a $(BUILD_STAGE)/pangomm/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share \
			$(BUILD_DIST)/libpangomm-1.4-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
	fi
	rm -rf $(BUILD_DIST)/libpangomm-1.4-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/doc \
		$(BUILD_DIST)/libpangomm-1.4-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/devhelp

	$(call SIGN,libpangomm-1.4-1v5,general.xml)
	$(call PACK,libpangomm-1.4-1v5,DEB_LIBPANGOMM_V)
	$(call PACK,libpangomm-1.4-dev,DEB_LIBPANGOMM_V)
	rm -rf $(BUILD_DIST)/libpangomm-1.4-1v5 $(BUILD_DIST)/libpangomm-1.4-dev

.PHONY: pangomm pangomm-package
