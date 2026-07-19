ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# gnome-font-viewer.mk — GNOME Fonts, a small GTK4/libadwaita app to browse/preview installed
# fonts. Chosen as a clean second GTK4 "simple win": it is PURE C (no Vala, no introspection),
# and every dependency is already in our tree or prebuilt — so it adds zero new sub-deps.
# (It pairs nicely with the x11-fonts-sf work: previews the live iOS system fonts.)
#
# Picked as the LIGHTEST simple win (zero new sub-deps). NOTE: gnome-calculator is also viable
# but heavier — it's Vala, but valac is a host transpiler (Vala->C, never runs target code), so
# it only needs vendored gtk4/libadwaita .vapi at build time, plus the C deps libsoup3/libgee/
# mpfr/mpc/gtksourceview5. (Only gjs/JS apps + the shell hit the runtime-typelib wall, not Vala.)
# See docs/gnome-apps.md "Language note".
#
# DEPENDS (target): gtk4 (gtk-builder) + libadwaita + gnome-desktop (+ harfbuzz/fontconfig/
#   freetype/fribidi/glib, all prebuilt).
#
# BUILT/PUBLISHED — gnome-font-viewer 46.0+ios1.

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
