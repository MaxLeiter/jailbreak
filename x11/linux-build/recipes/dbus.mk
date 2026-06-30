ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# D-Bus — shared session-bus foundation, not XFCE-specific. The GNOME-apps track (dconf,
# GLib GDBus, app activation) and XFCE (xfconf/xfconfd) both require it. Not in Procursus.
# dbus <=1.14 is autotools; 1.16+ is meson-only, so we pin 1.14.x.
SUBPROJECTS  += dbus
DBUS_VERSION := 1.14.10
DEB_DBUS_V   ?= $(DBUS_VERSION)

dbus-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://dbus.freedesktop.org/releases/dbus/dbus-$(DBUS_VERSION).tar.xz)
	$(call EXTRACT_TAR,dbus-$(DBUS_VERSION).tar.xz,dbus-$(DBUS_VERSION),dbus)

ifneq ($(wildcard $(BUILD_WORK)/dbus/.build_complete),)
dbus:
	@echo "Using previously built dbus."
else
dbus: dbus-setup expat
	cd $(BUILD_WORK)/dbus && ./configure -C \
		$(DEFAULT_CONFIGURE_FLAGS) \
		--disable-static \
		--disable-systemd \
		--disable-launchd \
		--disable-tests \
		--disable-doxygen-docs \
		--disable-xml-docs \
		--disable-ducktype-docs \
		--without-x \
		--with-session-socket-dir=$(MEMO_PREFIX)/var/run/dbus \
		--with-system-pid-file=$(MEMO_PREFIX)/var/run/dbus/pid \
		--with-system-socket=$(MEMO_PREFIX)/var/run/dbus/system_bus_socket \
		--with-dbus-daemondir=$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin
	+$(MAKE) -C $(BUILD_WORK)/dbus
	+$(MAKE) -C $(BUILD_WORK)/dbus install DESTDIR=$(BUILD_STAGE)/dbus
	$(call AFTER_BUILD,copy)
endif

dbus-package: dbus-stage
	# dbus.mk Package Structure — single runtime package (lib + daemon + tools)
	rm -rf $(BUILD_DIST)/dbus
	# MEMO_PREFIX is /var/jb, so copy the staged tree INTO dest$(MEMO_PREFIX) (preserving
	# var/jb) — copying $(MEMO_PREFIX) itself would drop the leaf to ./jb (bad install path).
	mkdir -p $(BUILD_DIST)/dbus$(MEMO_PREFIX)
	cp -a $(BUILD_STAGE)/dbus$(MEMO_PREFIX)/. $(BUILD_DIST)/dbus$(MEMO_PREFIX)/

	# dbus.mk Drop dev cruft (no -dev split shipped)
	rm -rf $(BUILD_DIST)/dbus/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/dbus/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig \
		$(BUILD_DIST)/dbus/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/*.a \
		$(BUILD_DIST)/dbus/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/doc

	# dbus.mk Sign (daemon/tools need entitlements; dylibs plain-signed)
	$(call SIGN,dbus,general.xml)
	$(call PACK,dbus,DEB_DBUS_V)
	rm -rf $(BUILD_DIST)/dbus

.PHONY: dbus dbus-package
