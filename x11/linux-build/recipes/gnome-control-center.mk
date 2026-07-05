ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# gnome-control-center.mk — GNOME Settings 46 for the Xios GNOME session (rootless iOS).
#
# A per-panel GTK4/libadwaita app. This builds the tractable CONFIG panels; panels whose
# backends have no iOS implementation are ectomied by ports/gnome-control-center/patches
# (see its header for the exact list). network/bluetooth/wacom are ALREADY auto-dropped off
# Linux by upstream; the patch stack removes the wwan configure-landmine + the goa
# (online-accounts) and cups (printers) panels/deps.
#
# KEPT panels: applications background display keyboard mouse multitasking notifications
#              power privacy search sharing sound universal-access
#              [+ bluetooth when GCC_WITH_BLUETOOTH=1]
#
# COMPANION PREREQS that must be built on the volume FIRST (not upstream-portable as-is):
#   * gudev-1.0 STUB — REQUIRED dep, consumed by panels/common (gsd-device-manager.c, linked by
#     keyboard/mouse). iOS has no udev, so the stub returns empty enumerations.
#   * libgsound/pwquality STUBS — REQUIRED by sound/system-adjacent code paths and optional
#     Bluetooth/settings work. They provide best-effort behavior without pulling Linux-only stacks.
#   * gnome-bluetooth (libgnome-bluetooth-ui-3.0) — ONLY when GCC_WITH_BLUETOOTH=1, for Max's
#     Bluetooth panel. Needs its own udev/gsound ectomy. Its org.bluez backend is already
#     provided at runtime by xios-bluez-stub (wayland/xios-bluez-stub.m, validated on device).
#
# Everything else (gtk4, libadwaita, gnome-desktop, gsettings-desktop-schemas, colord,
# accountsservice, polkit, gcr, pulseaudio, upower, gnome-settings-daemon headers, libX11/libXi,
# libepoxy) is already built on procursus-vol-shell.

SUBPROJECTS      += gnome-control-center
GCC_MAJOR_V      := 46
GCC_VERSION      := $(GCC_MAJOR_V).4
DEB_GCC_V        ?= $(GCC_VERSION)+ios1
GCC_WITH_BLUETOOTH ?= 0

gnome-control-center-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/gnome-control-center/$(GCC_MAJOR_V)/gnome-control-center-$(GCC_VERSION).tar.xz)
	$(call EXTRACT_TAR,gnome-control-center-$(GCC_VERSION).tar.xz,gnome-control-center-$(GCC_VERSION),gnome-control-center)
	$(call DO_PATCH,gnome-control-center,gnome-control-center,-p1)
	rm -rf $(BUILD_WORK)/gnome-control-center/build && mkdir -p $(BUILD_WORK)/gnome-control-center/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n \
	exe_wrapper = '/bin/true'\n" > $(BUILD_WORK)/gnome-control-center/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/gnome-control-center/.build_complete),)
gnome-control-center:
	@echo "Using previously built gnome-control-center."
else
gnome-control-center: gnome-control-center-setup gtk4 libadwaita gnome-desktop gsettings-desktop-schemas colord accountsservice polkit gcr pulseaudio upower gnome-settings-daemon
	cd $(BUILD_WORK)/gnome-control-center/build && meson \
		--cross-file cross.txt \
		-Dtests=false \
		-Dsnap=false \
		-Dmalcontent=false \
		-Dibus=false \
		-Dwayland=true \
		-Ddocumentation=false \
		-Dlocation-services=disabled \
		..
	+ninja -C $(BUILD_WORK)/gnome-control-center/build
	+DESTDIR="$(BUILD_STAGE)/gnome-control-center" ninja -C $(BUILD_WORK)/gnome-control-center/build install
	for f in $$(find $(BUILD_STAGE)/gnome-control-center/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin \
			$(BUILD_STAGE)/gnome-control-center/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib -type f 2>/dev/null); do \
		$(I_N_T) -change @rpath/libintl.dylib @rpath/libgtkintl.dylib $$f 2>/dev/null || true; \
	done
	$(call AFTER_BUILD,copy)
endif

gnome-control-center-package: gnome-control-center-stage
	rm -rf $(BUILD_DIST)/gnome-control-center
	mkdir -p $(BUILD_DIST)/gnome-control-center$(MEMO_PREFIX)
	cp -a $(BUILD_STAGE)/gnome-control-center$(MEMO_PREFIX)/. $(BUILD_DIST)/gnome-control-center$(MEMO_PREFIX)/
	rm -rf $(BUILD_DIST)/gnome-control-center$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/man \
		$(BUILD_DIST)/gnome-control-center$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/doc

	$(call SIGN,gnome-control-center,general.xml)
	$(call PACK,gnome-control-center,DEB_GCC_V)
	rm -rf $(BUILD_DIST)/gnome-control-center

.PHONY: gnome-control-center gnome-control-center-package
