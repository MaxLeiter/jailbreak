ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

SUBPROJECTS                += gnome-font-viewer
GNOME-FONT-VIEWER_MAJOR_V  := 46
GNOME-FONT-VIEWER_VERSION  := $(GNOME-FONT-VIEWER_MAJOR_V).0
DEB_GNOME-FONT-VIEWER_V    ?= $(GNOME-FONT-VIEWER_VERSION)+ios1

gnome-font-viewer-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/gnome-font-viewer/$(GNOME-FONT-VIEWER_MAJOR_V)/gnome-font-viewer-$(GNOME-FONT-VIEWER_VERSION).tar.xz)
	$(call EXTRACT_TAR,gnome-font-viewer-$(GNOME-FONT-VIEWER_VERSION).tar.xz,gnome-font-viewer-$(GNOME-FONT-VIEWER_VERSION),gnome-font-viewer)
	mkdir -p $(BUILD_WORK)/gnome-font-viewer/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/gnome-font-viewer/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/gnome-font-viewer/.build_complete),)
gnome-font-viewer:
	@echo "Using previously built gnome-font-viewer."
else
gnome-font-viewer: gnome-font-viewer-setup gtk4 libadwaita gnome-desktop
	cd $(BUILD_WORK)/gnome-font-viewer/build && meson \
		--cross-file cross.txt \
		..
	+ninja -C $(BUILD_WORK)/gnome-font-viewer/build
	+DESTDIR="$(BUILD_STAGE)/gnome-font-viewer" ninja -C $(BUILD_WORK)/gnome-font-viewer/build install
	$(call AFTER_BUILD,copy)
endif

gnome-font-viewer-package: gnome-font-viewer-stage
	rm -rf $(BUILD_DIST)/gnome-font-viewer
	mkdir -p $(BUILD_DIST)/gnome-font-viewer/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	# app: bin/gnome-font-viewer + share (desktop, icons, gschemas, gresource)
	cp -a $(BUILD_STAGE)/gnome-font-viewer/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin $(BUILD_DIST)/gnome-font-viewer/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/gnome-font-viewer/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share $(BUILD_DIST)/gnome-font-viewer/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	$(call SIGN,gnome-font-viewer,iosc-gpu-client-ent.xml,,,nogeneral)
	$(call PACK,gnome-font-viewer,DEB_GNOME-FONT-VIEWER_V)
	rm -rf $(BUILD_DIST)/gnome-font-viewer

.PHONY: gnome-font-viewer gnome-font-viewer-package
