ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# Xwayland (X11-on-Wayland) for rootless iOS, GPU-accelerated via ANGLE-Metal.
#
# Version pin is LOAD-BEARING: 23.2.x is the last series with the pluggable
# `struct xwl_egl_backend` vtable (24.1 hard-wired gbm/dma-buf and dropped
# it). An IOSurface EGL backend hooks into that vtable (ports/xwayland/patches/,
# recipes/build_info/xwayland-glamor-iosurface.c); buffers reach the
# compositor over the iosc_iosurface protocol.
#
# GLX-on-EGL builds but desktop-GL apps stay on llvmpipe/SHM (no client DRI
# on iOS); glamor only accelerates the 2D X path.

SUBPROJECTS      += xwayland
XWAYLAND_VERSION := 23.2.7
DEB_XWAYLAND_V   ?= $(XWAYLAND_VERSION)+ios4

# libdrm is a links-only build shim: xwayland-window.h
# includes <xf86drm.h> unconditionally (the xwl_window / xwl_egl_backend structs
# carry drmDevice* fields), but the DRM code path stays inert on iOS.

xwayland-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://xorg.freedesktop.org/archive/individual/xserver/xwayland-$(XWAYLAND_VERSION).tar.xz)
	$(call EXTRACT_TAR,xwayland-$(XWAYLAND_VERSION).tar.xz,xwayland-$(XWAYLAND_VERSION),xwayland)
	# iOS/ANGLE source edits: rootless popen shell + the IOSurface glamor
	# backend hooks wired into the xwl_egl_backend vtable.
	$(call DO_PATCH,xwayland,xwayland,-p1)
	# Local backend implementation and private iosc protocol XML are build
	# inputs, not upstream source patches.
	cp -v $(BUILD_INFO)/xwayland-glamor-iosurface.c $(BUILD_WORK)/xwayland/hw/xwayland/
	cp -v /work/x11/wayland/iosc-iosurface.xml $(BUILD_WORK)/xwayland/hw/xwayland/
	cp -v /work/x11/wayland/xios_metal_sync.{m,h} $(BUILD_WORK)/xwayland/hw/xwayland/
	cp -v /work/x11/apps/shared/XiosMetalEventBroker.{m,h} $(BUILD_WORK)/xwayland/hw/xwayland/
	cp -v /work/x11/apps/shared/XiosProtocol.h $(BUILD_WORK)/xwayland/hw/xwayland/
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
          font-util libxkbcommon libxcvt libxshmfence libdrm libepoxy wayland wayland-protocols
	# Native wayland-scanner comes from the build machine's pkg-config
	# (build-xwayland.sh installs libwayland-bin); no version pin here.
	#
	# glamor needs libdrm.pc + epoxy.pc unconditionally (libdrm is the
	# links-only shim). dri3/xshmfence off (no client GPU on iOS). ObjC is
	# enabled for the IOSurface/CoreFoundation calls in the backend. The
	# three -D...=false flags below each avoid a hard meson error() on iOS:
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
		-Dglamor=true \
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
	# One deb: the Xwayland server binary (+ Xwayland.desktop / man). No
	# -dev split (nothing links against it).
	rm -rf $(BUILD_DIST)/xwayland
	mkdir -p $(BUILD_DIST)/xwayland/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin

	cp -a $(BUILD_STAGE)/xwayland/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/Xwayland \
		$(BUILD_DIST)/xwayland/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin
	if [ -d "$(BUILD_STAGE)/xwayland/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share" ]; then \
		cp -a $(BUILD_STAGE)/xwayland/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share \
			$(BUILD_DIST)/xwayland/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
	fi

	# `nogeneral` is LOAD-BEARING: it skips the default general.xml merge,
	# which sets com.apple.private.security.no-container=true and would kill
	# Metal (MTLCreateSystemDefaultDevice -> nil). xwayland-ent.xml already
	# carries skip-library-validation + can-allow-non-platform + IOKit +
	# file exceptions on its own. See [[fakesigned-metal-gpu-entitlement]].
	$(call SIGN,xwayland,xwayland-ent.xml,,,nogeneral)
	$(call PACK,xwayland,DEB_XWAYLAND_V)

	rm -rf $(BUILD_DIST)/xwayland

.PHONY: xwayland xwayland-package
