ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# garcon — freedesktop.org menu (.menu) library for XFCE (libgarcon-1 + libgarcon-gtk3).
# GTK3 is available; this recipe is not yet build-validated.
SUBPROJECTS    += garcon
GARCON_MAJOR_V := 4.16
GARCON_VERSION := $(GARCON_MAJOR_V).1
DEB_GARCON_V   ?= $(GARCON_VERSION)+ios1

garcon-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://archive.xfce.org/src/xfce/garcon/$(GARCON_MAJOR_V)/garcon-$(GARCON_VERSION).tar.bz2)
	$(call EXTRACT_TAR,garcon-$(GARCON_VERSION).tar.bz2,garcon-$(GARCON_VERSION),garcon)

ifneq ($(wildcard $(BUILD_WORK)/garcon/.build_complete),)
garcon:
	@echo "Using previously built garcon."
else
garcon: garcon-setup glib2.0 gtk+3.0 libxfce4util libxfce4ui
	cd $(BUILD_WORK)/garcon && ./configure -C \
		$(DEFAULT_CONFIGURE_FLAGS) \
		--disable-static \
		--disable-gtk-doc \
		--disable-introspection \
		--disable-debug
	+$(MAKE) -C $(BUILD_WORK)/garcon
	+$(MAKE) -C $(BUILD_WORK)/garcon install DESTDIR=$(BUILD_STAGE)/garcon
	$(call AFTER_BUILD,copy)
endif

garcon-package: garcon-stage
	rm -rf $(BUILD_DIST)/libgarcon-1-0
	mkdir -p $(BUILD_DIST)/libgarcon-1-0
	cp -a $(BUILD_STAGE)/garcon/$(MEMO_PREFIX) $(BUILD_DIST)/libgarcon-1-0/

	rm -rf $(BUILD_DIST)/libgarcon-1-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libgarcon-1-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig \
		$(BUILD_DIST)/libgarcon-1-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/*.a \
		$(BUILD_DIST)/libgarcon-1-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/gtk-doc

	$(call SIGN,libgarcon-1-0,general.xml)
	$(call PACK,libgarcon-1-0,DEB_GARCON_V)
	rm -rf $(BUILD_DIST)/libgarcon-1-0

.PHONY: garcon garcon-package
