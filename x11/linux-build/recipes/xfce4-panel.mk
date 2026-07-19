ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# xfce4-panel — the XFCE panel (+ libxfce4panel-2.0 used by plugins). libwnck3 powers the
# tasklist/pager/windowmenu plugins. GTK3 is available; this recipe is not yet build-validated.
SUBPROJECTS        += xfce4-panel
XFCE4PANEL_MAJOR_V := 4.16
XFCE4PANEL_VERSION := $(XFCE4PANEL_MAJOR_V).6
DEB_XFCE4PANEL_V   ?= $(XFCE4PANEL_VERSION)+ios1

xfce4-panel-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://archive.xfce.org/src/xfce/xfce4-panel/$(XFCE4PANEL_MAJOR_V)/xfce4-panel-$(XFCE4PANEL_VERSION).tar.bz2)
	$(call EXTRACT_TAR,xfce4-panel-$(XFCE4PANEL_VERSION).tar.bz2,xfce4-panel-$(XFCE4PANEL_VERSION),xfce4-panel)

ifneq ($(wildcard $(BUILD_WORK)/xfce4-panel/.build_complete),)
xfce4-panel:
	@echo "Using previously built xfce4-panel."
else
xfce4-panel: xfce4-panel-setup gtk+3.0 libxfce4util libxfce4ui exo garcon xfconf libwnck3
	cd $(BUILD_WORK)/xfce4-panel && ./configure -C \
		$(DEFAULT_CONFIGURE_FLAGS) \
		--disable-static \
		--disable-gtk-doc \
		--disable-introspection \
		--disable-debug
	+$(MAKE) -C $(BUILD_WORK)/xfce4-panel
	+$(MAKE) -C $(BUILD_WORK)/xfce4-panel install DESTDIR=$(BUILD_STAGE)/xfce4-panel
	$(call AFTER_BUILD,copy)
endif

xfce4-panel-package: xfce4-panel-stage
	rm -rf $(BUILD_DIST)/xfce4-panel
	mkdir -p $(BUILD_DIST)/xfce4-panel
	cp -a $(BUILD_STAGE)/xfce4-panel/$(MEMO_PREFIX) $(BUILD_DIST)/xfce4-panel/

	rm -rf $(BUILD_DIST)/xfce4-panel/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/xfce4-panel/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig \
		$(BUILD_DIST)/xfce4-panel/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/*.a \
		$(BUILD_DIST)/xfce4-panel/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/gtk-doc

	$(call SIGN,xfce4-panel,general.xml)
	$(call PACK,xfce4-panel,DEB_XFCE4PANEL_V)
	rm -rf $(BUILD_DIST)/xfce4-panel

.PHONY: xfce4-panel xfce4-panel-package
