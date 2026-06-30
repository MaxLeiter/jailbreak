ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# Local variant of Procursus' libepoxy.mk that ENABLES EGL. GTK4's X11 backend
# #includes <epoxy/egl.h> unconditionally, so epoxy must provide it. Two changes vs
# upstream:
#   1. meson -Degl=yes  (build the EGL dispatch; epoxy dlopens libEGL at runtime, so
#      no libEGL is needed at build/runtime — GTK4 falls back to GLX/cairo if absent).
#   2. epoxy hardcodes `#define PLATFORM_HAS_EGL 0` on __APPLE__, which would skip the
#      `#include <epoxy/egl.h>` and break the (now-compiled) dispatch_egl.c. Make Apple
#      honour ENABLE_EGL instead. (The Khronos EGL/KHR headers are dropped into
#      build_base by build-gtk.sh, since mesa here was built without EGL.)

SUBPROJECTS      += libepoxy
LIBEPOXY_VERSION := 1.5.7
# +angle1: EGL/GLES dispatch repointed at the ANGLE deb (/var/jb/lib/angle) — see below.
DEB_LIBEPOXY_V   ?= 1.5.7+angle1

libepoxy-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/libepoxy/$(shell echo $(LIBEPOXY_VERSION) | cut -d. -f-2)/libepoxy-$(LIBEPOXY_VERSION).tar.xz)
	$(call EXTRACT_TAR,libepoxy-$(LIBEPOXY_VERSION).tar.xz,libepoxy-$(LIBEPOXY_VERSION),libepoxy)
	sed -i 's/#define PLATFORM_HAS_EGL 0/#define PLATFORM_HAS_EGL ENABLE_EGL/' $(BUILD_WORK)/libepoxy/src/dispatch_common.h
	# epoxy's __APPLE__ block defines no EGL_LIB and points GLX_LIB at XQuartz (/opt/X11).
	# Repoint the EGL + GLES2 dispatch at the ANGLE deb (/var/jb/lib/angle) so epoxy
	# consumers — GTK4's GL/NGL renderer on the Wayland backend — get hardware GLES->Metal/
	# AGX; keep GLX_LIB on mesa's software libGL for the X11 path. These dlopens are SOFT:
	# if the angle deb is absent epoxy fails the EGL load gracefully and GTK4 falls back to
	# GLX/cairo, so there is NO hard package dep on angle. (X11 itself cannot use ANGLE: no
	# EGL_EXT_platform_x11 + CAMetalLayer-only surfaces — see hwgl-plan.md Phase C; the win
	# is the Wayland backend.)
	sed -i 's|#define GLX_LIB "/opt/X11/lib/libGL.1.dylib"|#define GLX_LIB "/var/jb/usr/lib/libGL.1.dylib"\n#define EGL_LIB "/var/jb/lib/angle/libEGL.dylib"|' $(BUILD_WORK)/libepoxy/src/dispatch_common.c
	# Repoint epoxy's GLES2 dispatch (Apple block only) at ANGLE's libGLESv2 so GLES2 core
	# entrypoints get dlsym'd from ANGLE's libGLESv2 instead of the absent "libGLESv2.so" soname.
	sed -i '/#if defined(__APPLE__)/,/#elif/ s|#define GLES2_LIB "libGLESv2.so"|#define GLES2_LIB "/var/jb/lib/angle/libGLESv2.dylib"|' $(BUILD_WORK)/libepoxy/src/dispatch_common.c
	rm -rf $(BUILD_WORK)/libepoxy/build
	mkdir -p $(BUILD_WORK)/libepoxy/build
	echo -e "[host_machine]\n \
	system = 'darwin'\n \
	cpu_family = '$(shell echo $(GNU_HOST_TRIPLE) | cut -d- -f1)'\n \
	cpu = '$(MEMO_ARCH)'\n \
	endian = 'little'\n \
	[properties]\n \
	root = '$(BUILD_BASE)'\n \
	[paths]\n \
	prefix ='$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)'\n \
	sysconfdir='$(MEMO_PREFIX)/etc'\n \
	localstatedir='$(MEMO_PREFIX)/var'\n \
	[binaries]\n \
	c = '$(CC)'\n \
	cpp = '$(CXX)'\n \
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/libepoxy/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/libepoxy/.build_complete),)
libepoxy:
	@echo "Using previously built libepoxy."
else
libepoxy: libepoxy-setup libx11 mesa
	cd $(BUILD_WORK)/libepoxy/build && meson \
		--cross-file cross.txt \
		-Dtests=false \
		-Dx11=true \
		-Degl=yes \
		-Dglx=yes \
		..
	+ninja -C $(BUILD_WORK)/libepoxy/build
	+DESTDIR="$(BUILD_STAGE)/libepoxy" ninja -C $(BUILD_WORK)/libepoxy/build install
	$(call AFTER_BUILD,copy)
endif

libepoxy-package: libepoxy-stage
	rm -rf $(BUILD_DIST)/libepoxy{0,-dev}
	mkdir -p $(BUILD_DIST)/libepoxy{0,-dev}/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# libepoxy.mk Prep libepoxy0
	cp -a $(BUILD_STAGE)/libepoxy/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libepoxy.0.dylib $(BUILD_DIST)/libepoxy0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# libepoxy.mk Prep libepoxy-dev
	cp -a $(BUILD_STAGE)/libepoxy/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/!(libepoxy.0.dylib) $(BUILD_DIST)/libepoxy-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/libepoxy/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/libepoxy-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	# libepoxy.mk Sign
	$(call SIGN,libepoxy0,general.xml)

	# libepoxy.mk Make .debs
	$(call PACK,libepoxy0,DEB_LIBEPOXY_V)
	$(call PACK,libepoxy-dev,DEB_LIBEPOXY_V)

	# libepoxy.mk Build cleanup
	rm -rf $(BUILD_DIST)/libepoxy{0,-dev}

.PHONY: libepoxy libepoxy-package
