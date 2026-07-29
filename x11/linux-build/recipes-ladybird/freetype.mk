ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# --without-harfbuzz breaks the freetype<->harfbuzz circular dependency; harfbuzz is
# built afterward, with freetype enabled.

SUBPROJECTS      += freetype
FREETYPE_VERSION := 2.13.3
DEB_FREETYPE_V   ?= $(FREETYPE_VERSION)+ios1

freetype-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.savannah.gnu.org/releases/freetype/freetype-$(FREETYPE_VERSION).tar.xz)
	# Stale-tree guard: wipe a mismatched (gtk-era 2.12.1) tree so 2.13.3 extracts.
	if [ -d $(BUILD_WORK)/freetype ] && ! grep -q "FREETYPE_VERSION = $(FREETYPE_VERSION)" $(BUILD_WORK)/freetype/docs/VERSIONS.TXT 2>/dev/null && ! grep -rq "$(FREETYPE_VERSION)" $(BUILD_WORK)/freetype/README 2>/dev/null; then \
		echo "freetype: stale source tree (not $(FREETYPE_VERSION)), wiping"; \
		rm -rf $(BUILD_WORK)/freetype $(BUILD_STAGE)/freetype; \
	fi
	$(call EXTRACT_TAR,freetype-$(FREETYPE_VERSION).tar.xz,freetype-$(FREETYPE_VERSION),freetype)

ifneq ($(wildcard $(BUILD_WORK)/freetype/.build_complete),)
freetype:
	@echo "Using previously built freetype."
else
freetype: freetype-setup brotli libpng16
	cd $(BUILD_WORK)/freetype && ./configure -C \
		$(DEFAULT_CONFIGURE_FLAGS) \
		--without-harfbuzz \
		--with-brotli \
		--with-png \
		--with-zlib \
		CC_BUILD="$(CC_FOR_BUILD)"
	+$(MAKE) -C $(BUILD_WORK)/freetype
	+$(MAKE) -C $(BUILD_WORK)/freetype install \
		DESTDIR=$(BUILD_STAGE)/freetype
	$(call AFTER_BUILD,copy)
endif

freetype-package: .SHELLFLAGS=-O extglob -c
freetype-package: freetype-stage
	# freetype.mk Package Structure
	rm -rf $(BUILD_DIST)/libfreetype{6,-dev}
	mkdir -p $(BUILD_DIST)/libfreetype{6,-dev}/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# freetype.mk Prep libfreetype6
	cp -a $(BUILD_STAGE)/freetype/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libfreetype.6.dylib $(BUILD_DIST)/libfreetype6/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# freetype.mk Prep libfreetype-dev
	cp -a $(BUILD_STAGE)/freetype/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/{libfreetype.{a,dylib},pkgconfig} $(BUILD_DIST)/libfreetype-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/freetype/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/{include,share} $(BUILD_DIST)/libfreetype-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	# freetype.mk Sign
	$(call SIGN,libfreetype6,general.xml)

	# freetype.mk Make .debs
	$(call PACK,libfreetype6,DEB_FREETYPE_V)
	$(call PACK,libfreetype-dev,DEB_FREETYPE_V)

	# freetype.mk Build cleanup
	rm -rf $(BUILD_DIST)/libfreetype{6,-dev}

.PHONY: freetype freetype-package
