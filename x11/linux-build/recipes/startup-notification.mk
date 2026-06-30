ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# startup-notification — launch feedback library; required by xfwm4, optional for
# libxfce4ui/xfce4-panel. Not in Procursus. Classic autotools (xcb backend).
SUBPROJECTS  += startup-notification
STARTUPNOTIFICATION_VERSION := 0.12
DEB_STARTUPNOTIFICATION_V   ?= $(STARTUPNOTIFICATION_VERSION)

startup-notification-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://www.freedesktop.org/software/startup-notification/releases/startup-notification-$(STARTUPNOTIFICATION_VERSION).tar.gz)
	$(call EXTRACT_TAR,startup-notification-$(STARTUPNOTIFICATION_VERSION).tar.gz,startup-notification-$(STARTUPNOTIFICATION_VERSION),startup-notification)

ifneq ($(wildcard $(BUILD_WORK)/startup-notification/.build_complete),)
startup-notification:
	@echo "Using previously built startup-notification."
else
startup-notification: startup-notification-setup libx11 libxcb xcb-util
	cd $(BUILD_WORK)/startup-notification && ./configure -C \
		$(DEFAULT_CONFIGURE_FLAGS) \
		--disable-static \
		--with-x
	+$(MAKE) -C $(BUILD_WORK)/startup-notification
	+$(MAKE) -C $(BUILD_WORK)/startup-notification install DESTDIR=$(BUILD_STAGE)/startup-notification
	$(call AFTER_BUILD,copy)
endif

startup-notification-package: startup-notification-stage
	rm -rf $(BUILD_DIST)/libstartup-notification0
	mkdir -p $(BUILD_DIST)/libstartup-notification0
	cp -a $(BUILD_STAGE)/startup-notification/$(MEMO_PREFIX) $(BUILD_DIST)/libstartup-notification0/

	rm -rf $(BUILD_DIST)/libstartup-notification0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libstartup-notification0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig \
		$(BUILD_DIST)/libstartup-notification0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/*.a \
		$(BUILD_DIST)/libstartup-notification0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/doc

	$(call SIGN,libstartup-notification0,general.xml)
	$(call PACK,libstartup-notification0,DEB_STARTUPNOTIFICATION_V)
	rm -rf $(BUILD_DIST)/libstartup-notification0

.PHONY: startup-notification startup-notification-package
