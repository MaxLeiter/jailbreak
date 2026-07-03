ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# startup-notification — launch feedback library; required by xfwm4, optional for
# libxfce4ui/xfce4-panel. Not in Procursus. Classic autotools (xcb backend).
SUBPROJECTS  += startup-notification
STARTUPNOTIFICATION_VERSION := 0.12
DEB_STARTUPNOTIFICATION_V   ?= $(STARTUPNOTIFICATION_VERSION)+ios2

startup-notification-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://www.freedesktop.org/software/startup-notification/releases/startup-notification-$(STARTUPNOTIFICATION_VERSION).tar.gz)
	$(call EXTRACT_TAR,startup-notification-$(STARTUPNOTIFICATION_VERSION).tar.gz,startup-notification-$(STARTUPNOTIFICATION_VERSION),startup-notification)
	# the 2012 tarball's config.sub predates the aarch64-apple-darwin triple
	cp -af $(BUILD_MISC)/config.guess $(BUILD_MISC)/config.sub $(BUILD_WORK)/startup-notification/

ifneq ($(wildcard $(BUILD_WORK)/startup-notification/.build_complete),)
startup-notification:
	@echo "Using previously built startup-notification."
else
startup-notification: startup-notification-setup libx11 libxcb xcb-util
	cd $(BUILD_WORK)/startup-notification && ./configure -C \
		$(DEFAULT_CONFIGURE_FLAGS) \
		--disable-static \
		--with-x \
		lf_cv_sane_realloc=yes
	+$(MAKE) -C $(BUILD_WORK)/startup-notification
	+$(MAKE) -C $(BUILD_WORK)/startup-notification install DESTDIR=$(BUILD_STAGE)/startup-notification
	$(call AFTER_BUILD,copy)
endif

startup-notification-package: startup-notification-stage
	rm -rf $(BUILD_DIST)/libstartup-notification0 $(BUILD_DIST)/libstartup-notification-dev
	mkdir -p $(BUILD_DIST)/libstartup-notification0$(MEMO_PREFIX) \
		$(BUILD_DIST)/libstartup-notification-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	# copy the CONTENTS of the staged prefix (copying $(MEMO_PREFIX) itself drops the leading
	# `var/` from /var/jb -> installs to /jb).
	cp -a $(BUILD_STAGE)/startup-notification$(MEMO_PREFIX)/. $(BUILD_DIST)/libstartup-notification0$(MEMO_PREFIX)/

	# -dev: headers + .pc + unversioned symlink (gnome-shell's cross AND on-device
	# introspection builds need libstartup-notification-1.0.pc)
	cp -a $(BUILD_STAGE)/startup-notification/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libstartup-notification-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/startup-notification/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig \
		$(BUILD_DIST)/libstartup-notification-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/startup-notification/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libstartup-notification-1.dylib \
		$(BUILD_DIST)/libstartup-notification-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib 2>/dev/null || true

	rm -rf $(BUILD_DIST)/libstartup-notification0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libstartup-notification0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig \
		$(BUILD_DIST)/libstartup-notification0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libstartup-notification-1.dylib \
		$(BUILD_DIST)/libstartup-notification0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/*.a \
		$(BUILD_DIST)/libstartup-notification0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/doc

	$(call SIGN,libstartup-notification0,general.xml)
	$(call PACK,libstartup-notification0,DEB_STARTUPNOTIFICATION_V)
	$(call PACK,libstartup-notification-dev,DEB_STARTUPNOTIFICATION_V)
	rm -rf $(BUILD_DIST)/libstartup-notification0 $(BUILD_DIST)/libstartup-notification-dev

.PHONY: startup-notification startup-notification-package
