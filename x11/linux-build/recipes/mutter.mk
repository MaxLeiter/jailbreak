ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# mutter.mk — cross-build mutter 46 for rootless iOS (the GNOME-Shell compositor; bundles
# Cogl/Clutter/Mtk). Built as a WAYLAND compositor (per the GPU/iosc direction — X11-WM
# compositing can't be GPU-accelerated on a software Xios; see docs/gjs-plan.md). native
# (KMS/DRM/GBM/logind) backend OFF; GL via ANGLE EGL/GLES2 (egl staged into build_base by
# build-mutter.sh). introspection is OFF here — cross can't run the gir dumper; the
# Meta/Clutter/Cogl typelibs are scanned ON-DEVICE afterwards (Design A, gir-build-ondevice.sh).
#
# NOTE: mutter has never been ported to Darwin/iOS — expect portability patches accreting in
# the sed/patch block below as the build surfaces them.

SUBPROJECTS    += mutter
MUTTER_MAJOR_V := 46
# libmutter's ABI/API version (soname + $libdir/mutter-N data dir) is 14, NOT the 46
# release number — the cogl/clutter/mtk dylibs + plugins install to lib/mutter-14/.
MUTTER_API_V   := 14
MUTTER_VERSION := $(MUTTER_MAJOR_V).0
DEB_MUTTER_V   ?= $(MUTTER_VERSION)

# The dead X11/xcb closure to weak-link in mutter-package (see the mutter-package weaken step).
# EVERYTHING X11/xcb that libmutter/cogl/mtk pull in — EXCEPT libxkbcommon.0, which the Wayland
# keymap path uses for real and must stay a strong (present-on-device) dependency.
MUTTER_X11_WEAK := libX11.6.dylib libX11-xcb.1.dylib libXext.6.dylib libXfixes.3.dylib \
	libXdamage.1.dylib libXcomposite.1.dylib libXrandr.2.dylib libXtst.6.dylib libXi.6.dylib \
	libXinerama.1.dylib libXcursor.1.dylib libxkbfile.1.dylib libxkbcommon-x11.0.dylib \
	libxcb.1.dylib libxcb-randr.0.dylib libxcb-res.0.dylib

mutter-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/mutter/$(MUTTER_MAJOR_V)/mutter-$(MUTTER_VERSION).tar.xz)
	$(call EXTRACT_TAR,mutter-$(MUTTER_VERSION).tar.xz,mutter-$(MUTTER_VERSION),mutter)
	# --- iOS portability patches (accreting) ---
	# libei/libeis (input emulation) are dependency()'d unconditionally but only USED under
	# HAVE_REMOTE_DESKTOP (off here) — make them non-required so configure proceeds without them.
	sed -i "s/dependency('libeis-1.0', version: libei_req)/dependency('libeis-1.0', version: libei_req, required: false)/" $(BUILD_WORK)/mutter/meson.build
	sed -i "s/dependency('libei-1.0', version: libei_req)/dependency('libei-1.0', version: libei_req, required: false)/" $(BUILD_WORK)/mutter/meson.build
	# MetaBackendIOS integration: if the x11 repo is mounted at /work/x11 (build-mutter.sh
	# -v x11:/work/x11), stage the whole iOS/IOSurface backend + apply the 5 integration patches
	# (incl. meta-context-main-ios-backend.patch, which gives the wayland+no-native branch a REAL
	# MetaBackendIOS instead of a stub). Else fall back to the typelib-only build: give the
	# dangling `else` a body so `make mutter` still configures without the backend.
	@if [ -d /work/x11/wayland ] && [ -f /work/x11/wayland/out/libxios_glue.a ]; then \
		echo "==> integrating MetaBackendIOS (real backend from /work/x11)"; \
		bash /work/x11/linux-build/integrate-ios-backend.sh $(BUILD_WORK)/mutter /work/x11; \
	else \
		echo "==> WARN: /work/x11 not mounted — STOCK typelib-only mutter (NO iOS backend)"; \
		perl -0pi -e 's{return create_native_backend \(context, error\);\n#endif /\* HAVE_NATIVE_BACKEND \*/}{return create_native_backend (context, error);\n#else\n      g_assert_not_reached ();\n      return NULL;\n#endif /* HAVE_NATIVE_BACKEND */}' $(BUILD_WORK)/mutter/src/core/meta-context-main.c; \
	fi
	# meta-context-main.c uses sd_pid_get_user_unit (systemd) guarded only by HAVE_WAYLAND, not
	# HAVE_LIBSYSTEMD — undefined symbol when systemd is off. Guard it; fall back to MANDATORY X11
	# policy when systemd is absent (the correct no-logind behaviour on iOS).
	perl -0pi -e 's{else if \(sd_pid_get_user_unit \(0, &unit\) < 0\)\n        return META_X11_DISPLAY_POLICY_MANDATORY;\n      else\n        return META_X11_DISPLAY_POLICY_ON_DEMAND;}{else\n        \{\n#ifdef HAVE_LIBSYSTEMD\n          if (sd_pid_get_user_unit (0, &unit) < 0)\n            return META_X11_DISPLAY_POLICY_MANDATORY;\n          else\n            return META_X11_DISPLAY_POLICY_ON_DEMAND;\n#else\n          (void) unit;\n          return META_X11_DISPLAY_POLICY_MANDATORY;\n#endif\n        \}}' $(BUILD_WORK)/mutter/src/core/meta-context-main.c
	rm -rf $(BUILD_WORK)/mutter/build && mkdir -p $(BUILD_WORK)/mutter/build
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
	c_args = ['-DSOCK_CLOEXEC=0']\n \
	[binaries]\n \
	c = '$(CC)'\n \
	cpp = '$(CXX)'\n \
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n \
	exe_wrapper = '/bin/true'\n" > $(BUILD_WORK)/mutter/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/mutter/.build_complete),)
mutter:
	@echo "Using previously built mutter."
else
# NOTE: wayland/wayland-protocols are NOT prereqs — they're already staged in build_base by the
# Wayland (W0) track's Darwin-patched recipe. Listing them here would trigger an unpatched rebuild
# (fails on Linux SOCK_CLOEXEC/timerfd). Same for the gtk4 stack: pre-built, used from build_base.
mutter: mutter-setup glib2.0 gtk4 graphene gdk-pixbuf pango cairo fribidi harfbuzz \
		gsettings-desktop-schemas json-glib libxkbcommon lcms2 colord \
		libpixman libxcomposite libdrm libei \
		libx11 libxext libxi libxrandr libxcursor libxfixes libxdamage libxinerama
	cd $(BUILD_WORK)/mutter/build && meson \
		--cross-file cross.txt \
		-Dwayland=true \
		-Dxwayland=false \
		-Dsystemd=false \
		-Dnative_backend=false \
		-Dudev=false \
		-Dopengl=false \
		-Dglx=false \
		-Degl=true \
		-Dgles2=true \
		-Dintrospection=false \
		-Dprofiler=false \
		-Dremote_desktop=false \
		-Dwayland_eglstream=false \
		-Degl_device=false \
		-Dlibgnome_desktop=false \
		-Dsound_player=false \
		-Dstartup_notification=false \
		-Dsm=false \
		-Dlibwacom=false \
		-Dlibdisplay_info=disabled \
		-Dtests=false \
		-Dcogl_tests=false \
		-Dclutter_tests=false \
		-Dcore_tests=false \
		-Dnative_tests=false \
		-Dtty_tests=false \
		-Dkvm_tests=false \
		-Dinstalled_tests=false \
		-Ddocs=false \
		..
	+ninja -C $(BUILD_WORK)/mutter/build
	+DESTDIR="$(BUILD_STAGE)/mutter" ninja -C $(BUILD_WORK)/mutter/build install
	# Like GTK4, mutter links GTK's bundled proxy-libintl (@rpath/libintl.dylib, g_libintl_*
	# symbols) — relink every mutter mach-o onto the libgtkintl shim, drop the proxy.
	for f in $$(find $(BUILD_STAGE)/mutter/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
			$(BUILD_STAGE)/mutter/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin -type f 2>/dev/null); do \
		$(I_N_T) -change @rpath/libintl.dylib @rpath/libgtkintl.dylib $$f 2>/dev/null || true; \
	done
	rm -f $(BUILD_STAGE)/mutter/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libintl.dylib
	$(call AFTER_BUILD,copy)
endif

mutter-package: mutter-stage
	rm -rf $(BUILD_DIST)/libmutter-14-0 $(BUILD_DIST)/libmutter-14-dev
	mkdir -p $(BUILD_DIST)/libmutter-14-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libmutter-14-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/{include,lib}

	# runtime: the top-level libmutter-14 dylib + the lib/mutter-14/ data dir which holds the
	# cogl/clutter/cogl-pango/mtk dylibs and the plugins (this is the API-version dir, mutter-14).
	cp -a $(BUILD_STAGE)/mutter/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libmutter*.dylib $(BUILD_DIST)/libmutter-14-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib 2>/dev/null || true
	if [ -d "$(BUILD_STAGE)/mutter/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/mutter-$(MUTTER_API_V)" ]; then \
		cp -a $(BUILD_STAGE)/mutter/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/mutter-$(MUTTER_API_V) $(BUILD_DIST)/libmutter-14-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib; \
	fi

	# runtime DATA: mutter installs share/ (the org.gnome.mutter{,.wayland} GSettings schemas —
	# WITHOUT which mutter aborts "Settings schema 'org.gnome.mutter' is not installed" — plus the
	# GConf convert file, gnome-control-center keybinding lists, and translations). The earlier
	# packaging dropped this whole tree. Ship it (skip man/ — the minos stamper double-zsts it).
	# build_info/libmutter-14-0.postinst runs glib-compile-schemas on-device (like the gtk4 deb).
	mkdir -p $(BUILD_DIST)/libmutter-14-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share
	for d in glib-2.0 GConf gnome-control-center locale; do \
		if [ -d "$(BUILD_STAGE)/mutter/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/$$d" ]; then \
			cp -a $(BUILD_STAGE)/mutter/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/$$d $(BUILD_DIST)/libmutter-14-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/; \
		fi; \
	done

	# dev: headers + .pc (needed for the on-device introspection scan)
	cp -a $(BUILD_STAGE)/mutter/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/libmutter-14-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX) 2>/dev/null || true
	cp -a $(BUILD_STAGE)/mutter/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig $(BUILD_DIST)/libmutter-14-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib 2>/dev/null || true

	# --- ANGLE rpath (dyld-landmine #1): the mutter dylibs load @rpath/libGLESv2 + libEGL (Cogl
	# links ANGLE GLES/EGL), but gnome-shell — the process that dlopens libmutter — has no
	# /var/jb/lib/angle rpath, so @rpath only resolves through libmutter's OWN LC_RPATH. Add it to
	# every mutter dylib. BEFORE the weaken (macho-weaken is byte-preserving and transparent to an
	# extra LC_RPATH) and BEFORE SIGN (install_name_tool invalidates the signature; SIGN re-covers).
	for f in $$(find $(BUILD_DIST)/libmutter-14-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib -type f -name '*.dylib'); do \
		$(I_N_T) -add_rpath /var/jb/lib/angle $$f 2>/dev/null || true; \
	done

	# --- weak-link the DEAD X11/xcb closure so libmutter loads on an X11-free iPad -------------
	# mutter 46 cannot be built without X11 ("For now always require X11 support" — meson.build
	# hardcodes have_x11=true; there is no x11 meson option, only xwayland). core/frame.c and
	# core/keybindings.c are in the ALWAYS-compiled source list and use X11 unconditionally, so
	# libmutter/cogl/mtk link the whole X11/xcb closure even though it is dead on iOS (we run
	# Wayland + MetaBackendIOS, never MetaBackendX11). Those libs (libxcb-randr.0, libxcb-res.0,
	# libX11-xcb.1, libX11.6, ...) do not exist on the device, so dyld hard-fails at load before
	# the backend runs. Flip their LC_LOAD_DYLIB -> LC_LOAD_WEAK_DYLIB: dyld then tolerates the
	# libs being absent and binds their (never-called) symbols to 0. libxkbcommon.0 stays STRONG
	# (Wayland keymap — live code). Byte-length-preserving; SIGN below re-covers the edit. Fully
	# dropping X11 = backporting GNOME 47/48's x11-optional work (out of scope). See build5 +
	# tools/macho-weaken.py.
	@test -f $(BUILD_TOOLS)/macho-weaken.py || { echo "ERROR: $(BUILD_TOOLS)/macho-weaken.py missing — mount tools/ into the build (see build-mutter.sh header) so the X11/xcb weaken can run"; exit 1; }
	for f in $$(find $(BUILD_DIST)/libmutter-14-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib -type f -name '*.dylib'); do \
		python3 $(BUILD_TOOLS)/macho-weaken.py $$f $(MUTTER_X11_WEAK); \
	done

	$(call SIGN,libmutter-14-0,general.xml)
	$(call PACK,libmutter-14-0,DEB_MUTTER_V)
	$(call PACK,libmutter-14-dev,DEB_MUTTER_V)
	rm -rf $(BUILD_DIST)/libmutter-14-0 $(BUILD_DIST)/libmutter-14-dev

.PHONY: mutter mutter-package
