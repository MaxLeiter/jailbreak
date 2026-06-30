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
DEB_APPSTREAM_V   ?= $(APPSTREAM_VERSION)

appstream-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://www.freedesktop.org/software/appstream/releases/AppStream-$(APPSTREAM_VERSION).tar.xz)
	$(call EXTRACT_TAR,AppStream-$(APPSTREAM_VERSION).tar.xz,AppStream-$(APPSTREAM_VERSION),appstream)
	# Cross-build: data/meson.build wants a NATIVE appstream >= our version just to run
	# `appstreamcli news-to-metainfo` for AppStream's OWN cli metainfo (irrelevant to the
	# library we ship). The host (Debian bookworm) has appstreamcli 0.16 — fine for that
	# subcommand but it fails the >= version gate. Drop the version-checked native dependency
	# and keep the bare find_program('appstreamcli'), which picks up the host binary.
	sed -i "/dependency('appstream', version:/,/not_found_message:/d" $(BUILD_WORK)/appstream/data/meson.build
	# tools/meson.build override_find_program() points find_program('appstreamcli') at the
	# TARGET-built (iOS) appstreamcli, so data/meson.build's news-to-metainfo step tries to run
	# an iOS binary on the Linux host -> "exe_wrapper needed". Drop that override so the host
	# appstreamcli on PATH is used for the build-time metainfo generation instead.
	sed -i "/meson.override_find_program('appstreamcli', ascli_exe)/d" $(BUILD_WORK)/appstream/tools/meson.build
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
