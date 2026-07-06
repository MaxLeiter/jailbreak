ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# yad.mk - YAD, a GTK3 dialog utility for scripts. Upstream is plain C/autotools
# and only hard-requires gtk+-3.0 >= 3.22 plus gtk+-unix-print-3.0, which matches
# the verified Xios GTK3 Wayland path used by hitori/zathura.
#
# Initial iOS cut intentionally disables optional WebKit, spell, GtkSourceView,
# AppIndicator, and tray/status-icon support. That keeps the package useful for
# script dialogs without pulling in unported desktop notification/status stacks.
# The GitHub tag archive does not ship generated configure, so setup runs
# autoreconf before configure like iso-codes.mk.

SUBPROJECTS  += yad
YAD_VERSION  := 15.0
DEB_YAD_V    ?= $(YAD_VERSION)+ios1

yad-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://github.com/v1cont/yad/archive/refs/tags/v$(YAD_VERSION).tar.gz)
	$(call EXTRACT_TAR,v$(YAD_VERSION).tar.gz,yad-$(YAD_VERSION),yad)

ifneq ($(wildcard $(BUILD_WORK)/yad/.build_complete),)
yad:
	@echo "Using previously built yad."
else
yad: yad-setup gtk+3.0
	cd $(BUILD_WORK)/yad && [ -f configure ] || autoreconf -fi
	cd $(BUILD_WORK)/yad && ./configure -C \
		$(DEFAULT_CONFIGURE_FLAGS) \
		--with-rgb=$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/X11/rgb.txt \
		--disable-html \
		--disable-spell \
		--disable-sourceview \
		--disable-appindicator \
		--disable-tray \
		--disable-deprecated
	+$(MAKE) -C $(BUILD_WORK)/yad
	+$(MAKE) -C $(BUILD_WORK)/yad install DESTDIR=$(BUILD_STAGE)/yad
	# gettext's unversioned libintl.dylib is a -dev artifact; runtime ships libintl.8.
	for f in $$(find $(BUILD_STAGE)/yad/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin -type f 2>/dev/null); do \
		$(I_N_T) -change @rpath/libintl.dylib @rpath/libintl.8.dylib $$f 2>/dev/null || true; \
	done
	$(call AFTER_BUILD,copy)
endif

yad-package: yad-stage
	rm -rf $(BUILD_DIST)/yad
	mkdir -p $(BUILD_DIST)/yad/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	# app: bin/yad, yad-tools, yad-icon-browser, yad-settings + desktop/icon/locale data
	cp -a $(BUILD_STAGE)/yad/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin $(BUILD_DIST)/yad/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/yad/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share $(BUILD_DIST)/yad/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	$(call SIGN,yad,iosc-gpu-client-ent.xml,,,nogeneral)
	$(call PACK,yad,DEB_YAD_V)
	rm -rf $(BUILD_DIST)/yad

.PHONY: yad yad-package
