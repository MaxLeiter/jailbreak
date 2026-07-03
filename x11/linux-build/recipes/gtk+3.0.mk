ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

SUBPROJECTS    += gtk+3.0
GTK_MAJOR_V    := 3.24
GTK_VERSION    := $(GTK_MAJOR_V).38
DEB_LIBGTK_V   ?= $(GTK_VERSION)+ios1
# libgtkintl: the proxy-libintl symbol shim (see gtkintl_shim.c). Built during the
# gtk+3.0 step and shipped as its own deb; both GTK3 and GTK4 relink onto it.
DEB_LIBGTKINTL_V ?= 1.0

gtk+3.0-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://ftp.gnome.org/pub/gnome/sources/gtk+/$(GTK_MAJOR_V)/gtk+-$(GTK_VERSION).tar.xz)
	$(call EXTRACT_TAR,gtk+-$(GTK_VERSION).tar.xz,gtk+-$(GTK_VERSION),gtk+3.0)
	# GTK's meson force-sets `wayland_enabled = false` AND `x11_enabled = false` inside its
	# `if os_darwin` block, overriding our -D backend options, so a darwin cross-build (our
	# iOS target) would end up with no GDK backend. No-op both overrides (rewrite them to
	# self-assignments) so the multi-backend x11 + wayland build takes effect — GDK then
	# picks the backend at runtime via GDK_BACKEND. The iosc shell exports
	# GDK_BACKEND=wayland, so GTK3 apps run as native Wayland clients; the X11 backend stays
	# available as a fallback. The wayland deps (wayland-client/egl/cursor, wayland-protocols,
	# xkbcommon) + a host wayland-scanner + the linux/input-event-codes + sys/sysmacros shims
	# are staged by build-gtk.sh — the very same prerequisites GTK4's wayland backend uses.
	# (The win32 wayland-off line is neutralised too; harmless, we never target win32.)
	sed -i 's/wayland_enabled = false/wayland_enabled = wayland_enabled/g' $(BUILD_WORK)/gtk+3.0/meson.build
	sed -i 's/x11_enabled = false/x11_enabled = x11_enabled/g' $(BUILD_WORK)/gtk+3.0/meson.build
	# Drop the AT-SPI accessibility bridge (atk-bridge-2.0): it would pull the whole
	# at-spi2 + D-Bus stack, which we don't have on iOS (and there's no a11y bus to
	# connect to at runtime). GTK apps run fine without it.
	sed -i "s|dependency('atk-bridge-2.0', version: at_spi2_atk_req)|dependency('atk-bridge-2.0', version: at_spi2_atk_req, required: false)|" $(BUILD_WORK)/gtk+3.0/meson.build
	sed -i "/atk_pkgs += \['atk-bridge-2.0'\]/d" $(BUILD_WORK)/gtk+3.0/meson.build
	sed -i 's|#include <atk-bridge.h>|/* atk-bridge.h removed for iOS (no AT-SPI) */|' $(BUILD_WORK)/gtk+3.0/gtk/a11y/gtkaccessibility.c
	sed -i 's|atk_bridge_adaptor_init (NULL, NULL);|/* atk_bridge_adaptor_init disabled for iOS */|' $(BUILD_WORK)/gtk+3.0/gtk/a11y/gtkaccessibility.c
	rm -rf $(BUILD_WORK)/gtk+3.0/build
	mkdir -p $(BUILD_WORK)/gtk+3.0/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/gtk+3.0/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/gtk+3.0/.build_complete),)
gtk+3.0:
	@echo "Using previously built gtk+3.0."
else
gtk+3.0: gtk+3.0-setup glib2.0 pango gdk-pixbuf atk cairo libepoxy fribidi \
		libx11 libxext libxrender libxi libxrandr libxcursor libxfixes \
		libxdamage libxinerama
	cd $(BUILD_WORK)/gtk+3.0/build && meson \
		--cross-file cross.txt \
		-Dx11_backend=true \
		-Dwayland_backend=true \
		-Dbroadway_backend=false \
		-Dquartz_backend=false \
		-Dprint_backends=file \
		-Dintrospection=false \
		-Dgtk_doc=false \
		-Dman=false \
		-Ddemos=false \
		-Dexamples=false \
		-Dtests=false \
		-Dinstalled_tests=false \
		-Dcolord=no \
		-Dxinerama=yes \
		-Dcloudproviders=false \
		-Dprofiler=false \
		..
	cd $(BUILD_WORK)/gtk+3.0/build; \
		DESTDIR="$(BUILD_STAGE)/gtk+3.0" meson install
	# GTK's meson links libgtk-3, libgdk-3 and the gtk-* tools against its bundled
	# proxy-libintl (@rpath/libintl.dylib), whose exports are renamed g_libintl_*. We
	# can't ship libintl.dylib (gettext owns that path), and the system libintl.8 only
	# has libintl_* (not g_libintl_*), so a bare redirect makes dyld abort at load
	# ("Symbol not found: _g_libintl_gettext"). We relink every GTK mach-o that imports
	# the proxy onto @rpath/libgtkintl.dylib — a shim built in the package step that
	# reexports libintl.8 and re-adds the g_libintl_* names (see gtkintl_shim.c).
	# (install_name_tool -change rewrites the path string only; the shim need not exist
	# yet.) Then drop the unshippable proxy.
	for f in $$(find $(BUILD_STAGE)/gtk+3.0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
			$(BUILD_STAGE)/gtk+3.0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin -type f 2>/dev/null); do \
		$(I_N_T) -change @rpath/libintl.dylib @rpath/libgtkintl.dylib $$f 2>/dev/null || true; \
	done
	rm -f $(BUILD_STAGE)/gtk+3.0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libintl.dylib \
		$(BUILD_STAGE)/gtk+3.0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libintl.a
	$(call AFTER_BUILD,copy)
endif

gtk+3.0-package: gtk+3.0-stage
	# gtk+3.0.mk Package Structure
	rm -rf $(BUILD_DIST)/libgtk-3-0 $(BUILD_DIST)/libgtk-3-dev $(BUILD_DIST)/gtk-3-bin $(BUILD_DIST)/libgtkintl
	mkdir -p $(BUILD_DIST)/libgtk-3-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/{lib,share} \
		$(BUILD_DIST)/libgtk-3-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/gtk-3-bin/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX) \
		$(BUILD_DIST)/libgtkintl/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# gtk+3.0.mk Build libgtkintl (the proxy-libintl shim GTK3/GTK4 are relinked onto;
	# see gtkintl_shim.c). Compiled here in the package step so it is always produced
	# even on a cached gtk+3.0 build. -Wl,-reexport-lintl pulls in libintl.8 so real
	# libintl_* still resolve; the wrappers add the g_libintl_* names dyld needs.
	$(CC) -dynamiclib -fno-common -install_name @rpath/libgtkintl.dylib \
		$(BUILD_TOOLS)/gtkintl_shim.c \
		-L$(BUILD_BASE)/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib -Wl,-reexport-lintl \
		-o $(BUILD_DIST)/libgtkintl/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libgtkintl.dylib

	# gtk+3.0.mk Prep libgtk-3-0 (runtime dylibs + loadable modules + data)
	cp -a $(BUILD_STAGE)/gtk+3.0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/*-3.0.dylib $(BUILD_DIST)/libgtk-3-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	if [ -d "$(BUILD_STAGE)/gtk+3.0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/gtk-3.0" ]; then \
		cp -a $(BUILD_STAGE)/gtk+3.0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/gtk-3.0 $(BUILD_DIST)/libgtk-3-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib; \
	fi
	for d in gtk-3.0 themes icons glib-2.0 locale; do \
		if [ -d "$(BUILD_STAGE)/gtk+3.0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/$$d" ]; then \
			cp -a $(BUILD_STAGE)/gtk+3.0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/$$d $(BUILD_DIST)/libgtk-3-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share; \
		fi; \
	done

	# gtk+3.0.mk Prep libgtk-3-dev (headers, symlinks, .pc)
	cp -a $(BUILD_STAGE)/gtk+3.0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/libgtk-3-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/gtk+3.0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/!(*-3.0.dylib|gtk-3.0) $(BUILD_DIST)/libgtk-3-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# gtk+3.0.mk Prep gtk-3-bin (tools)
	if [ -d "$(BUILD_STAGE)/gtk+3.0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin" ]; then \
		cp -a $(BUILD_STAGE)/gtk+3.0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin $(BUILD_DIST)/gtk-3-bin/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
	fi

	# gtk+3.0.mk Sign
	$(call SIGN,libgtk-3-0,general.xml)
	$(call SIGN,gtk-3-bin,general.xml)
	$(call SIGN,libgtkintl,general.xml)

	# gtk+3.0.mk Make .debs
	$(call PACK,libgtk-3-0,DEB_LIBGTK_V)
	$(call PACK,libgtk-3-dev,DEB_LIBGTK_V)
	$(call PACK,gtk-3-bin,DEB_LIBGTK_V)
	$(call PACK,libgtkintl,DEB_LIBGTKINTL_V)

	# gtk+3.0.mk Build cleanup
	rm -rf $(BUILD_DIST)/libgtk-3-0 $(BUILD_DIST)/libgtk-3-dev $(BUILD_DIST)/gtk-3-bin $(BUILD_DIST)/libgtkintl

.PHONY: gtk+3.0 gtk+3.0-package
