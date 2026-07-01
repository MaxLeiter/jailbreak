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

mutter-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/mutter/$(MUTTER_MAJOR_V)/mutter-$(MUTTER_VERSION).tar.xz)
	$(call EXTRACT_TAR,mutter-$(MUTTER_VERSION).tar.xz,mutter-$(MUTTER_VERSION),mutter)
	# --- iOS portability patches (accreting) ---
	# libei/libeis (input emulation) are dependency()'d unconditionally but only USED under
	# HAVE_REMOTE_DESKTOP (off here) — make them non-required so configure proceeds without them.
	sed -i "s/dependency('libeis-1.0', version: libei_req)/dependency('libeis-1.0', version: libei_req, required: false)/" $(BUILD_WORK)/mutter/meson.build
	sed -i "s/dependency('libei-1.0', version: libei_req)/dependency('libei-1.0', version: libei_req, required: false)/" $(BUILD_WORK)/mutter/meson.build
	# meta-context-main.c: for the wayland + x11 + NO-native-backend combo (untested upstream), the
	# X11-nested branch's `else` is left bodiless because the native-backend block is #ifdef'd out
	# ("else }" -> expected statement). Give it a body. (The real wayland-without-native path is
	# nested or MetaBackendIOS; we only need this to compile for the typelibs.)
	perl -0pi -e 's{return create_native_backend \(context, error\);\n#endif /\* HAVE_NATIVE_BACKEND \*/}{return create_native_backend (context, error);\n#else\n      g_assert_not_reached ();\n      return NULL;\n#endif /* HAVE_NATIVE_BACKEND */}' $(BUILD_WORK)/mutter/src/core/meta-context-main.c
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

	# dev: headers + .pc (needed for the on-device introspection scan)
	cp -a $(BUILD_STAGE)/mutter/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/libmutter-14-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX) 2>/dev/null || true
	cp -a $(BUILD_STAGE)/mutter/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig $(BUILD_DIST)/libmutter-14-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib 2>/dev/null || true

	$(call SIGN,libmutter-14-0,general.xml)
	$(call PACK,libmutter-14-0,DEB_MUTTER_V)
	$(call PACK,libmutter-14-dev,DEB_MUTTER_V)
	rm -rf $(BUILD_DIST)/libmutter-14-0 $(BUILD_DIST)/libmutter-14-dev

.PHONY: mutter mutter-package
