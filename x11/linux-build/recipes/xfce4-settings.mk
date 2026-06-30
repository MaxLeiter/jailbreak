ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# xfce4-settings — settings manager + xfsettingsd daemon (theme/dpi/keyboard/display).
# Uses libX11/Xi/Xrandr/Xcursor (all in Procursus). libnotify/libxklavier/upower are
# optional and auto-disable when absent. BLOCKED on the GTK3 stack.
SUBPROJECTS           += xfce4-settings
XFCE4SETTINGS_MAJOR_V := 4.16
XFCE4SETTINGS_VERSION := $(XFCE4SETTINGS_MAJOR_V).5
DEB_XFCE4SETTINGS_V   ?= $(XFCE4SETTINGS_VERSION)

xfce4-settings-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://archive.xfce.org/src/xfce/xfce4-settings/$(XFCE4SETTINGS_MAJOR_V)/xfce4-settings-$(XFCE4SETTINGS_VERSION).tar.bz2)
	$(call EXTRACT_TAR,xfce4-settings-$(XFCE4SETTINGS_VERSION).tar.bz2,xfce4-settings-$(XFCE4SETTINGS_VERSION),xfce4-settings)

ifneq ($(wildcard $(BUILD_WORK)/xfce4-settings/.build_complete),)
xfce4-settings:
	@echo "Using previously built xfce4-settings."
else
xfce4-settings: xfce4-settings-setup gtk+3.0 libxfce4util libxfce4ui exo xfconf garcon libx11 libxi libxrandr libxcursor
	cd $(BUILD_WORK)/xfce4-settings && ./configure -C \
		$(DEFAULT_CONFIGURE_FLAGS) \
		--disable-static \
		--disable-gtk-doc \
		--disable-debug \
		--enable-xrandr \
		--disable-libnotify \
		--disable-xklavier
	+$(MAKE) -C $(BUILD_WORK)/xfce4-settings
	+$(MAKE) -C $(BUILD_WORK)/xfce4-settings install DESTDIR=$(BUILD_STAGE)/xfce4-settings
	$(call AFTER_BUILD,copy)
endif

xfce4-settings-package: xfce4-settings-stage
	rm -rf $(BUILD_DIST)/xfce4-settings
	mkdir -p $(BUILD_DIST)/xfce4-settings
	cp -a $(BUILD_STAGE)/xfce4-settings/$(MEMO_PREFIX) $(BUILD_DIST)/xfce4-settings/

	rm -rf $(BUILD_DIST)/xfce4-settings/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/xfce4-settings/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig \
		$(BUILD_DIST)/xfce4-settings/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/*.a \
		$(BUILD_DIST)/xfce4-settings/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/gtk-doc

	$(call SIGN,xfce4-settings,general.xml)
	$(call PACK,xfce4-settings,DEB_XFCE4SETTINGS_V)
	rm -rf $(BUILD_DIST)/xfce4-settings

.PHONY: xfce4-settings xfce4-settings-package
