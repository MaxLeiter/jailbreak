ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

SUBPROJECTS   += gtk4
GTK4_MAJOR_V  := 4.14
GTK4_VERSION  := $(GTK4_MAJOR_V).5
DEB_LIBGTK4_V ?= $(GTK4_VERSION)

gtk4-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://ftp.gnome.org/pub/gnome/sources/gtk/$(GTK4_MAJOR_V)/gtk-$(GTK4_VERSION).tar.xz)
	$(call EXTRACT_TAR,gtk-$(GTK4_VERSION).tar.xz,gtk-$(GTK4_VERSION),gtk4)
	# iOS: GTK4's meson.build force-sets `wayland_enabled = false` in the `if os_darwin`
	# block, overriding -Dwayland-backend=true (x11 stays; only wayland is killed on
	# darwin). No-op it so the multi-backend (x11 + wayland) build takes effect — the
	# wayland deps (wayland-client/egl, wayland-protocols, xkbcommon) are staged from W0.
	sed -i 's/wayland_enabled = false/wayland_enabled = wayland_enabled/g' $(BUILD_WORK)/gtk4/meson.build
	rm -rf $(BUILD_WORK)/gtk4/build
	mkdir -p $(BUILD_WORK)/gtk4/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/gtk4/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/gtk4/.build_complete),)
gtk4:
	@echo "Using previously built gtk4."
else
gtk4: gtk4-setup glib2.0 pango gdk-pixbuf cairo libepoxy fribidi harfbuzz graphene \
		libpng16 libjpeg-turbo libtiff \
		libx11 libxext libxi libxrandr libxcursor libxfixes libxdamage libxinerama
	cd $(BUILD_WORK)/gtk4/build && meson \
		--cross-file cross.txt \
		-Dx11-backend=true \
		-Dwayland-backend=true \
		-Dbroadway-backend=false \
		-Dmacos-backend=false \
		-Dwin32-backend=false \
		-Dvulkan=disabled \
		-Dmedia-gstreamer=disabled \
		-Dprint-cups=disabled \
		-Dintrospection=disabled \
		-Dbuild-demos=false \
		-Dbuild-testsuite=false \
		-Dbuild-tests=false \
		-Dbuild-examples=false \
		-Dsysprof=disabled \
		-Dcloudproviders=disabled \
		-Dcolord=disabled \
		-Ddocumentation=false \
		-Dman-pages=false \
		..
	cd $(BUILD_WORK)/gtk4/build; \
		DESTDIR="$(BUILD_STAGE)/gtk4" meson install
	# Like GTK3, GTK4 links its bundled proxy-libintl (@rpath/libintl.dylib, exports
	# renamed g_libintl_*) which we can't ship and the system libintl.8 doesn't provide.
	# Relink every GTK4 mach-o onto the libgtkintl shim (built + packaged by gtk+3.0.mk;
	# install_name_tool -change needs only the path, not the file). Drop the proxy.
	for f in $$(find $(BUILD_STAGE)/gtk4/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
			$(BUILD_STAGE)/gtk4/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin -type f 2>/dev/null); do \
		$(I_N_T) -change @rpath/libintl.dylib @rpath/libgtkintl.dylib $$f 2>/dev/null || true; \
	done
	rm -f $(BUILD_STAGE)/gtk4/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libintl.dylib \
		$(BUILD_STAGE)/gtk4/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libintl.a
	$(call AFTER_BUILD,copy)
endif

gtk4-package: gtk4-stage
	# gtk4.mk Package Structure
	rm -rf $(BUILD_DIST)/libgtk-4-1 $(BUILD_DIST)/libgtk-4-dev $(BUILD_DIST)/gtk-4-bin
	mkdir -p $(BUILD_DIST)/libgtk-4-1/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/{lib,share} \
		$(BUILD_DIST)/libgtk-4-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/gtk-4-bin/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	# gtk4.mk Prep libgtk-4-1 (runtime dylib + modules + data); real lib is
	# libgtk-4.1.dylib, the bare libgtk-4.dylib symlink goes to -dev.
	cp -a $(BUILD_STAGE)/gtk4/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libgtk-4.[0-9]*.dylib $(BUILD_DIST)/libgtk-4-1/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	if [ -d "$(BUILD_STAGE)/gtk4/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/gtk-4.0" ]; then \
		cp -a $(BUILD_STAGE)/gtk4/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/gtk-4.0 $(BUILD_DIST)/libgtk-4-1/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib; \
	fi
	for d in gtk-4.0 themes icons glib-2.0 locale; do \
		if [ -d "$(BUILD_STAGE)/gtk4/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/$$d" ]; then \
			cp -a $(BUILD_STAGE)/gtk4/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/$$d $(BUILD_DIST)/libgtk-4-1/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share; \
		fi; \
	done

	# gtk4.mk Default GSK_RENDERER=cairo. GTK4's GL renderer fatally dlopens desktop
	# OpenGL.framework (absent on iOS); cairo renders in software and works today.
	# Drop this once a GLES path (ANGLE->Metal) lands libEGL/libGLESv2.
	mkdir -p $(BUILD_DIST)/libgtk-4-1/$(MEMO_PREFIX)/etc/profile.d
	printf 'export GSK_RENDERER=cairo\n' \
		> $(BUILD_DIST)/libgtk-4-1/$(MEMO_PREFIX)/etc/profile.d/10-gtk-renderer.sh
	chmod 0755 $(BUILD_DIST)/libgtk-4-1/$(MEMO_PREFIX)/etc/profile.d/10-gtk-renderer.sh

	# gtk4.mk Prep libgtk-4-dev (headers, symlinks, .pc)
	cp -a $(BUILD_STAGE)/gtk4/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/libgtk-4-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/gtk4/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/!(libgtk-4.[0-9]*.dylib|gtk-4.0) $(BUILD_DIST)/libgtk-4-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# gtk4.mk Prep gtk-4-bin (tools)
	if [ -d "$(BUILD_STAGE)/gtk4/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin" ]; then \
		cp -a $(BUILD_STAGE)/gtk4/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin $(BUILD_DIST)/gtk-4-bin/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
	fi

	# gtk4.mk Sign
	$(call SIGN,libgtk-4-1,general.xml)
	$(call SIGN,gtk-4-bin,general.xml)

	# gtk4.mk Make .debs
	$(call PACK,libgtk-4-1,DEB_LIBGTK4_V)
	$(call PACK,libgtk-4-dev,DEB_LIBGTK4_V)
	$(call PACK,gtk-4-bin,DEB_LIBGTK4_V)

	# gtk4.mk Build cleanup
	rm -rf $(BUILD_DIST)/libgtk-4-1 $(BUILD_DIST)/libgtk-4-dev $(BUILD_DIST)/gtk-4-bin

.PHONY: gtk4 gtk4-package
