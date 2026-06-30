ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# enchant.mk — spell-checking abstraction library. Leaf dependency of gnome-text-editor.
# Autotools (not meson), like the XFCE track's dbus.mk. Builds fine with NO dictionary
# backend (hunspell/aspell/nuspell) — spell-checking is then a no-op, which is acceptable for
# first-light; add a backend later. glib only otherwise.
#
# DRAFT — Phase 1, NOT built/verified.

SUBPROJECTS     += enchant
ENCHANT_VERSION := 2.6.1
DEB_ENCHANT_V   ?= $(ENCHANT_VERSION)

enchant-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://github.com/AbiWord/enchant/releases/download/v$(ENCHANT_VERSION)/enchant-$(ENCHANT_VERSION).tar.gz)
	$(call EXTRACT_TAR,enchant-$(ENCHANT_VERSION).tar.gz,enchant-$(ENCHANT_VERSION),enchant)

ifneq ($(wildcard $(BUILD_WORK)/enchant/.build_complete),)
enchant:
	@echo "Using previously built enchant."
else
enchant: enchant-setup glib2.0
	cd $(BUILD_WORK)/enchant && ./configure -C \
		$(DEFAULT_CONFIGURE_FLAGS) \
		--disable-static \
		--enable-relocatable
	+$(MAKE) -C $(BUILD_WORK)/enchant
	+$(MAKE) -C $(BUILD_WORK)/enchant install DESTDIR=$(BUILD_STAGE)/enchant
	$(call AFTER_BUILD,copy)
endif

enchant-package: enchant-stage
	rm -rf $(BUILD_DIST)/libenchant-2-2 $(BUILD_DIST)/libenchant-2-dev
	mkdir -p $(BUILD_DIST)/libenchant-2-2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libenchant-2-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# libenchant-2-2 (runtime dylib + provider modules + enchant-2 tool)
	cp -a $(BUILD_STAGE)/enchant/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libenchant-2.2.dylib $(BUILD_DIST)/libenchant-2-2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	if [ -d "$(BUILD_STAGE)/enchant/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/enchant-2" ]; then \
		cp -a $(BUILD_STAGE)/enchant/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/enchant-2 $(BUILD_DIST)/libenchant-2-2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib; \
	fi
	if [ -d "$(BUILD_STAGE)/enchant/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin" ]; then \
		cp -a $(BUILD_STAGE)/enchant/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin $(BUILD_DIST)/libenchant-2-2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
	fi

	# libenchant-2-dev (headers, symlink, .pc)
	cp -a $(BUILD_STAGE)/enchant/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/!(libenchant-2.2.dylib|enchant-2) $(BUILD_DIST)/libenchant-2-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/enchant/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/libenchant-2-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	$(call SIGN,libenchant-2-2,general.xml)
	$(call PACK,libenchant-2-2,DEB_ENCHANT_V)
	$(call PACK,libenchant-2-dev,DEB_ENCHANT_V)
	rm -rf $(BUILD_DIST)/libenchant-2-2 $(BUILD_DIST)/libenchant-2-dev

.PHONY: enchant enchant-package
