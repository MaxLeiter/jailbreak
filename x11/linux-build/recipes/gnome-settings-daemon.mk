ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# Minimal build: only a11y-settings, housekeeping, keyboard, screensaver-proxy plugins are
# kept (see ports/gnome-settings-daemon/patches for the full audit). The dropped plugins
# were the only consumers of geocode-glib/gweather4/libcanberra/libgeoclue/upower, so those
# become required:false. systemd is off: daemons are D-Bus/child-launched by gnome-session.

SUBPROJECTS      += gnome-settings-daemon
GSD_MAJOR_V      := 46
GSD_VERSION      := $(GSD_MAJOR_V).0
DEB_GSD_V        ?= $(GSD_VERSION)+ios1

gnome-settings-daemon-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/gnome-settings-daemon/$(GSD_MAJOR_V)/gnome-settings-daemon-$(GSD_VERSION).tar.xz)
	$(call EXTRACT_TAR,gnome-settings-daemon-$(GSD_VERSION).tar.xz,gnome-settings-daemon-$(GSD_VERSION),gnome-settings-daemon)
	$(call DO_PATCH,gnome-settings-daemon,gnome-settings-daemon,-p1)
	rm -rf $(BUILD_WORK)/gnome-settings-daemon/build && mkdir -p $(BUILD_WORK)/gnome-settings-daemon/build
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
	exe_wrapper = '/bin/true'\n" > $(BUILD_WORK)/gnome-settings-daemon/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/gnome-settings-daemon/.build_complete),)
gnome-settings-daemon:
	@echo "Using previously built gnome-settings-daemon."
else
gnome-settings-daemon: gnome-settings-daemon-setup gtk+3.0 gnome-desktop gsettings-desktop-schemas libnotify polkit pulseaudio
	cd $(BUILD_WORK)/gnome-settings-daemon/build && meson \
		--cross-file cross.txt \
		-Dsystemd=false \
		-Dalsa=false \
		-Dgudev=false \
		-Dwayland=false \
		-Dcups=false \
		-Dnetwork_manager=false \
		-Dcolord=false \
		-Dsmartcard=false \
		-Dusb-protection=false \
		-Dwwan=false \
		-Drfkill=false \
		..
	+ninja -C $(BUILD_WORK)/gnome-settings-daemon/build
	+DESTDIR="$(BUILD_STAGE)/gnome-settings-daemon" ninja -C $(BUILD_WORK)/gnome-settings-daemon/build install
	for f in $$(find $(BUILD_STAGE)/gnome-settings-daemon/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
			$(BUILD_STAGE)/gnome-settings-daemon/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec -type f 2>/dev/null); do \
		$(I_N_T) -change @rpath/libintl.dylib @rpath/libgtkintl.dylib $$f 2>/dev/null || true; \
	done
	$(call AFTER_BUILD,copy)
endif

gnome-settings-daemon-package: gnome-settings-daemon-stage
	rm -rf $(BUILD_DIST)/gnome-settings-daemon
	mkdir -p $(BUILD_DIST)/gnome-settings-daemon$(MEMO_PREFIX)
	cp -a $(BUILD_STAGE)/gnome-settings-daemon$(MEMO_PREFIX)/. $(BUILD_DIST)/gnome-settings-daemon$(MEMO_PREFIX)/
	rm -rf $(BUILD_DIST)/gnome-settings-daemon$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/man \
		$(BUILD_DIST)/gnome-settings-daemon$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/doc

	$(call SIGN,gnome-settings-daemon,general.xml)
	$(call PACK,gnome-settings-daemon,DEB_GSD_V)
	rm -rf $(BUILD_DIST)/gnome-settings-daemon

.PHONY: gnome-settings-daemon gnome-settings-daemon-package
