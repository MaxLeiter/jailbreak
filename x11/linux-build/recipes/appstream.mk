ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# appstream.mk — AppStream metadata library. Mandatory dependency of libadwaita 1.4
# (src/meson.build declares it required). Pulls libxmlb + libyaml + libxml2 (libyaml/libxml2
# are prebuilt in Procursus; libxmlb is our recipe). GTK-independent. See docs/gnome-apps.md.
# Build runs glib-compile-resources + msgfmt on the HOST (provided by libglib2.0-bin / gettext).
#
# DRAFT — Phase 1, NOT built/verified. Mirrors recipes/pango.mk style. Soname 5 matches the
# Debian sid libappstream5 (AppStream 1.0.x).

SUBPROJECTS       += appstream
APPSTREAM_VERSION := 1.0.3
DEB_APPSTREAM_V   ?= $(APPSTREAM_VERSION)+ios1

appstream-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://www.freedesktop.org/software/appstream/releases/AppStream-$(APPSTREAM_VERSION).tar.xz)
	$(call EXTRACT_TAR,AppStream-$(APPSTREAM_VERSION).tar.xz,AppStream-$(APPSTREAM_VERSION),appstream)
	# Keep the cross-build appstreamcli source fixes in the port patch stack.
	$(call DO_PATCH,appstream,appstream,-p1)
	mkdir -p $(BUILD_WORK)/appstream/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/appstream/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/appstream/.build_complete),)
appstream:
	@echo "Using previously built appstream."
else
appstream: appstream-setup glib2.0 libxml2 libyaml libxmlb curl
	cd $(BUILD_WORK)/appstream/build && meson \
		--cross-file cross.txt \
		-Dgir=false \
		-Dapidocs=false \
		-Dinstall-docs=false \
		-Dstemming=false \
		-Dvapi=false \
		-Dcompose=false \
		-Dsystemd=false \
		..
	+ninja -C $(BUILD_WORK)/appstream/build
	+DESTDIR="$(BUILD_STAGE)/appstream" ninja -C $(BUILD_WORK)/appstream/build install
	$(call AFTER_BUILD,copy)
endif

appstream-package: appstream-stage
	rm -rf $(BUILD_DIST)/libappstream5 $(BUILD_DIST)/libappstream-dev
	mkdir -p $(BUILD_DIST)/libappstream5/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libappstream-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# libappstream5 (runtime dylib + appstreamcli + data)
	cp -a $(BUILD_STAGE)/appstream/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libappstream.5.dylib $(BUILD_DIST)/libappstream5/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	if [ -d "$(BUILD_STAGE)/appstream/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin" ]; then \
		cp -a $(BUILD_STAGE)/appstream/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin $(BUILD_DIST)/libappstream5/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
	fi
	if [ -d "$(BUILD_STAGE)/appstream/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share" ]; then \
		cp -a $(BUILD_STAGE)/appstream/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share $(BUILD_DIST)/libappstream5/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
	fi

	# libappstream-dev (headers, symlink, .pc)
	cp -a $(BUILD_STAGE)/appstream/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/!(libappstream.5.dylib) $(BUILD_DIST)/libappstream-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/appstream/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/libappstream-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	$(call SIGN,libappstream5,general.xml)
	$(call PACK,libappstream5,DEB_APPSTREAM_V)
	$(call PACK,libappstream-dev,DEB_APPSTREAM_V)
	rm -rf $(BUILD_DIST)/libappstream5 $(BUILD_DIST)/libappstream-dev

.PHONY: appstream appstream-package
