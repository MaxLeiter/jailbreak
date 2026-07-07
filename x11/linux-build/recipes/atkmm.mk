ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# atkmm 2.28 / ABI 1.6: C++ bindings for ATK used by gtkmm3.

SUBPROJECTS     += atkmm
ATKMM_MAJOR_V   := 2.28
ATKMM_VERSION   := $(ATKMM_MAJOR_V).3
DEB_LIBATKMM_V  ?= $(ATKMM_VERSION)+ios1

atkmm-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/atkmm/$(ATKMM_MAJOR_V)/atkmm-$(ATKMM_VERSION).tar.xz)
	$(call EXTRACT_TAR,atkmm-$(ATKMM_VERSION).tar.xz,atkmm-$(ATKMM_VERSION),atkmm)
	rm -rf $(BUILD_WORK)/atkmm/build
	mkdir -p $(BUILD_WORK)/atkmm/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/atkmm/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/atkmm/.build_complete),)
atkmm:
	@echo "Using previously built atkmm."
else
atkmm: atkmm-setup atk glibmm
	cd $(BUILD_WORK)/atkmm/build && meson \
		--cross-file cross.txt \
		-Dmaintainer-mode=false \
		-Dwarnings=min \
		-Dbuild-documentation=false \
		..
	+ninja -C $(BUILD_WORK)/atkmm/build
	+DESTDIR="$(BUILD_STAGE)/atkmm" ninja -C $(BUILD_WORK)/atkmm/build install
	for f in $$(find $(BUILD_STAGE)/atkmm/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib -type f 2>/dev/null); do \
		$(I_N_T) -change @rpath/libintl.dylib @rpath/libgtkintl.dylib $$f 2>/dev/null || true; \
	done
	$(call AFTER_BUILD,copy)
endif

atkmm-package: atkmm-stage
	rm -rf $(BUILD_DIST)/libatkmm-1.6-1v5 $(BUILD_DIST)/libatkmm-1.6-dev
	mkdir -p $(BUILD_DIST)/libatkmm-1.6-1v5/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libatkmm-1.6-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	cp -a $(BUILD_STAGE)/atkmm/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libatkmm-1.6.*.dylib \
		$(BUILD_DIST)/libatkmm-1.6-1v5/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	cp -a $(BUILD_STAGE)/atkmm/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libatkmm-1.6-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/atkmm/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/!(libatkmm-1.6.*.dylib) \
		$(BUILD_DIST)/libatkmm-1.6-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	if [ -d "$(BUILD_STAGE)/atkmm/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share" ]; then \
		cp -a $(BUILD_STAGE)/atkmm/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share \
			$(BUILD_DIST)/libatkmm-1.6-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
	fi
	rm -rf $(BUILD_DIST)/libatkmm-1.6-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/doc \
		$(BUILD_DIST)/libatkmm-1.6-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/devhelp

	$(call SIGN,libatkmm-1.6-1v5,general.xml)
	$(call PACK,libatkmm-1.6-1v5,DEB_LIBATKMM_V)
	$(call PACK,libatkmm-1.6-dev,DEB_LIBATKMM_V)
	rm -rf $(BUILD_DIST)/libatkmm-1.6-1v5 $(BUILD_DIST)/libatkmm-1.6-dev

.PHONY: atkmm atkmm-package
