ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# Built as a Wayland compositor — X11-WM compositing can't be GPU-accelerated on a software
# Xios. Native (KMS/DRM/GBM/logind) backend off; GL via ANGLE EGL/GLES2. Introspection is off
# here because cross can't run the gir dumper; the Meta/Clutter/Cogl typelibs are scanned
# on-device afterward (gir-build-ondevice.sh).

SUBPROJECTS    += mutter
MUTTER_MAJOR_V := 46
# libmutter's ABI/API version (soname + $libdir/mutter-N data dir) is 14, NOT the 46
# release number — the cogl/clutter/mtk dylibs + plugins install to lib/mutter-14/.
MUTTER_API_V   := 14
MUTTER_VERSION := $(MUTTER_MAJOR_V).0
DEB_MUTTER_V   ?= $(MUTTER_VERSION)+ios10

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
		test -f $(BUILD_ROOT)/build_patch/mutter-gir/series || { echo "ERROR: missing staged mutter-gir patch series"; exit 1; }; \
		for patch_file in $$(awk 'NF && $$1 !~ /^#/ { print $$1 }' $(BUILD_ROOT)/build_patch/mutter-gir/series); do \
			echo "   mutter-gir patch: $$patch_file"; \
			patch -p1 -d $(BUILD_WORK)/mutter < $(BUILD_ROOT)/build_patch/mutter-gir/$$patch_file; \
		done; \
	fi
	# Keep unconditional iOS portability edits in the main port patch stack. The
	# no-/work/x11 fallback branch above applies the GIR-only conditional stack.
	$(call DO_PATCH,mutter,mutter,-p1)
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
	# Runtime packages must contain the real iOS backend. The GIR-only setup fallback is useful
	# for tooling, but it must never silently become the compositor library shipped to a device.
	@ios_runtime="$(BUILD_DIST)/libmutter-14-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libmutter-$(MUTTER_API_V).0.dylib"; \
		test -f "$$ios_runtime" || { echo "ERROR: Mutter runtime dylib missing: $$ios_runtime"; exit 1; }; \
		grep -aq 'MetaBackendIOS' "$$ios_runtime" || { echo "ERROR: refusing to package Mutter without MetaBackendIOS"; exit 1; }; \
		grep -aq 'xios_surface_create' "$$ios_runtime" || { echo "ERROR: refusing to package Mutter without linked xios_glue"; exit 1; }
	# The plugin loader asks for .so names; package those aliases with libmutter instead of
	# mutating the installed library tree from launch-gnome-session.sh.
	for f in $(BUILD_DIST)/libmutter-14-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/mutter-$(MUTTER_API_V)/plugins/*.dylib; do \
		[ -e "$$f" ] || continue; \
		ln -sf "$$(basename "$$f")" "$${f%.dylib}.so"; \
	done

	# mutter installs share/ (org.gnome.mutter{,.wayland} GSettings schemas — without which
	# mutter aborts "Settings schema 'org.gnome.mutter' is not installed" — plus GConf/
	# gnome-control-center/locale data). Skip man/ (the minos stamper double-zsts it).
	# build_info/libmutter-14-0.postinst runs glib-compile-schemas on-device.
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
		$(I_N_T) -add_rpath $(MEMO_PREFIX)/lib/angle $$f 2>/dev/null || true; \
	done

	# Weak-link the dead X11/xcb closure: mutter 46 hardcodes have_x11=true and links symbols
	# that don't exist on-device (Wayland-only backend, never called) — flipping to
	# LC_LOAD_WEAK_DYLIB lets dyld tolerate their absence. libxkbcommon.0 stays strong (real Wayland keymap code).
	@test -f $(BUILD_TOOLS)/macho-weaken.py || { echo "ERROR: $(BUILD_TOOLS)/macho-weaken.py missing — mount tools/ into the build (see build-mutter.sh header) so the X11/xcb weaken can run"; exit 1; }
	for f in $$(find $(BUILD_DIST)/libmutter-14-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib -type f -name '*.dylib'); do \
		python3 $(BUILD_TOOLS)/macho-weaken.py $$f $(MUTTER_X11_WEAK); \
	done

	$(call SIGN,libmutter-14-0,general.xml)
	$(call PACK,libmutter-14-0,DEB_MUTTER_V)
	$(call PACK,libmutter-14-dev,DEB_MUTTER_V)
	rm -rf $(BUILD_DIST)/libmutter-14-0 $(BUILD_DIST)/libmutter-14-dev

.PHONY: mutter mutter-package
