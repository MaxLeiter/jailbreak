ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# upower.mk — the libupower-glib CLIENT library only, for rootless iOS. gnome-shell statically
# imports gi://UPowerGlib in status/system.js at panel boot, so the shell will not start without
# the UPowerGlib typelib + dylib. The daemon (udev/systemd/sysfs) is dropped (upower-ios-fixes.sh);
# the client library is a GDBus proxy on glib/gio. Introspection off; UPowerGlib-1.0 typelib is
# generated ON-DEVICE. The udev/systemd install-dir probes are satisfied with explicit paths so
# the top-level meson does not dependency('udev'/'systemd') (both absent).

SUBPROJECTS      += upower
UPOWER_VERSION   := 1.90.2
DEB_UPOWER_V     ?= $(UPOWER_VERSION)+ios1

upower-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://gitlab.freedesktop.org/upower/upower/-/archive/v$(UPOWER_VERSION)/upower-v$(UPOWER_VERSION).tar.bz2)
	$(call EXTRACT_TAR,upower-v$(UPOWER_VERSION).tar.bz2,upower-v$(UPOWER_VERSION),upower)
	bash /work/recipes/upower-ios-fixes.sh $(BUILD_WORK)/upower
	rm -rf $(BUILD_WORK)/upower/build && mkdir -p $(BUILD_WORK)/upower/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/upower/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/upower/.build_complete),)
upower:
	@echo "Using previously built upower."
else
upower: upower-setup glib2.0
	cd $(BUILD_WORK)/upower/build && meson \
		--cross-file cross.txt \
		-Dintrospection=disabled \
		-Dos_backend=dummy \
		-Didevice=disabled \
		-Dman=false \
		-Dgtk-doc=false \
		-Dudevrulesdir=$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/udev/rules.d \
		-Dudevhwdbdir=$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/udev/hwdb.d \
		-Dsystemdsystemunitdir=$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/systemd/system \
		..
	+ninja -C $(BUILD_WORK)/upower/build
	+DESTDIR="$(BUILD_STAGE)/upower" ninja -C $(BUILD_WORK)/upower/build install
	$(call AFTER_BUILD,copy)
endif

upower-package: upower-stage
	rm -rf $(BUILD_DIST)/libupower-glib3 $(BUILD_DIST)/libupower-glib-dev
	mkdir -p $(BUILD_DIST)/libupower-glib3/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libupower-glib-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	cp -a $(BUILD_STAGE)/upower/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libupower-glib.*.dylib \
		$(BUILD_DIST)/libupower-glib3/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/ 2>/dev/null || \
	cp -a $(BUILD_STAGE)/upower/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libupower-glib.dylib \
		$(BUILD_DIST)/libupower-glib3/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/

	cp -a $(BUILD_STAGE)/upower/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libupower-glib-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/ 2>/dev/null || true
	cp -a $(BUILD_STAGE)/upower/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig \
		$(BUILD_DIST)/libupower-glib-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/ 2>/dev/null || true
	if [ -e "$(BUILD_STAGE)/upower/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libupower-glib.dylib" ]; then \
		cp -a $(BUILD_STAGE)/upower/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libupower-glib.dylib \
			$(BUILD_DIST)/libupower-glib-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/ 2>/dev/null || true; \
	fi

	$(call SIGN,libupower-glib3,general.xml)
	$(call PACK,libupower-glib3,DEB_UPOWER_V)
	$(call PACK,libupower-glib-dev,DEB_UPOWER_V)
	rm -rf $(BUILD_DIST)/libupower-glib3 $(BUILD_DIST)/libupower-glib-dev

.PHONY: upower upower-package
