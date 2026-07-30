ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# xfconf — XFCE configuration store. Ships libxfconf-0 + the xfconfd daemon (a session-bus
# service) + xfconf-query. GTK-independent (glib/gio + GDBus), so buildable ahead of GTK.
# dbus is a RUNTIME dep (xfconfd is D-Bus activated); listed as a build prereq for ordering.
SUBPROJECTS   += xfconf
XFCONF_MAJOR_V := 4.16
XFCONF_VERSION := $(XFCONF_MAJOR_V).0
DEB_XFCONF_V   ?= $(XFCONF_VERSION)+ios1

xfconf-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://archive.xfce.org/src/xfce/xfconf/$(XFCONF_MAJOR_V)/xfconf-$(XFCONF_VERSION).tar.bz2)
	$(call EXTRACT_TAR,xfconf-$(XFCONF_VERSION).tar.bz2,xfconf-$(XFCONF_VERSION),xfconf)

ifneq ($(wildcard $(BUILD_WORK)/xfconf/.build_complete),)
xfconf:
	@echo "Using previously built xfconf."
else
xfconf: xfconf-setup glib2.0 libxfce4util dbus
	cd $(BUILD_WORK)/xfconf && ac_cv_func_fdatasync=no ./configure -C \
		$(DEFAULT_CONFIGURE_FLAGS) \
		--disable-static \
		--disable-gtk-doc \
		--disable-introspection \
		--disable-visibility \
		--disable-debug
	+$(MAKE) -C $(BUILD_WORK)/xfconf
	+$(MAKE) -C $(BUILD_WORK)/xfconf install DESTDIR=$(BUILD_STAGE)/xfconf
	$(call AFTER_BUILD,copy)
endif

xfconf-package: xfconf-stage
	rm -rf $(BUILD_DIST)/xfconf
	mkdir -p $(BUILD_DIST)/xfconf$(MEMO_PREFIX)
	cp -a $(BUILD_STAGE)/xfconf$(MEMO_PREFIX)/. $(BUILD_DIST)/xfconf$(MEMO_PREFIX)/

	rm -rf $(BUILD_DIST)/xfconf/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/xfconf/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig \
		$(BUILD_DIST)/xfconf/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/*.a \
		$(BUILD_DIST)/xfconf/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/gtk-doc

	$(call SIGN,xfconf,general.xml)
	$(call PACK,xfconf,DEB_XFCONF_V)
	rm -rf $(BUILD_DIST)/xfconf

.PHONY: xfconf xfconf-package
