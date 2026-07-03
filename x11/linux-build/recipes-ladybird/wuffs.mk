ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# wuffs.mk — NEW recipe for the Ladybird leaf closure (pin wuffs 0.3.4). Header-only image
# codecs: the whole library is the single-file amalgamation release/c/wuffs-v0.3.c, which acts
# as a header unless WUFFS_IMPLEMENTATION is defined in exactly one TU (Ladybird does that).
# No compile step; we just drop the amalgamation into the prefix include dir. +ios1 marker.

SUBPROJECTS     += wuffs
WUFFS_VERSION   := 0.3.4
DEB_WUFFS_V     ?= $(WUFFS_VERSION)+ios1

wuffs-setup: setup
	$(call GITHUB_ARCHIVE,google,wuffs,$(WUFFS_VERSION),v$(WUFFS_VERSION))
	$(call EXTRACT_TAR,wuffs-$(WUFFS_VERSION).tar.gz,wuffs-$(WUFFS_VERSION),wuffs)

ifneq ($(wildcard $(BUILD_WORK)/wuffs/.build_complete),)
wuffs:
	@echo "Using previously built wuffs."
else
wuffs: wuffs-setup
	mkdir -p $(BUILD_STAGE)/wuffs/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include
	cp -a $(BUILD_WORK)/wuffs/release/c/wuffs-v0.3.c $(BUILD_STAGE)/wuffs/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/wuffs-v0.3.c
	$(call AFTER_BUILD,copy)
endif

wuffs-package: wuffs-stage
	# wuffs.mk Package Structure (header drop only)
	rm -rf $(BUILD_DIST)/wuffs-dev
	mkdir -p $(BUILD_DIST)/wuffs-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include

	# wuffs.mk Prep wuffs-dev
	cp -a $(BUILD_STAGE)/wuffs/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/wuffs-v0.3.c $(BUILD_DIST)/wuffs-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include

	# wuffs.mk Make .deb (no binaries -> no SIGN)
	$(call PACK,wuffs-dev,DEB_WUFFS_V)

	# wuffs.mk Build cleanup
	rm -rf $(BUILD_DIST)/wuffs-dev

.PHONY: wuffs wuffs-package
