ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# libadwaita.mk — GNOME's GTK4 platform library (Adwaita widgets/styling). The keystone for
# every modern GNOME app's look. GNOME 46 generation = libadwaita 1.5.0.
#
# DEPENDS (target): gtk4 (gtk-builder owns it) + appstream (our recipe; libadwaita 1.4
#   src/meson.build requires it) + fribidi/glib (in stack).
# BUILD-HOST TOOL: sassc — libadwaita compiles its SCSS stylesheet at build time. sassc runs
#   on the LINUX BUILD HOST, so it is NOT a cross/target dep: add `sassc` to the Dockerfile
#   apt line (build-essential layer) rather than a recipe.
# NOTE: the `gtk4` make-target name + the libgtk-4-* deb names below must match gtk-builder's
#   actual GTK4 recipe/package names — reconcile before building.
#
# DRAFT — Phase 1, NOT built/verified. Mirrors recipes/pango.mk style.

SUBPROJECTS        += libadwaita
LIBADWAITA_MAJOR_V := 1.5
LIBADWAITA_VERSION := $(LIBADWAITA_MAJOR_V).0
DEB_LIBADWAITA_V   ?= $(LIBADWAITA_VERSION)+ios1

libadwaita-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/libadwaita/$(LIBADWAITA_MAJOR_V)/libadwaita-$(LIBADWAITA_VERSION).tar.xz)
	$(call EXTRACT_TAR,libadwaita-$(LIBADWAITA_VERSION).tar.xz,libadwaita-$(LIBADWAITA_VERSION),libadwaita)
	# Our cross file declares system='darwin' (it IS Darwin/iOS), so libadwaita's settings code
	# takes its macOS branch: dependency('appleframeworks', modules:[AppKit,Foundation]) +
	# adw-settings-impl-macos.c. AppKit does not exist on iOS. Force the condition false so the
	# build falls through to the `else` branch (adw-settings-impl-portal.c — the standard Linux
	# xdg-desktop-portal backend, correct for our X11/GTK-on-iOS environment).
	sed -i "s/if target_system == 'darwin'/if target_system == '_ios_force_portal'/" $(BUILD_WORK)/libadwaita/src/meson.build
	# The C sources gate the same macOS backend on #ifdef __APPLE__ (independently of meson):
	# adw-settings-impl-private.h declares AdwSettingsImplMacOS (not ...Portal) and adw-settings.c
	# calls adw_settings_impl_macos_new(). Force both off __APPLE__ so the #else (portal) branch
	# is taken, matching the meson source selection above. Each file has exactly one such gate.
	sed -i "s/#ifdef __APPLE__/#if 0 \/* iOS: use portal settings backend *\//" $(BUILD_WORK)/libadwaita/src/adw-settings-impl-private.h
	sed -i "s/#ifdef __APPLE__/#if 0 \/* iOS: use portal settings backend *\//" $(BUILD_WORK)/libadwaita/src/adw-settings.c
	mkdir -p $(BUILD_WORK)/libadwaita/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/libadwaita/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/libadwaita/.build_complete),)
libadwaita:
	@echo "Using previously built libadwaita."
else
libadwaita: libadwaita-setup gtk4 appstream
	cd $(BUILD_WORK)/libadwaita/build && meson \
		--cross-file cross.txt \
		-Dintrospection=disabled \
		-Dvapi=false \
		-Dtests=false \
		-Dexamples=false \
		-Dgtk_doc=false \
		..
	+ninja -C $(BUILD_WORK)/libadwaita/build
	+DESTDIR="$(BUILD_STAGE)/libadwaita" ninja -C $(BUILD_WORK)/libadwaita/build install
	$(call AFTER_BUILD,copy)
endif

libadwaita-package: libadwaita-stage
	rm -rf $(BUILD_DIST)/libadwaita-1-0 $(BUILD_DIST)/libadwaita-1-dev
	mkdir -p $(BUILD_DIST)/libadwaita-1-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libadwaita-1-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# libadwaita-1-0 (runtime dylib + any installed data)
	cp -a $(BUILD_STAGE)/libadwaita/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libadwaita-1.0.dylib $(BUILD_DIST)/libadwaita-1-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# libadwaita-1-dev (headers, symlink, .pc)
	cp -a $(BUILD_STAGE)/libadwaita/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/!(libadwaita-1.0.dylib) $(BUILD_DIST)/libadwaita-1-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/libadwaita/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/libadwaita-1-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	$(call SIGN,libadwaita-1-0,general.xml)
	$(call PACK,libadwaita-1-0,DEB_LIBADWAITA_V)
	$(call PACK,libadwaita-1-dev,DEB_LIBADWAITA_V)
	rm -rf $(BUILD_DIST)/libadwaita-1-0 $(BUILD_DIST)/libadwaita-1-dev

.PHONY: libadwaita libadwaita-package
