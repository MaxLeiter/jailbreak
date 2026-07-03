ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# gnome-desktop.mk — libgnome-desktop-4 (shared desktop utilities: thumbnails, GnomeBG,
# GnomeXkbInfo, GnomeLanguages). Required by nautilus. The heaviest leaf of the Files tree:
# it drags iso-codes (GnomeLanguages) and libxkbregistry (GnomeXkbInfo).
#
# DEPENDS (target): gtk4 (gtk-builder) + gsettings-desktop-schemas + iso-codes +
#   libxkbcommon (MUST be built with -Denable-xkbregistry=true — the Wayland track's
#   libxkbcommon.mk currently disables it; coordinate to flip that on, it only adds a
#   libxml2 dep which is already prebuilt).
# VERIFY before build: soname (libgnome-desktop-4.2.dylib?) and meson option names
#   (-Dudev=disabled for darwin, -Dbuild_gtk4=true, -Dintrospection=false).
#
# DRAFT — Phase 1, NOT built/verified. Mirrors recipes/pango.mk style.

SUBPROJECTS           += gnome-desktop
GNOME-DESKTOP_MAJOR_V := 44
GNOME-DESKTOP_VERSION := $(GNOME-DESKTOP_MAJOR_V).1
DEB_GNOME-DESKTOP_V   ?= $(GNOME-DESKTOP_VERSION)+ios1

gnome-desktop-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/gnome-desktop/$(GNOME-DESKTOP_MAJOR_V)/gnome-desktop-$(GNOME-DESKTOP_VERSION).tar.xz)
	$(call EXTRACT_TAR,gnome-desktop-$(GNOME-DESKTOP_VERSION).tar.xz,gnome-desktop-$(GNOME-DESKTOP_VERSION),gnome-desktop)
	# iOS/introspection=false fix: gnome.generate_gir() is called unconditionally in
	# libgnome-desktop/{,gnome-bg/,gnome-rr/}meson.build, but libgnome_desktop_base_gir
	# is only assigned under `if get_option('introspection')`, so the subdirs' gir
	# generation hits "Unknown variable" when introspection is off. The helper drops the
	# base dep's lone gir sources ref and gates the two subdir generate_gir blocks
	# (idempotent). Script is mounted at /work/recipes by build-gnome.sh.
	bash /work/recipes/gnome-desktop-introspection-fix.sh $(BUILD_WORK)/gnome-desktop
	mkdir -p $(BUILD_WORK)/gnome-desktop/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/gnome-desktop/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/gnome-desktop/.build_complete),)
gnome-desktop:
	@echo "Using previously built gnome-desktop."
else
gnome-desktop: gnome-desktop-setup gtk4 gsettings-desktop-schemas iso-codes libxkbcommon xkeyboard-config
	cd $(BUILD_WORK)/gnome-desktop/build && meson \
		--cross-file cross.txt \
		-Dintrospection=false \
		-Dbuild_gtk4=true \
		-Dlegacy_library=false \
		-Ddesktop_docs=false \
		-Dgtk_doc=false \
		-Dudev=disabled \
		..
	+ninja -C $(BUILD_WORK)/gnome-desktop/build
	+DESTDIR="$(BUILD_STAGE)/gnome-desktop" ninja -C $(BUILD_WORK)/gnome-desktop/build install
	$(call AFTER_BUILD,copy)
endif

gnome-desktop-package: gnome-desktop-stage
	rm -rf $(BUILD_DIST)/libgnome-desktop-4-2 $(BUILD_DIST)/libgnome-desktop-dev
	mkdir -p $(BUILD_DIST)/libgnome-desktop-4-2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libgnome-desktop-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# libgnome-desktop-4-2 (runtime dylib + share data)
	cp -a $(BUILD_STAGE)/gnome-desktop/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libgnome-desktop-4.*.dylib $(BUILD_DIST)/libgnome-desktop-4-2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	if [ -d "$(BUILD_STAGE)/gnome-desktop/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share" ]; then \
		cp -a $(BUILD_STAGE)/gnome-desktop/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share $(BUILD_DIST)/libgnome-desktop-4-2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
	fi

	# libgnome-desktop-dev (headers, symlink, .pc)
	cp -a $(BUILD_STAGE)/gnome-desktop/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/!(libgnome-desktop-4.*.dylib) $(BUILD_DIST)/libgnome-desktop-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/gnome-desktop/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/libgnome-desktop-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	$(call SIGN,libgnome-desktop-4-2,general.xml)
	$(call PACK,libgnome-desktop-4-2,DEB_GNOME-DESKTOP_V)
	$(call PACK,libgnome-desktop-dev,DEB_GNOME-DESKTOP_V)
	rm -rf $(BUILD_DIST)/libgnome-desktop-4-2 $(BUILD_DIST)/libgnome-desktop-dev

.PHONY: gnome-desktop gnome-desktop-package
