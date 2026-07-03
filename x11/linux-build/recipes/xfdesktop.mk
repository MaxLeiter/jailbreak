ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# xfdesktop — desktop background, right-click menu and desktop icons. libwnck3 (workspace
# awareness) and thunarx (file icons) are used; thunarx is optional here. BLOCKED on GTK3.
SUBPROJECTS       += xfdesktop
XFDESKTOP_MAJOR_V := 4.16
XFDESKTOP_VERSION := $(XFDESKTOP_MAJOR_V).1
DEB_XFDESKTOP_V   ?= $(XFDESKTOP_VERSION)+ios1

xfdesktop-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://archive.xfce.org/src/xfce/xfdesktop/$(XFDESKTOP_MAJOR_V)/xfdesktop-$(XFDESKTOP_VERSION).tar.bz2)
	$(call EXTRACT_TAR,xfdesktop-$(XFDESKTOP_VERSION).tar.bz2,xfdesktop-$(XFDESKTOP_VERSION),xfdesktop)

ifneq ($(wildcard $(BUILD_WORK)/xfdesktop/.build_complete),)
xfdesktop:
	@echo "Using previously built xfdesktop."
else
xfdesktop: xfdesktop-setup gtk+3.0 libxfce4util libxfce4ui exo garcon xfconf libwnck3
	cd $(BUILD_WORK)/xfdesktop && ./configure -C \
		$(DEFAULT_CONFIGURE_FLAGS) \
		--disable-static \
		--disable-gtk-doc \
		--disable-debug
	+$(MAKE) -C $(BUILD_WORK)/xfdesktop
	+$(MAKE) -C $(BUILD_WORK)/xfdesktop install DESTDIR=$(BUILD_STAGE)/xfdesktop
	$(call AFTER_BUILD,copy)
endif

xfdesktop-package: xfdesktop-stage
	rm -rf $(BUILD_DIST)/xfdesktop4
	mkdir -p $(BUILD_DIST)/xfdesktop4
	cp -a $(BUILD_STAGE)/xfdesktop/$(MEMO_PREFIX) $(BUILD_DIST)/xfdesktop4/

	rm -rf $(BUILD_DIST)/xfdesktop4/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/xfdesktop4/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig \
		$(BUILD_DIST)/xfdesktop4/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/*.a \
		$(BUILD_DIST)/xfdesktop4/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/gtk-doc

	$(call SIGN,xfdesktop4,general.xml)
	$(call PACK,xfdesktop4,DEB_XFDESKTOP_V)
	rm -rf $(BUILD_DIST)/xfdesktop4

.PHONY: xfdesktop xfdesktop-package
