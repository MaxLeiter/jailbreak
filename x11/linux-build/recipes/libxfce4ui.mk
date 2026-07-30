ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# libxfce4ui — XFCE GTK3 widget library (also libxfce4kbd-private + xfce4-ui utils).
# First GTK-linked XFCE brick. GTK3 is available; this recipe is not yet build-validated.
SUBPROJECTS        += libxfce4ui
LIBXFCE4UI_MAJOR_V := 4.16
LIBXFCE4UI_VERSION := $(LIBXFCE4UI_MAJOR_V).0
DEB_LIBXFCE4UI_V   ?= $(LIBXFCE4UI_VERSION)+ios1

libxfce4ui-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://archive.xfce.org/src/xfce/libxfce4ui/$(LIBXFCE4UI_MAJOR_V)/libxfce4ui-$(LIBXFCE4UI_VERSION).tar.bz2)
	$(call EXTRACT_TAR,libxfce4ui-$(LIBXFCE4UI_VERSION).tar.bz2,libxfce4ui-$(LIBXFCE4UI_VERSION),libxfce4ui)

ifneq ($(wildcard $(BUILD_WORK)/libxfce4ui/.build_complete),)
libxfce4ui:
	@echo "Using previously built libxfce4ui."
else
libxfce4ui: libxfce4ui-setup gtk+3.0 libxfce4util xfconf startup-notification libepoxy
	cd $(BUILD_WORK)/libxfce4ui && ./configure -C \
		$(DEFAULT_CONFIGURE_FLAGS) \
		--disable-static \
		--disable-gtk-doc \
		--disable-introspection \
		--disable-glade \
		--disable-vala \
		--disable-visibility \
		--disable-glibtop \
		--disable-debug
	+$(MAKE) -C $(BUILD_WORK)/libxfce4ui
	+$(MAKE) -C $(BUILD_WORK)/libxfce4ui install DESTDIR=$(BUILD_STAGE)/libxfce4ui
	$(call AFTER_BUILD,copy)
endif

libxfce4ui-package: libxfce4ui-stage
	rm -rf $(BUILD_DIST)/libxfce4ui-2-0
	mkdir -p $(BUILD_DIST)/libxfce4ui-2-0$(MEMO_PREFIX)
	cp -a $(BUILD_STAGE)/libxfce4ui$(MEMO_PREFIX)/. \
		$(BUILD_DIST)/libxfce4ui-2-0$(MEMO_PREFIX)/

	rm -rf $(BUILD_DIST)/libxfce4ui-2-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libxfce4ui-2-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig \
		$(BUILD_DIST)/libxfce4ui-2-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/*.a \
		$(BUILD_DIST)/libxfce4ui-2-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/gtk-doc

	$(call SIGN,libxfce4ui-2-0,general.xml)
	$(call PACK,libxfce4ui-2-0,DEB_LIBXFCE4UI_V)
	rm -rf $(BUILD_DIST)/libxfce4ui-2-0

.PHONY: libxfce4ui libxfce4ui-package
