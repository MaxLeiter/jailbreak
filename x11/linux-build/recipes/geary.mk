ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# Geary 46 is the GTK3/WebKitGTK 4.1 release used by the Xios GNOME lane.
# WebKitGTK, Folks, gcr-3/gck-1 and the GOA client API are staged separately.
# libhandy 1.2.1 is built from Geary's pinned subproject and shipped in the
# application package so this port does not conflict with GTK4/libadwaita.

SUBPROJECTS   += geary
GEARY_VERSION := 46.0
DEB_GEARY_V   ?= $(GEARY_VERSION)+ios1

geary-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/geary/46/geary-$(GEARY_VERSION).tar.xz)
	$(call EXTRACT_TAR,geary-$(GEARY_VERSION).tar.xz,geary-$(GEARY_VERSION),geary)
	$(call DO_PATCH,geary,geary,-p1)
	rm -rf $(BUILD_WORK)/geary/build && mkdir -p $(BUILD_WORK)/geary/build
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
	exe_wrapper = '/bin/true'\n" > $(BUILD_WORK)/geary/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/geary/.build_complete),)
geary:
	@echo "Using previously built Geary."
else
geary: geary-setup
	cd $(BUILD_WORK)/geary/build && meson \
		--cross-file cross.txt \
		--buildtype=release \
		-Dprofile=release \
		-Dvaladoc=disabled \
		-Dlibunwind=disabled \
		-Dtnef=disabled \
		-Dcontractor=disabled \
		..
	+ninja -C $(BUILD_WORK)/geary/build
	+DESTDIR="$(BUILD_STAGE)/geary" ninja -C $(BUILD_WORK)/geary/build install
	$(call AFTER_BUILD,copy)
endif

geary-package: geary-stage
	rm -rf $(BUILD_DIST)/geary
	mkdir -p $(BUILD_DIST)/geary/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/geary/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/. \
		$(BUILD_DIST)/geary/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/
	rm -rf $(BUILD_DIST)/geary/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/doc \
		$(BUILD_DIST)/geary/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/man
	$(call SIGN,geary,iosc-gpu-client-ent.xml,,,nogeneral)
	$(call PACK,geary,DEB_GEARY_V)
	rm -rf $(BUILD_DIST)/geary

.PHONY: geary geary-package
