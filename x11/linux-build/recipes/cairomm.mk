ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# cairomm 1.14 / ABI 1.0: C++ bindings for Cairo used by gtkmm3.

SUBPROJECTS       += cairomm
CAIROMM_MAJOR_V   := 1.14
CAIROMM_VERSION   := $(CAIROMM_MAJOR_V).5
DEB_LIBCAIROMM_V  ?= $(CAIROMM_VERSION)+ios1

cairomm-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://www.cairographics.org/releases/cairomm-$(CAIROMM_VERSION).tar.xz)
	$(call EXTRACT_TAR,cairomm-$(CAIROMM_VERSION).tar.xz,cairomm-$(CAIROMM_VERSION),cairomm)
	rm -rf $(BUILD_WORK)/cairomm/build
	mkdir -p $(BUILD_WORK)/cairomm/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/cairomm/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/cairomm/.build_complete),)
cairomm:
	@echo "Using previously built cairomm."
else
cairomm: cairomm-setup cairo libsigcplusplus
	cd $(BUILD_WORK)/cairomm/build && meson \
		--cross-file cross.txt \
		-Dmaintainer-mode=false \
		-Dwarnings=min \
		-Dbuild-documentation=false \
		-Dbuild-examples=false \
		-Dbuild-tests=false \
		..
	+ninja -C $(BUILD_WORK)/cairomm/build
	+DESTDIR="$(BUILD_STAGE)/cairomm" ninja -C $(BUILD_WORK)/cairomm/build install
	for f in $$(find $(BUILD_STAGE)/cairomm/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib -type f 2>/dev/null); do \
		$(I_N_T) -change @rpath/libintl.dylib @rpath/libgtkintl.dylib $$f 2>/dev/null || true; \
	done
	$(call AFTER_BUILD,copy)
endif

cairomm-package: cairomm-stage
	rm -rf $(BUILD_DIST)/libcairomm-1.0-1v5 $(BUILD_DIST)/libcairomm-1.0-dev
	mkdir -p $(BUILD_DIST)/libcairomm-1.0-1v5/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libcairomm-1.0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	cp -a $(BUILD_STAGE)/cairomm/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libcairomm-1.0.*.dylib \
		$(BUILD_DIST)/libcairomm-1.0-1v5/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	cp -a $(BUILD_STAGE)/cairomm/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libcairomm-1.0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/cairomm/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/!(libcairomm-1.0.*.dylib) \
		$(BUILD_DIST)/libcairomm-1.0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	if [ -d "$(BUILD_STAGE)/cairomm/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share" ]; then \
		cp -a $(BUILD_STAGE)/cairomm/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share \
			$(BUILD_DIST)/libcairomm-1.0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
	fi
	rm -rf $(BUILD_DIST)/libcairomm-1.0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/doc \
		$(BUILD_DIST)/libcairomm-1.0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/devhelp

	$(call SIGN,libcairomm-1.0-1v5,general.xml)
	$(call PACK,libcairomm-1.0-1v5,DEB_LIBCAIROMM_V)
	$(call PACK,libcairomm-1.0-dev,DEB_LIBCAIROMM_V)
	rm -rf $(BUILD_DIST)/libcairomm-1.0-1v5 $(BUILD_DIST)/libcairomm-1.0-dev

.PHONY: cairomm cairomm-package
