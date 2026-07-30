ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# nwg-look.mk - GTK settings editor for wlroots desktops.
#
# The driver pins a native Linux/arm64 Go 1.25 toolchain. Go's ios/arm64 target
# can emit a PIE executable when cgo is routed through the Procursus compiler;
# gotk3 then resolves the already-staged target GTK3 stack through the cross
# pkg-config wrapper. xcur2png is intentionally optional upstream: nwg-look
# omits cursor preview thumbnails when the helper is unavailable.

SUBPROJECTS        += nwg-look
NWG-LOOK_VERSION   := 1.1.1
DEB_NWG-LOOK_V     ?= $(NWG-LOOK_VERSION)+ios1

nwg-look-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://github.com/nwg-piotr/nwg-look/archive/refs/tags/v$(NWG-LOOK_VERSION).tar.gz)
	$(call EXTRACT_TAR,v$(NWG-LOOK_VERSION).tar.gz,nwg-look-$(NWG-LOOK_VERSION),nwg-look)
	$(call DO_PATCH,nwg-look,nwg-look,-p1)
	mkdir -p $(BUILD_WORK)/nwg-look/bin

ifneq ($(wildcard $(BUILD_WORK)/nwg-look/.build_complete),)
nwg-look:
	@echo "Using previously built nwg-look."
else
nwg-look: nwg-look-setup gtk+3.0
	cd $(BUILD_WORK)/nwg-look && \
		PKG_CONFIG="$(BUILD_TOOLS)/cross-pkg-config" \
		CGO_ENABLED=1 GOOS=ios GOARCH=arm64 \
		CC="$(CC)" CXX="$(CXX)" \
		go build -trimpath -buildvcs=false -o bin/nwg-look .
	DESTDIR="$(BUILD_STAGE)/nwg-look" \
		$(MAKE) -C $(BUILD_WORK)/nwg-look \
		PREFIX="$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)" install
	$(call AFTER_BUILD,copy)
endif

nwg-look-package: nwg-look-stage
	rm -rf $(BUILD_DIST)/nwg-look
	mkdir -p $(BUILD_DIST)/nwg-look/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/nwg-look/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/. \
		$(BUILD_DIST)/nwg-look/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/
	$(call SIGN,nwg-look,iosc-gpu-client-ent.xml,,,nogeneral)
	$(call PACK,nwg-look,DEB_NWG-LOOK_V)
	rm -rf $(BUILD_DIST)/nwg-look

.PHONY: nwg-look nwg-look-package
