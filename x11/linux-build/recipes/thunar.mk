ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# Thunar — XFCE file manager (+ libthunarx-3 plugin lib). gudev (udev) and libnotify are
# Linux-only/absent and auto-disable -> local browsing only, no removable-media mounting.
# BLOCKED on the GTK3 stack. NOTE: verify tarball case ('thunar' vs 'Thunar') at build.
SUBPROJECTS    += thunar
THUNAR_MAJOR_V := 4.16
THUNAR_VERSION := $(THUNAR_MAJOR_V).11
DEB_THUNAR_V   ?= $(THUNAR_VERSION)+ios1

thunar-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://archive.xfce.org/src/xfce/thunar/$(THUNAR_MAJOR_V)/thunar-$(THUNAR_VERSION).tar.bz2)
	$(call EXTRACT_TAR,thunar-$(THUNAR_VERSION).tar.bz2,thunar-$(THUNAR_VERSION),thunar)

ifneq ($(wildcard $(BUILD_WORK)/thunar/.build_complete),)
thunar:
	@echo "Using previously built thunar."
else
thunar: thunar-setup gtk+3.0 gdk-pixbuf exo libxfce4util libxfce4ui
	cd $(BUILD_WORK)/thunar && ./configure -C \
		$(DEFAULT_CONFIGURE_FLAGS) \
		--disable-static \
		--disable-gtk-doc \
		--disable-introspection \
		--disable-debug \
		--disable-gudev \
		--disable-libnotify
	+$(MAKE) -C $(BUILD_WORK)/thunar
	+$(MAKE) -C $(BUILD_WORK)/thunar install DESTDIR=$(BUILD_STAGE)/thunar
	$(call AFTER_BUILD,copy)
endif

thunar-package: thunar-stage
	rm -rf $(BUILD_DIST)/thunar
	mkdir -p $(BUILD_DIST)/thunar
	cp -a $(BUILD_STAGE)/thunar/$(MEMO_PREFIX) $(BUILD_DIST)/thunar/

	rm -rf $(BUILD_DIST)/thunar/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/thunar/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig \
		$(BUILD_DIST)/thunar/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/*.a \
		$(BUILD_DIST)/thunar/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/gtk-doc

	$(call SIGN,thunar,general.xml)
	$(call PACK,thunar,DEB_THUNAR_V)
	rm -rf $(BUILD_DIST)/thunar

.PHONY: thunar thunar-package
