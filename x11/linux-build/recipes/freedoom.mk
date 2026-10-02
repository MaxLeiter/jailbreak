ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# Freedoom: the free Doom/Doom II IWADs, so crispy-doom has game data from a
# normal apt install (the same role openttd-opengfx plays for OpenTTD). Data
# only: no Mach-O, nothing to sign. The WADs land in share/games/doom, the
# directory the crispy-doom wrapper exports as DOOMWADDIR.
#
# Freedoom is BSD-licensed. PACK replaces share/doc with the COPYING/AUTHORS
# files it finds in the work tree, so the release's COPYING.txt and credits are
# placed there under those names.

SUBPROJECTS       += freedoom
FREEDOOM_VERSION  := 0.13.0
DEB_FREEDOOM_V    ?= $(FREEDOOM_VERSION)+ios1
# Matches upstream's signed freedoom-0.13.0-CHECKSUM. Pinned so a re-rolled or
# truncated download fails loudly instead of shipping unreviewed content.
FREEDOOM_SHA256   := 3f9b264f3e3ce503b4fb7f6bdcb1f419d93c7b546f4df3e874dd878db9688f59
FREEDOOM_ARCHIVE  := freedoom-$(FREEDOOM_VERSION).zip

freedoom-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://github.com/freedoom/freedoom/releases/download/v$(FREEDOOM_VERSION)/$(FREEDOOM_ARCHIVE))
	if ! echo "$(FREEDOOM_SHA256)  $(BUILD_SOURCE)/$(FREEDOOM_ARCHIVE)" | sha256sum -c --status -; then \
		echo "ERROR: $(FREEDOOM_ARCHIVE) checksum mismatch, removing it for a refetch" >&2; \
		rm -f "$(BUILD_SOURCE)/$(FREEDOOM_ARCHIVE)"; \
		exit 1; \
	fi
	if [ ! -f "$(BUILD_WORK)/freedoom/.xios_setup_$(DEB_FREEDOOM_V)" ]; then \
		rm -rf $(BUILD_WORK)/freedoom $(BUILD_WORK)/freedoom-$(FREEDOOM_VERSION); \
		{ cd $(BUILD_WORK) && \
			python3 -m zipfile -e $(BUILD_SOURCE)/$(FREEDOOM_ARCHIVE) . && \
			mv freedoom-$(FREEDOOM_VERSION) freedoom; } || exit 1; \
		cp $(BUILD_WORK)/freedoom/COPYING.txt $(BUILD_WORK)/freedoom/COPYING; \
		cat $(BUILD_WORK)/freedoom/CREDITS.txt $(BUILD_WORK)/freedoom/CREDITS-MUSIC.txt \
			> $(BUILD_WORK)/freedoom/AUTHORS; \
		touch "$(BUILD_WORK)/freedoom/.xios_setup_$(DEB_FREEDOOM_V)"; \
	fi

ifneq ($(wildcard $(BUILD_WORK)/freedoom/.build_complete),)
freedoom:
	@echo "Using previously staged Freedoom."
else
freedoom: freedoom-setup
	rm -rf $(BUILD_STAGE)/freedoom
	mkdir -p $(BUILD_STAGE)/freedoom/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/games/doom
	install -m 0644 \
		$(BUILD_WORK)/freedoom/freedoom1.wad \
		$(BUILD_WORK)/freedoom/freedoom2.wad \
		$(BUILD_STAGE)/freedoom/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/games/doom/
	$(call AFTER_BUILD)
endif

freedoom-package: freedoom-stage
	rm -rf $(BUILD_DIST)/freedoom
	mkdir -p $(BUILD_DIST)/freedoom$(MEMO_PREFIX)
	cp -a $(BUILD_STAGE)/freedoom$(MEMO_PREFIX)/. $(BUILD_DIST)/freedoom$(MEMO_PREFIX)/
	$(call PACK,freedoom,DEB_FREEDOOM_V)
	rm -rf $(BUILD_DIST)/freedoom

.PHONY: freedoom freedoom-package
