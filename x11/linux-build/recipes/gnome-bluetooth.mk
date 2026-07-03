ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# gnome-bluetooth.mk — gnome-bluetooth 46 for the Xios GNOME session (rootless iOS).
#
# Builds libgnome-bluetooth-3.0 (BlueZ client) + libgnome-bluetooth-ui-3.0 (the widgets the
# gnome-control-center Bluetooth panel links, and the backend of gnome-shell's Bluetooth quick
# toggle). Its runtime backend is org.bluez — provided on iOS by xios-bluez-stub
# (wayland/xios-bluez-stub.m), which bridges BlueZ's D-Bus API to the private BluetoothManager
# framework (validated on device: enumerates the real paired devices).
#
# iOS accommodations:
#  - introspection=false (cross can't run g-ir-scanner; the GnomeBluetooth typelib for the shell
#    toggle is generated on-device afterwards, like the other typelibs).
#  - sendto=false (bluetooth-sendto app; needs OBEX/GTK file bits we don't want).
#  - libudev + gsound are STUBS installed into the sysroot (build-udev-stub.sh / build-gsound-
#    stub.sh): gnome-bluetooth uses libudev only for the pin.c hwdb name lookup (returns empty;
#    the device's own BT-reported name is used) and gsound only for the pairing chime.
#  - The `-Wl,--version-script` (GNU ld) link arg is auto-dropped by
#    cc.get_supported_link_arguments() on the Darwin linker — no patch needed.
# No source patch has been required; if one becomes necessary, add recipes/gnome-bluetooth-
# ios-fixes.sh and invoke it in -setup (mirrors gnome-settings-daemon.mk).

SUBPROJECTS      += gnome-bluetooth
GNOME-BLUETOOTH_MAJOR_V := 46
GNOME-BLUETOOTH_VERSION := $(GNOME-BLUETOOTH_MAJOR_V).0
DEB_GNOME-BLUETOOTH_V   ?= $(GNOME-BLUETOOTH_VERSION)+ios1

gnome-bluetooth-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/gnome-bluetooth/$(GNOME-BLUETOOTH_MAJOR_V)/gnome-bluetooth-$(GNOME-BLUETOOTH_VERSION).tar.xz)
	$(call EXTRACT_TAR,gnome-bluetooth-$(GNOME-BLUETOOTH_VERSION).tar.xz,gnome-bluetooth-$(GNOME-BLUETOOTH_VERSION),gnome-bluetooth)
	rm -rf $(BUILD_WORK)/gnome-bluetooth/build && mkdir -p $(BUILD_WORK)/gnome-bluetooth/build
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
	exe_wrapper = '/bin/true'\n" > $(BUILD_WORK)/gnome-bluetooth/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/gnome-bluetooth/.build_complete),)
gnome-bluetooth:
	@echo "Using previously built gnome-bluetooth."
else
gnome-bluetooth: gnome-bluetooth-setup gtk4 libadwaita libnotify upower
	cd $(BUILD_WORK)/gnome-bluetooth/build && meson \
		--cross-file cross.txt \
		-Dintrospection=false \
		-Dsendto=false \
		-Dgtk_doc=false \
		..
	+ninja -C $(BUILD_WORK)/gnome-bluetooth/build
	+DESTDIR="$(BUILD_STAGE)/gnome-bluetooth" ninja -C $(BUILD_WORK)/gnome-bluetooth/build install
	for f in $$(find $(BUILD_STAGE)/gnome-bluetooth/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib -type f -name '*.dylib' 2>/dev/null); do \
		$(I_N_T) -change @rpath/libintl.dylib @rpath/libgtkintl.dylib $$f 2>/dev/null || true; \
	done
	$(call AFTER_BUILD,copy)
endif

gnome-bluetooth-package: gnome-bluetooth-stage
	rm -rf $(BUILD_DIST)/gnome-bluetooth
	mkdir -p $(BUILD_DIST)/gnome-bluetooth$(MEMO_PREFIX)
	cp -a $(BUILD_STAGE)/gnome-bluetooth$(MEMO_PREFIX)/. $(BUILD_DIST)/gnome-bluetooth$(MEMO_PREFIX)/
	rm -rf $(BUILD_DIST)/gnome-bluetooth$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/man \
		$(BUILD_DIST)/gnome-bluetooth$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/doc

	$(call SIGN,gnome-bluetooth,general.xml)
	$(call PACK,gnome-bluetooth,DEB_GNOME-BLUETOOTH_V)
	rm -rf $(BUILD_DIST)/gnome-bluetooth

.PHONY: gnome-bluetooth gnome-bluetooth-package
