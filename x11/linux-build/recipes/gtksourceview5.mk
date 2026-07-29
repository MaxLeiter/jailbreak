ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# gtksourceview4 is the separate GTK3-flavored library for gedit; that's a distinct recipe.

SUBPROJECTS         += gtksourceview5
GTKSOURCEVIEW5_MAJOR_V := 5.12
GTKSOURCEVIEW5_VERSION := $(GTKSOURCEVIEW5_MAJOR_V).1
DEB_GTKSOURCEVIEW5_V   ?= $(GTKSOURCEVIEW5_VERSION)+ios1

gtksourceview5-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/gtksourceview/$(GTKSOURCEVIEW5_MAJOR_V)/gtksourceview-$(GTKSOURCEVIEW5_VERSION).tar.xz)
	$(call EXTRACT_TAR,gtksourceview-$(GTKSOURCEVIEW5_VERSION).tar.xz,gtksourceview-$(GTKSOURCEVIEW5_VERSION),gtksourceview5)
	mkdir -p $(BUILD_WORK)/gtksourceview5/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/gtksourceview5/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/gtksourceview5/.build_complete),)
gtksourceview5:
	@echo "Using previously built gtksourceview5."
else
gtksourceview5: gtksourceview5-setup gtk4 libxml2 pcre2
	cd $(BUILD_WORK)/gtksourceview5/build && meson \
		--cross-file cross.txt \
		-Dintrospection=disabled \
		-Dvapi=false \
		-Ddocumentation=false \
		-Dsysprof=false \
		-Dinstall-tests=false \
		-Dbuild-testsuite=false \
		..
	+ninja -C $(BUILD_WORK)/gtksourceview5/build
	+DESTDIR="$(BUILD_STAGE)/gtksourceview5" ninja -C $(BUILD_WORK)/gtksourceview5/build install
	$(call AFTER_BUILD,copy)
endif

gtksourceview5-package: gtksourceview5-stage
	rm -rf $(BUILD_DIST)/libgtksourceview-5-0 $(BUILD_DIST)/libgtksourceview-5-dev
	mkdir -p $(BUILD_DIST)/libgtksourceview-5-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libgtksourceview-5-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# libgtksourceview-5-0 (runtime dylib + language-specs/styles data)
	cp -a $(BUILD_STAGE)/gtksourceview5/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libgtksourceview-5.0.dylib $(BUILD_DIST)/libgtksourceview-5-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	if [ -d "$(BUILD_STAGE)/gtksourceview5/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share" ]; then \
		cp -a $(BUILD_STAGE)/gtksourceview5/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share $(BUILD_DIST)/libgtksourceview-5-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
	fi

	# libgtksourceview-5-dev (headers, symlink, .pc)
	cp -a $(BUILD_STAGE)/gtksourceview5/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/!(libgtksourceview-5.0.dylib) $(BUILD_DIST)/libgtksourceview-5-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/gtksourceview5/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/libgtksourceview-5-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	$(call SIGN,libgtksourceview-5-0,general.xml)
	$(call PACK,libgtksourceview-5-0,DEB_GTKSOURCEVIEW5_V)
	$(call PACK,libgtksourceview-5-dev,DEB_GTKSOURCEVIEW5_V)
	rm -rf $(BUILD_DIST)/libgtksourceview-5-0 $(BUILD_DIST)/libgtksourceview-5-dev

.PHONY: gtksourceview5 gtksourceview5-package
