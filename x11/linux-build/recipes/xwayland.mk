ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# xwayland.mk — Xwayland (the X server that runs X11 apps as clients of a
# Wayland compositor) for rootless iOS, GPU-accelerated on ANGLE-Metal.
#
# Version pin is LOAD-BEARING: xwayland 23.2.x is the last series with the
# pluggable `struct xwl_egl_backend` vtable (24.1 hard-wired gbm/dma-buf and
# removed the struct). We add an IOSurface EGL backend (no gbm, no dma-buf)
# via that vtable — see recipes/build_info/xwayland-glamor-iosurface.c and
# recipes/xwayland-ios-fixes.sh. Buffers are handed to the compositor with the
# iosc_iosurface protocol (x11/wayland/iosc-iosurface.xml), the same mach-port
# handoff iosc already implements.
#
# Two build flavors from ONE recipe (env XWAYLAND_GLAMOR, default true):
#   X1 (default) glamor ON  -> GPU: window pixmaps are IOSurface/ANGLE textures.
#   X0           glamor OFF -> pure wl_shm software (first-light / bisect aid):
#                              XWAYLAND_GLAMOR=false make xwayland
#
# Deps already cross-built in Procursus: pixman, xorgproto, xtrans, libxkbfile,
# libxfont2, libfontenc, font-util, libepoxy(+angle repoint), libxkbcommon,
# wayland, wayland-protocols. NEW: libxcvt (recipes/libxcvt.mk), libdrm (the
# links-only shim, recipes/libdrm.mk — glamor's meson requires libdrm.pc even
# though no DRM path runs). GLX-on-EGL is built but desktop-GL apps stay on
# llvmpipe/SHM (no client DRI on iOS); glamor accelerates the 2D X path.

SUBPROJECTS      += xwayland
XWAYLAND_VERSION := 23.2.7
DEB_XWAYLAND_V   ?= $(XWAYLAND_VERSION)+ios2

XWAYLAND_GLAMOR  ?= true

# libdrm is the links-only SHIM and is a BASE dep even for X0: xwayland-window.h
# includes <xf86drm.h> unconditionally (the xwl_window / xwl_egl_backend structs
# carry drmDevice* fields), so the header is needed regardless of glamor; the DRM
# code path stays inert on iOS. Only libepoxy (glamor's GL loader, repointed at
# ANGLE) is glamor-specific -> X1 only.
ifeq ($(XWAYLAND_GLAMOR),true)
XWAYLAND_GL_DEPS := libepoxy
else
XWAYLAND_GL_DEPS :=
endif

xwayland-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://xorg.freedesktop.org/archive/individual/xserver/xwayland-$(XWAYLAND_VERSION).tar.xz)
	$(call EXTRACT_TAR,xwayland-$(XWAYLAND_VERSION).tar.xz,xwayland-$(XWAYLAND_VERSION),xwayland)
	# iOS/ANGLE source edits (idempotent): rootless popen shell + the IOSurface
	# glamor backend wired into the xwl_egl_backend vtable. The backend .c and
	# the iosc protocol XML are staged into build_info by build-xwayland.sh.
	bash $(BUILD_INFO)/xwayland-ios-fixes.sh \
		$(BUILD_WORK)/xwayland \
		$(BUILD_INFO)/xwayland-glamor-iosurface.c \
		$(BUILD_INFO)/iosc-iosurface.xml
	mkdir -p $(BUILD_WORK)/xwayland/build
	echo -e "[host_machine]\n \
	system = 'darwin'\n \
	cpu_family = '$(shell echo $(GNU_HOST_TRIPLE) | cut -d- -f1)'\n \
	cpu = '$(MEMO_ARCH)'\n \
	endian = 'little'\n \
	[properties]\n \
	needs_exe_wrapper = true\n \
	[built-in options]\n \
	prefix ='$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)'\n \
	[binaries]\n \
	c = '$(CC)'\n \
	cpp = '$(CXX)'\n \
	objc = '$(CC)'\n \
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/xwayland/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/xwayland/.build_complete),)
xwayland:
	@echo "Using previously built xwayland."
else
xwayland: xwayland-setup libpixman xorgproto xtrans libxkbfile libxfont2 libfontenc \
          font-util libxkbcommon libxcvt libxshmfence libdrm wayland wayland-protocols $(XWAYLAND_GL_DEPS)
	# The native (host) wayland-scanner for `dependency('wayland-scanner',
	# native:true)` comes from the build machine's pkg-config (build-xwayland.sh
	# installs libwayland-bin). No version pin on the scanner in xwayland.
	#
	# glamor requires libdrm.pc + epoxy.pc unconditionally (top meson.build);
	# both are present (libdrm = the links-only shim). dri3/xshmfence OFF (no
	# client GPU on iOS). Objective-C is enabled for the IOSurface/CoreFoundation
	# calls in the backend (compiled by clang as .c but pulls ObjC frameworks).
	# Only options that actually exist in this tree's meson_options.txt (validated
	# off-device — int10/systemd_logind/os_vendor are NOT xwayland options and
	# would abort meson). The three -D...=false below each prevent a HARD meson
	# error on iOS (validated against every error() gate in meson.build/os):
	#   xdmcp     -> dependency('xdmcp') is required; we don't build libXdmcp, and
	#                Xwayland never needs XDMCP (its connection comes from Wayland).
	#                Disabling it also auto-disables xdm-auth-1.
	#   secure-rpc-> os/meson.build errors "neither libtirpc or libc RPC"; Darwin
	#                has no Sun RPC. Xwayland doesn't need secure RPC auth.
	#   sha1=CommonCrypto -> deterministic zero-dep iOS SHA1 (CC_SHA1_Init in
	#                libSystem); 'auto' would also land here but pin it. Avoids the
	#                libmd dep the old xorg-server recipe used.
	# xcsecurity stays default-off, so the X-ACE error() gate never triggers.
	#   glx=false -> drops the required 'dri' pkg-config dep (include/meson.build
	#                gates it on build_glx). iOS has no client-side DRI drivers, so
	#                GLX apps stay software regardless. GLX-on-EGL (needs a mesa
	#                dri.pc) is a X1 follow-up; not needed for xterm/hitori/fluxbox.
	cd $(BUILD_WORK)/xwayland/build && \
		OBJC="$(CC)" meson \
		--cross-file cross.txt \
		-Dglamor=$(XWAYLAND_GLAMOR) \
		-Dxwayland_eglstream=false \
		-Ddri3=false \
		-Dxvfb=false \
		-Dxwayland_ei=false \
		-Dglx=false \
		-Ddtrace=false \
		-Dlibunwind=false \
		-Dxdmcp=false \
		-Dsecure-rpc=false \
		-Dsha1=CommonCrypto \
		-Dxkb_dir=$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/X11/xkb \
		-Dxkb_output_dir=$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/var/lib/xkb \
		--prefix=$(MEMO_PREFIX)$(MEMO_SUB_PREFIX) \
		--libexecdir=$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec \
		..
	+ninja -C $(BUILD_WORK)/xwayland/build
	+DESTDIR="$(BUILD_STAGE)/xwayland" ninja -C $(BUILD_WORK)/xwayland/build install
	$(call AFTER_BUILD,copy)
endif

xwayland-package: xwayland-stage
	# xwayland.mk Package Structure — one deb: the Xwayland server binary
	# (+ Xwayland.desktop / man). No -dev split (nothing links against it).
	rm -rf $(BUILD_DIST)/xwayland
	mkdir -p $(BUILD_DIST)/xwayland/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin

	cp -a $(BUILD_STAGE)/xwayland/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/Xwayland \
		$(BUILD_DIST)/xwayland/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin
	if [ -d "$(BUILD_STAGE)/xwayland/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share" ]; then \
		cp -a $(BUILD_STAGE)/xwayland/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share \
			$(BUILD_DIST)/xwayland/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
	fi

	# Sign with the GPU entitlement set (Metal via ANGLE + IOSurface IOKit +
	# task_for_pid so the compositor can import our surfaces) — same set the
	# iosc GPU client uses. The 5th arg `nogeneral` is LOAD-BEARING: it skips the
	# default general.xml merge, which sets com.apple.private.security.no-container
	# = true and would kill Metal (MTLCreateSystemDefaultDevice -> nil). Our
	# xwayland-ent.xml is self-sufficient (skip-library-validation +
	# can-allow-non-platform + IOKit + file exceptions), like iosc-gpu-client-ent.
	# The ent lives in build_misc/entitlements/ (where SIGN looks), staged there
	# by build-xwayland.sh. See [[fakesigned-metal-gpu-entitlement]].
	$(call SIGN,xwayland,xwayland-ent.xml,,,nogeneral)
	$(call PACK,xwayland,DEB_XWAYLAND_V)

	rm -rf $(BUILD_DIST)/xwayland

.PHONY: xwayland xwayland-package
