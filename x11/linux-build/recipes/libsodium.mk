ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

SUBPROJECTS           += libsodium
LIBSODIUM_VERSION     := 1.0.18
DEB_LIBSODIUM_V       ?= $(LIBSODIUM_VERSION)+ios1
LIBSODIUM_ARCHIVE     := libsodium-$(LIBSODIUM_VERSION).tar.gz

libsodium-setup: setup
	@if [ -f "$(BUILD_SOURCE)/$(LIBSODIUM_ARCHIVE)" ] && \
		! tar -tzf "$(BUILD_SOURCE)/$(LIBSODIUM_ARCHIVE)" >/dev/null 2>&1; then \
		echo "Removing invalid cached $(LIBSODIUM_ARCHIVE)"; \
		rm -f "$(BUILD_SOURCE)/$(LIBSODIUM_ARCHIVE)"; \
	fi
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://github.com/jedisct1/libsodium/releases/download/$(LIBSODIUM_VERSION)-RELEASE/$(LIBSODIUM_ARCHIVE))
	$(call EXTRACT_TAR,$(LIBSODIUM_ARCHIVE),libsodium-$(LIBSODIUM_VERSION),libsodium)

ifneq ($(wildcard $(BUILD_WORK)/libsodium/.build_complete),)
libsodium:
	@echo "Using previously built libsodium."
else
libsodium: libsodium-setup
	cd $(BUILD_WORK)/libsodium && ./configure -C \
		$(DEFAULT_CONFIGURE_FLAGS)
	+$(MAKE) -C $(BUILD_WORK)/libsodium
	+$(MAKE) -C $(BUILD_WORK)/libsodium install \
		DESTDIR=$(BUILD_STAGE)/libsodium
	$(call AFTER_BUILD,copy)
endif

libsodium-package: libsodium-stage
	rm -rf $(BUILD_DIST)/libsodium{23,-dev}
	mkdir -p $(BUILD_DIST)/libsodium{23,-dev}/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	cp -a $(BUILD_STAGE)/libsodium/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libsodium.23.dylib $(BUILD_DIST)/libsodium23/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	cp -a $(BUILD_STAGE)/libsodium/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/libsodium-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/libsodium/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/!(libsodium.23.dylib) $(BUILD_DIST)/libsodium-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	$(call SIGN,libsodium23,general.xml)

	$(call PACK,libsodium23,DEB_LIBSODIUM_V)
	$(call PACK,libsodium-dev,DEB_LIBSODIUM_V)

	rm -rf $(BUILD_DIST)/libsodium{23,-dev}

.PHONY: libsodium libsodium-package
