ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# xfce4-appfinder — lightweight application launcher / finder. Cheap, very useful as the
# primary way to launch apps with the iOS keyboard. GTK3 is available; this
# recipe is not yet build-validated.
SUBPROJECTS            += xfce4-appfinder
XFCE4APPFINDER_MAJOR_V := 4.16
XFCE4APPFINDER_VERSION := $(XFCE4APPFINDER_MAJOR_V).0
DEB_XFCE4APPFINDER_V   ?= $(XFCE4APPFINDER_VERSION)+ios1

xfce4-appfinder-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://archive.xfce.org/src/xfce/xfce4-appfinder/$(XFCE4APPFINDER_MAJOR_V)/xfce4-appfinder-$(XFCE4APPFINDER_VERSION).tar.bz2)
	$(call EXTRACT_TAR,xfce4-appfinder-$(XFCE4APPFINDER_VERSION).tar.bz2,xfce4-appfinder-$(XFCE4APPFINDER_VERSION),xfce4-appfinder)

ifneq ($(wildcard $(BUILD_WORK)/xfce4-appfinder/.build_complete),)
xfce4-appfinder:
	@echo "Using previously built xfce4-appfinder."
else
xfce4-appfinder: xfce4-appfinder-setup gtk+3.0 libxfce4util libxfce4ui garcon xfconf
	cd $(BUILD_WORK)/xfce4-appfinder && ./configure -C \
		$(DEFAULT_CONFIGURE_FLAGS) \
		--disable-static \
		--disable-gtk-doc \
		--disable-debug
	+$(MAKE) -C $(BUILD_WORK)/xfce4-appfinder
	+$(MAKE) -C $(BUILD_WORK)/xfce4-appfinder install DESTDIR=$(BUILD_STAGE)/xfce4-appfinder
	$(call AFTER_BUILD,copy)
endif

xfce4-appfinder-package: xfce4-appfinder-stage
	rm -rf $(BUILD_DIST)/xfce4-appfinder
	mkdir -p $(BUILD_DIST)/xfce4-appfinder
	cp -a $(BUILD_STAGE)/xfce4-appfinder/$(MEMO_PREFIX) $(BUILD_DIST)/xfce4-appfinder/

	rm -rf $(BUILD_DIST)/xfce4-appfinder/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/xfce4-appfinder/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig \
		$(BUILD_DIST)/xfce4-appfinder/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/*.a \
		$(BUILD_DIST)/xfce4-appfinder/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/gtk-doc

	$(call SIGN,xfce4-appfinder,general.xml)
	$(call PACK,xfce4-appfinder,DEB_XFCE4APPFINDER_V)
	rm -rf $(BUILD_DIST)/xfce4-appfinder

.PHONY: xfce4-appfinder xfce4-appfinder-package
