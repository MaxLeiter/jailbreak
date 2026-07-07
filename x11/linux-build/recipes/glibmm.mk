ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# glibmm 2.66 / ABI 2.4: C++ bindings for GLib/GIO used by gtkmm3.

SUBPROJECTS      += glibmm
GLIBMM_MAJOR_V   := 2.66
GLIBMM_VERSION   := $(GLIBMM_MAJOR_V).7
DEB_LIBGLIBMM_V  ?= $(GLIBMM_VERSION)+ios1

glibmm-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/glibmm/$(GLIBMM_MAJOR_V)/glibmm-$(GLIBMM_VERSION).tar.xz)
	$(call EXTRACT_TAR,glibmm-$(GLIBMM_VERSION).tar.xz,glibmm-$(GLIBMM_VERSION),glibmm)
	rm -rf $(BUILD_WORK)/glibmm/build
	mkdir -p $(BUILD_WORK)/glibmm/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/glibmm/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/glibmm/.build_complete),)
glibmm:
	@echo "Using previously built glibmm."
else
glibmm: glibmm-setup glib2.0 libsigcplusplus
	cd $(BUILD_WORK)/glibmm/build && meson \
		--cross-file cross.txt \
		-Dmaintainer-mode=false \
		-Dwarnings=min \
		-Dbuild-documentation=false \
		-Dbuild-examples=false \
		..
	+ninja -C $(BUILD_WORK)/glibmm/build
	+DESTDIR="$(BUILD_STAGE)/glibmm" ninja -C $(BUILD_WORK)/glibmm/build install
	for f in $$(find $(BUILD_STAGE)/glibmm/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib -type f 2>/dev/null); do \
		$(I_N_T) -change @rpath/libintl.dylib @rpath/libgtkintl.dylib $$f 2>/dev/null || true; \
	done
	$(call AFTER_BUILD,copy)
endif

glibmm-package: glibmm-stage
	rm -rf $(BUILD_DIST)/libglibmm-2.4-1v5 $(BUILD_DIST)/libglibmm-2.4-dev
	mkdir -p $(BUILD_DIST)/libglibmm-2.4-1v5/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libglibmm-2.4-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	cp -a $(BUILD_STAGE)/glibmm/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libglibmm-2.4.*.dylib \
		$(BUILD_STAGE)/glibmm/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libgiomm-2.4.*.dylib \
		$(BUILD_DIST)/libglibmm-2.4-1v5/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	cp -a $(BUILD_STAGE)/glibmm/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libglibmm-2.4-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/glibmm/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/!(libglibmm-2.4.*.dylib|libgiomm-2.4.*.dylib) \
		$(BUILD_DIST)/libglibmm-2.4-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	if [ -d "$(BUILD_STAGE)/glibmm/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share" ]; then \
		cp -a $(BUILD_STAGE)/glibmm/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share \
			$(BUILD_DIST)/libglibmm-2.4-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
	fi
	rm -rf $(BUILD_DIST)/libglibmm-2.4-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/doc \
		$(BUILD_DIST)/libglibmm-2.4-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/devhelp

	$(call SIGN,libglibmm-2.4-1v5,general.xml)
	$(call PACK,libglibmm-2.4-1v5,DEB_LIBGLIBMM_V)
	$(call PACK,libglibmm-2.4-dev,DEB_LIBGLIBMM_V)
	rm -rf $(BUILD_DIST)/libglibmm-2.4-1v5 $(BUILD_DIST)/libglibmm-2.4-dev

.PHONY: glibmm glibmm-package
