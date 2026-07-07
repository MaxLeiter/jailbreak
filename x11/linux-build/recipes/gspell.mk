ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# gspell.mk — GTK3 spell-checking widgets for Geary. GIR/VAPI generation is disabled for
# the cross pass; Vala consumers will need vendored bindings or an on-device GI/VAPI pass.

SUBPROJECTS     += gspell
GSPELL_MAJOR_V  := 1.12
GSPELL_VERSION  := $(GSPELL_MAJOR_V).2
DEB_GSPELL_V    ?= $(GSPELL_VERSION)+ios1

gspell-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/gspell/$(GSPELL_MAJOR_V)/gspell-$(GSPELL_VERSION).tar.xz)
	$(call EXTRACT_TAR,gspell-$(GSPELL_VERSION).tar.xz,gspell-$(GSPELL_VERSION),gspell)

ifneq ($(wildcard $(BUILD_WORK)/gspell/.build_complete),)
gspell:
	@echo "Using previously built gspell."
else
gspell: gspell-setup glib2.0 gtk+3.0 enchant icu4c
	cd $(BUILD_WORK)/gspell && GLIB_MKENUMS=/usr/bin/glib-mkenums \
		GLIB_COMPILE_RESOURCES=/usr/bin/glib-compile-resources \
		./configure -C \
		$(DEFAULT_CONFIGURE_FLAGS) \
		--disable-static \
		--disable-gtk-doc \
		--disable-installed-tests \
		--disable-introspection \
		--enable-vala=no \
		--enable-compile-warnings=no \
		--disable-Werror
	+$(MAKE) -C $(BUILD_WORK)/gspell
	+$(MAKE) -C $(BUILD_WORK)/gspell install DESTDIR=$(BUILD_STAGE)/gspell
	$(call AFTER_BUILD,copy)
endif

gspell-package: gspell-stage
	rm -rf $(BUILD_DIST)/libgspell-1-2 $(BUILD_DIST)/libgspell-1-dev
	mkdir -p $(BUILD_DIST)/libgspell-1-2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libgspell-1-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	cp -a $(BUILD_STAGE)/gspell/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libgspell-1.*.dylib \
		$(BUILD_DIST)/libgspell-1-2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	if [ -d "$(BUILD_STAGE)/gspell/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/locale" ]; then \
		mkdir -p $(BUILD_DIST)/libgspell-1-2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share; \
		cp -a $(BUILD_STAGE)/gspell/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/locale \
			$(BUILD_DIST)/libgspell-1-2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share; \
	fi

	cp -a $(BUILD_STAGE)/gspell/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/!(libgspell-1.*.dylib) \
		$(BUILD_DIST)/libgspell-1-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/gspell/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libgspell-1-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	$(call SIGN,libgspell-1-2,general.xml)
	$(call PACK,libgspell-1-2,DEB_GSPELL_V)
	$(call PACK,libgspell-1-dev,DEB_GSPELL_V)
	rm -rf $(BUILD_DIST)/libgspell-1-2 $(BUILD_DIST)/libgspell-1-dev

.PHONY: gspell gspell-package
