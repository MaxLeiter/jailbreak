ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

STRAPPROJECTS  += nettle
# 3.9.1 -> 3.10.2, staying on 3.10: nettle 4.0 bumps the sonames (libnettle.9,
# libhogweed.7) and would force a rebuild of every consumer. The sonames stay
# libnettle.8 / libhogweed.6, but the real files move from .8.8/.6.8 to
# .8.11/.6.11, so the old fully-versioned names ship as compat symlinks: they are
# file paths Procursus's packages own, and the shadow gate's parity rule checks
# every one of them. Consumers link @rpath/libnettle.8.dylib, not those names.
NETTLE_VERSION := 3.10.2
DEB_NETTLE_V   ?= $(NETTLE_VERSION)+ios1

nettle-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://ftpmirror.gnu.org/nettle/nettle-$(NETTLE_VERSION).tar.gz{$(comma).sig})
	$(call PGP_VERIFY,nettle-$(NETTLE_VERSION).tar.gz)
	$(call EXTRACT_TAR,nettle-$(NETTLE_VERSION).tar.gz,nettle-$(NETTLE_VERSION),nettle)
	# ports/nettle/patches: restores the two libhogweed.6 exports 3.10 dropped.
	$(call DO_PATCH,nettle,nettle,-p1)

ifneq ($(wildcard $(BUILD_WORK)/nettle/.build_complete),)
nettle:
	@echo "Using previously built nettle."
else
nettle: nettle-setup libgmp10
	cd $(BUILD_WORK)/nettle && ./configure -C \
		$(DEFAULT_CONFIGURE_FLAGS) \
		CC_FOR_BUILD='$(shell command -v cc) $(CFLAGS_FOR_BUILD)' \
		CPP_FOR_BUILD='$(shell command -v cc) -E $(CPPFLAGS_FOR_BUILD)'
	+$(MAKE) -C $(BUILD_WORK)/nettle
	+$(MAKE) -C $(BUILD_WORK)/nettle install \
		DESTDIR=$(BUILD_STAGE)/nettle
	$(call AFTER_BUILD,copy)
endif

nettle-package: nettle-stage
	# nettle.mk Package Structure
	rm -rf $(BUILD_DIST)/nettle-bin \
		$(BUILD_DIST)/nettle-dev \
		$(BUILD_DIST)/libnettle8 \
		$(BUILD_DIST)/libhogweed6
	mkdir -p $(BUILD_DIST)/nettle-bin/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX) \
		$(BUILD_DIST)/nettle-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libnettle8/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libhogweed6/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# nettle.mk Prep nettle-bin
	cp -a $(BUILD_STAGE)/nettle/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin $(BUILD_DIST)/nettle-bin/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	# nettle.mk Prep libnettle8
	cp -a $(BUILD_STAGE)/nettle/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libnettle.8*.dylib $(BUILD_DIST)/libnettle8/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	[ -e $(BUILD_DIST)/libnettle8/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libnettle.8.8.dylib ] || \
		ln -s $$(readlink $(BUILD_DIST)/libnettle8/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libnettle.8.dylib) $(BUILD_DIST)/libnettle8/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libnettle.8.8.dylib

	# nettle.mk Prep libhogweed6
	cp -a $(BUILD_STAGE)/nettle/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libhogweed.6*.dylib $(BUILD_DIST)/libhogweed6/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	[ -e $(BUILD_DIST)/libhogweed6/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libhogweed.6.8.dylib ] || \
		ln -s $$(readlink $(BUILD_DIST)/libhogweed6/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libhogweed.6.dylib) $(BUILD_DIST)/libhogweed6/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libhogweed.6.8.dylib

	# nettle.mk Prep nettle-dev
	cp -a $(BUILD_STAGE)/nettle/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/{pkgconfig,lib{nettle,hogweed}.{dylib,a}} $(BUILD_DIST)/nettle-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/nettle/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/nettle-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	# nettle.mk Sign
	$(call SIGN,nettle-bin,general.xml)
	$(call SIGN,libnettle8,general.xml)
	$(call SIGN,libhogweed6,general.xml)

	# nettle.mk Make .debs
	$(call PACK,nettle-bin,DEB_NETTLE_V)
	$(call PACK,nettle-dev,DEB_NETTLE_V)
	$(call PACK,libnettle8,DEB_NETTLE_V)
	$(call PACK,libhogweed6,DEB_NETTLE_V)

	# nettle.mk Build cleanup
	rm -rf $(BUILD_DIST)/nettle-bin \
		$(BUILD_DIST)/nettle-dev \
		$(BUILD_DIST)/libnettle8 \
		$(BUILD_DIST)/libhogweed6

.PHONY: nettle nettle-package
