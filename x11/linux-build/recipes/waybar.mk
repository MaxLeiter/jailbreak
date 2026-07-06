ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# waybar.mk -- Waybar, a GTK3/gtkmm Wayland status bar.
#
# Initial iOS bring-up is intentionally small. Waybar's upstream Meson file builds a large set of
# wlroots-compositor modules unconditionally (sway/river/dwl/hyprland/wayfire/taskbar) and Linux
# service modules opportunistically. For rootless iOS first-light, prune that surface to clock and
# custom modules, and disable Linux-only/daemon/audio/tray features through Meson options:
# systemd/logind/libinput/libevdev/libudev/JACK/pipewire/wireplumber/cava/mpris/bluetooth/tray.
#
# Still required by Waybar's core: gtkmm-3.0, gtk-layer-shell-0, wayland-client/cursor,
# wayland-protocols, libxkbcommon's xkbregistry, gio-unix-2.0, sigc++-2.0, fmt, spdlog, jsoncpp.
# fmt/spdlog/jsoncpp/gtk-layer-shell have upstream Meson wraps in the 0.15.0 tarball; gtkmm does
# not, so the Procursus volume needs a gtkmm3 stack before a real configure can complete.

SUBPROJECTS    += waybar
WAYBAR_VERSION := 0.15.0
DEB_WAYBAR_V   ?= $(WAYBAR_VERSION)+ios1

waybar-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://github.com/Alexays/Waybar/archive/refs/tags/$(WAYBAR_VERSION).tar.gz)
	$(call EXTRACT_TAR,$(WAYBAR_VERSION).tar.gz,Waybar-$(WAYBAR_VERSION),waybar)
	$(call DO_PATCH,waybar,waybar,-p1)
	rm -rf $(BUILD_WORK)/waybar/build && mkdir -p $(BUILD_WORK)/waybar/build
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
	cpp_args = ['-D_DARWIN_C_SOURCE', '-Wno-error']\n \
	[binaries]\n \
	c = '$(CC)'\n \
	cpp = '$(CXX)'\n \
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/waybar/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/waybar/.build_complete),)
waybar:
	@echo "Using previously built waybar."
else
waybar: waybar-setup wayland wayland-protocols libxkbcommon gtk+3.0
	cd $(BUILD_WORK)/waybar/build && meson \
		--cross-file cross.txt \
		--buildtype=release \
		-Dauto_features=disabled \
		-Dlibinput=disabled \
		-Dlibnl=disabled \
		-Dlibudev=disabled \
		-Dlibevdev=disabled \
		-Dpulseaudio=disabled \
		-Dupower_glib=disabled \
		-Dpipewire=disabled \
		-Dmpris=disabled \
		-Dsystemd=disabled \
		-Ddbusmenu-gtk=disabled \
		-Dman-pages=disabled \
		-Dmpd=disabled \
		-Drfkill=disabled \
		-Dsndio=disabled \
		-Dlogind=disabled \
		-Dtests=disabled \
		-Dexperimental=false \
		-Djack=disabled \
		-Dwireplumber=disabled \
		-Dcava=disabled \
		-Dniri=false \
		-Dlogin-proxy=false \
		-Dgps=disabled \
		..
	+ninja -C $(BUILD_WORK)/waybar/build
	+DESTDIR="$(BUILD_STAGE)/waybar" ninja -C $(BUILD_WORK)/waybar/build install
	# Replace upstream's Linux desktop sample with an iOS-first minimal config.
	mkdir -p $(BUILD_STAGE)/waybar/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/etc/xdg/waybar
	printf '%s\n' \
		'{' \
		'  "layer": "top",' \
		'  "position": "top",' \
		'  "modules-left": ["custom/xios"],' \
		'  "modules-center": ["clock"],' \
		'  "modules-right": [],' \
		'  "clock": { "format": "{:%H:%M}" },' \
		'  "custom/xios": { "format": "Xios", "exec": "printf Xios", "interval": 3600 }' \
		'}' \
		> $(BUILD_STAGE)/waybar/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/etc/xdg/waybar/config.jsonc
	printf '%s\n' \
		'* { border: none; border-radius: 0; font-family: sans-serif; font-size: 12px; min-height: 0; }' \
		'window#waybar { background: rgba(28, 28, 30, 0.92); color: #f5f5f7; }' \
		'#clock, #custom-xios { padding: 0 10px; }' \
		> $(BUILD_STAGE)/waybar/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/etc/xdg/waybar/style.css
	$(call AFTER_BUILD,copy)
endif

waybar-package: waybar-stage
	rm -rf $(BUILD_DIST)/waybar
	mkdir -p $(BUILD_DIST)/waybar/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/waybar/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin $(BUILD_DIST)/waybar/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/waybar/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/etc $(BUILD_DIST)/waybar/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	if [ -d "$(BUILD_STAGE)/waybar/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share" ]; then \
		cp -a $(BUILD_STAGE)/waybar/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share $(BUILD_DIST)/waybar/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
	fi

	$(call SIGN,waybar,iosc-gpu-client-ent.xml,,,nogeneral)
	$(call PACK,waybar,DEB_WAYBAR_V)
	rm -rf $(BUILD_DIST)/waybar

.PHONY: waybar waybar-package
