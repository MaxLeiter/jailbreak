ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# gnome-shell.mk — cross-build GNOME Shell 46 (C parts + JS/theme gresources) for rootless
# iOS. Pairs with the libmutter-14 build (mutter.mk). Three iOS realities shape this
# (all handled by recipes/gnome-shell-ios-fixes.sh, which patches the source so the SAME
# tarball also serves the on-device native gir build):
#   1. EDS is patched OUT (no ICU yet) — no calendar-server, empty calendar UI.
#   2. girs (St/Shell/Shew/Gvc) are cross-gated — generated ON-DEVICE afterwards
#      (gir-build-mutter-ondevice.sh pattern; St/Shell build INSIDE this tree).
#   3. The D-Bus services' Exec=gjs path is baked to the device path, not a host gjs.
# gjs/mozjs/gobject-introspection are NOT make prereqs — they were built on their own
# track and reconstructed into build_base from the out/ debs (listing them here would
# trigger a multi-hour rebuild).
# meson: networkmanager/camera_monitor(pipewire)/systemd OFF per the bring-up decision.

SUBPROJECTS          += gnome-shell
GNOME-SHELL_MAJOR_V  := 46
GNOME-SHELL_VERSION  := $(GNOME-SHELL_MAJOR_V).0
DEB_GNOME-SHELL_V    ?= $(GNOME-SHELL_VERSION)

# GNOME_SHELL_WITH_EDS=1 flips reality #1 below: keep EDS + calendar-server (ICU and
# evolution-data-server are built now — recipes/evolution-data-server.mk). STAGED but not
# the default: the EDS-out shell is mid-bring-up on device, so the lead sequences the flip.
# Use via build-shell.sh WITH_EDS=1 — a rebuild MUST re-extract pristine source (the ectomy
# deletes lines in-place and EXTRACT_TAR no-ops), which that driver path handles.
GNOME_SHELL_WITH_EDS ?= 0
ifeq ($(GNOME_SHELL_WITH_EDS),1)
DEB_GNOME-SHELL_V    := $(GNOME-SHELL_VERSION)-2
endif

gnome-shell-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/gnome-shell/$(GNOME-SHELL_MAJOR_V)/gnome-shell-$(GNOME-SHELL_VERSION).tar.xz)
	$(call EXTRACT_TAR,gnome-shell-$(GNOME-SHELL_VERSION).tar.xz,gnome-shell-$(GNOME-SHELL_VERSION),gnome-shell)
	WITH_EDS=$(GNOME_SHELL_WITH_EDS) bash /work/recipes/gnome-shell-ios-fixes.sh \
		$(BUILD_WORK)/gnome-shell \
		$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/gjs
	rm -rf $(BUILD_WORK)/gnome-shell/build && mkdir -p $(BUILD_WORK)/gnome-shell/build
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
	exe_wrapper = '/bin/true'\n" > $(BUILD_WORK)/gnome-shell/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/gnome-shell/.build_complete),)
gnome-shell:
	@echo "Using previously built gnome-shell."
else
gnome-shell: gnome-shell-setup mutter gtk4 gtk+3.0 gdk-pixbuf gnome-desktop \
		gsettings-desktop-schemas startup-notification at-spi2-core gcr polkit ibus \
		pulseaudio libxml2 \
		$(if $(filter 1,$(GNOME_SHELL_WITH_EDS)),evolution-data-server)
	cd $(BUILD_WORK)/gnome-shell/build && meson \
		--cross-file cross.txt \
		-Dnetworkmanager=false \
		-Dcamera_monitor=false \
		-Dsystemd=false \
		-Dextensions_tool=false \
		-Dextensions_app=false \
		-Dtests=false \
		-Dman=false \
		-Dgtk_doc=false \
		..
	+ninja -C $(BUILD_WORK)/gnome-shell/build
	+DESTDIR="$(BUILD_STAGE)/gnome-shell" ninja -C $(BUILD_WORK)/gnome-shell/build install
	# Like mutter/GTK4: if the build bundled the proxy-libintl, relink onto the libgtkintl
	# shim (the shared relink pass also covers the packed deb; this keeps the stage clean).
	for f in $$(find $(BUILD_STAGE)/gnome-shell/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
			$(BUILD_STAGE)/gnome-shell/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin -type f 2>/dev/null); do \
		$(I_N_T) -change @rpath/libintl.dylib @rpath/libgtkintl.dylib $$f 2>/dev/null || true; \
	done
	rm -f $(BUILD_STAGE)/gnome-shell/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libintl.dylib
	$(call AFTER_BUILD,copy)
endif

gnome-shell-package: gnome-shell-stage
	rm -rf $(BUILD_DIST)/gnome-shell
	mkdir -p $(BUILD_DIST)/gnome-shell$(MEMO_PREFIX)

	# single deb: bin/gnome-shell + lib/gnome-shell/ (libshell-14, libst-14, libshew-0,
	# libgvc) + share/gnome-shell gresources/theme + schemas + D-Bus services + desktops.
	# Copy the CONTENTS of the staged prefix into the same prefix under BUILD_DIST (copying
	# $(MEMO_PREFIX) itself would drop the leading `var/` from /var/jb -> installs to /jb).
	cp -a $(BUILD_STAGE)/gnome-shell$(MEMO_PREFIX)/. $(BUILD_DIST)/gnome-shell$(MEMO_PREFIX)/
	rm -rf $(BUILD_DIST)/gnome-shell$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/man \
		$(BUILD_DIST)/gnome-shell$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/doc

	$(call SIGN,gnome-shell,general.xml)
	$(call PACK,gnome-shell,DEB_GNOME-SHELL_V)
	rm -rf $(BUILD_DIST)/gnome-shell

.PHONY: gnome-shell gnome-shell-package
