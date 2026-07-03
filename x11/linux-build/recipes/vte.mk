ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# vte.mk — GNOME's virtual terminal emulator widget (NOT Procursus's libvterm). Used by
# gnome-console/kgx (GTK4). GNOME 45 generation = vte 0.74.2.
#
# GTK4-ONLY by default: the desktop track is GTK4-first and GTK3 is deferred, so building the
# GTK3 widget (which would hard-depend on gtk+3.0) is off by default. To also emit the GTK3
# widget (libvte-2.91) for gnome-terminal once GTK3 lands: flip `-Dgtk3=true`, add `gtk+3.0`
# to the deps line, and re-add the libvte-2.91-0 packaging block (kept below, commented).
#
# DEPENDS (target): gtk4 (gtk-builder) + libxml2 + pcre2 + gnutls + icu4c
#   (+ pango/fribidi/glib in stack).
#
# DRAFT — Phase 1, NOT built/verified. Mirrors recipes/pango.mk style.

SUBPROJECTS  += vte
VTE_MAJOR_V  := 0.76
VTE_VERSION  := $(VTE_MAJOR_V).6
DEB_VTE_V    ?= $(VTE_VERSION)+ios1

vte-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/vte/$(VTE_MAJOR_V)/vte-$(VTE_VERSION).tar.xz)
	$(call EXTRACT_TAR,vte-$(VTE_VERSION).tar.xz,vte-$(VTE_VERSION),vte)
	rm -rf $(BUILD_WORK)/vte/build && mkdir -p $(BUILD_WORK)/vte/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/vte/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/vte/.build_complete),)
vte:
	@echo "Using previously built vte."
else
vte: vte-setup gtk4 libxml2 pcre2 gnutls icu4c
	cd $(BUILD_WORK)/vte/build && meson \
		--cross-file cross.txt \
		-D_systemd=false \
		-Dgtk3=false \
		-Dgtk4=true \
		-Dvapi=false \
		-Dgir=false \
		-Dgnutls=true \
		-Ddocs=false \
		-D_b_symbolic_functions=false \
		-Dicu=true \
		..
	+ninja -C $(BUILD_WORK)/vte/build
	+DESTDIR="$(BUILD_STAGE)/vte" ninja -C $(BUILD_WORK)/vte/build install
	$(call AFTER_BUILD,copy)
endif

vte-package: vte-stage
	rm -rf $(BUILD_DIST)/libvte-2.91-gtk4-0 $(BUILD_DIST)/libvte-2.91-dev
	mkdir -p $(BUILD_DIST)/libvte-2.91-gtk4-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libvte-2.91-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# libvte-2.91-gtk4-0 (GTK4 runtime dylib + shell-integration helper)
	cp -a $(BUILD_STAGE)/vte/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libvte-2.91-gtk4.0.dylib $(BUILD_DIST)/libvte-2.91-gtk4-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	if [ -d "$(BUILD_STAGE)/vte/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec" ]; then \
		cp -a $(BUILD_STAGE)/vte/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec $(BUILD_DIST)/libvte-2.91-gtk4-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
	fi

	# libvte-2.91-dev (headers, symlinks, .pc) — GTK4 flavour only by default
	cp -a $(BUILD_STAGE)/vte/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/!(libvte-2.91-gtk4.0.dylib) $(BUILD_DIST)/libvte-2.91-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/vte/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/libvte-2.91-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	# --- GTK3 re-enable (when -Dgtk3=true): also stage the GTK3 dylib into libvte-2.91-0 ---
	# mkdir -p $(BUILD_DIST)/libvte-2.91-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	# cp -a $(BUILD_STAGE)/vte/.../lib/libvte-2.91.0.dylib $(BUILD_DIST)/libvte-2.91-0/.../lib
	# $(call SIGN,libvte-2.91-0,general.xml); $(call PACK,libvte-2.91-0,DEB_VTE_V)

	$(call SIGN,libvte-2.91-gtk4-0,general.xml)
	$(call PACK,libvte-2.91-gtk4-0,DEB_VTE_V)
	$(call PACK,libvte-2.91-dev,DEB_VTE_V)
	rm -rf $(BUILD_DIST)/libvte-2.91-gtk4-0 $(BUILD_DIST)/libvte-2.91-dev

.PHONY: vte vte-package
