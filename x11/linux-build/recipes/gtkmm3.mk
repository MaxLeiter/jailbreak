ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# gtkmm 3.24 / ABI 3.0: C++ bindings for GTK3 used by Waybar.

SUBPROJECTS     += gtkmm3
GTKMM3_MAJOR_V  := 3.24
GTKMM3_VERSION  := $(GTKMM3_MAJOR_V).9
DEB_LIBGTKMM_V  ?= $(GTKMM3_VERSION)+ios1

gtkmm3-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/gtkmm/$(GTKMM3_MAJOR_V)/gtkmm-$(GTKMM3_VERSION).tar.xz)
	$(call EXTRACT_TAR,gtkmm-$(GTKMM3_VERSION).tar.xz,gtkmm-$(GTKMM3_VERSION),gtkmm3)
	rm -rf $(BUILD_WORK)/gtkmm3/build
	mkdir -p $(BUILD_WORK)/gtkmm3/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/gtkmm3/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/gtkmm3/.build_complete),)
gtkmm3:
	@echo "Using previously built gtkmm3."
else
gtkmm3: gtkmm3-setup gtk+3.0 cairomm pangomm atkmm glibmm
	cd $(BUILD_WORK)/gtkmm3/build && meson \
		--cross-file cross.txt \
		-Dmaintainer-mode=false \
		-Dwarnings=min \
		-Dbuild-documentation=false \
		-Dbuild-demos=false \
		-Dbuild-tests=false \
		..
	+ninja -C $(BUILD_WORK)/gtkmm3/build
	+DESTDIR="$(BUILD_STAGE)/gtkmm3" ninja -C $(BUILD_WORK)/gtkmm3/build install
	for f in $$(find $(BUILD_STAGE)/gtkmm3/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib -type f 2>/dev/null); do \
		$(I_N_T) -change @rpath/libintl.dylib @rpath/libgtkintl.dylib $$f 2>/dev/null || true; \
	done
	$(call AFTER_BUILD,copy)
endif

gtkmm3-package: gtkmm3-stage
	rm -rf $(BUILD_DIST)/libgtkmm-3.0-1v5 $(BUILD_DIST)/libgtkmm-3.0-dev
	mkdir -p $(BUILD_DIST)/libgtkmm-3.0-1v5/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libgtkmm-3.0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	cp -a $(BUILD_STAGE)/gtkmm3/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libgdkmm-3.0.*.dylib \
		$(BUILD_STAGE)/gtkmm3/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libgtkmm-3.0.*.dylib \
		$(BUILD_DIST)/libgtkmm-3.0-1v5/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	cp -a $(BUILD_STAGE)/gtkmm3/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libgtkmm-3.0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/gtkmm3/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/!(libgdkmm-3.0.*.dylib|libgtkmm-3.0.*.dylib) \
		$(BUILD_DIST)/libgtkmm-3.0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	if [ -d "$(BUILD_STAGE)/gtkmm3/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share" ]; then \
		cp -a $(BUILD_STAGE)/gtkmm3/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share \
			$(BUILD_DIST)/libgtkmm-3.0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
	fi
	rm -rf $(BUILD_DIST)/libgtkmm-3.0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/doc \
		$(BUILD_DIST)/libgtkmm-3.0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/devhelp

	$(call SIGN,libgtkmm-3.0-1v5,general.xml)
	$(call PACK,libgtkmm-3.0-1v5,DEB_LIBGTKMM_V)
	$(call PACK,libgtkmm-3.0-dev,DEB_LIBGTKMM_V)
	rm -rf $(BUILD_DIST)/libgtkmm-3.0-1v5 $(BUILD_DIST)/libgtkmm-3.0-dev

.PHONY: gtkmm3 gtkmm3-package
