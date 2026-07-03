ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# xorgproto — bumped to 2024.1 (stock Procursus ships 2021.5). Xwayland 23.2.7's
# present.c uses PresentAllAsyncOptions / PresentOptionAsyncMayTear (presentproto
# 1.3, the async-may-tear/tearing addition), which 2021.5's presenttokens.h lacks.
# 2024.1 ships presentproto 1.4 (has them) and is contemporary with xwayland 23.2.
# Header-only; additive vs 2021.5, and this is an ISOLATED build volume, so the
# bump can't affect the other flavor volumes. (Tarball is .tar.xz in 2024.x.)
#
# --enable-legacy is REQUIRED: 2024.x makes the per-proto .pc files (xproto.pc,
# kbproto.pc, presentproto.pc, fontsproto.pc, ...) legacy, default-OFF; xwayland's
# meson looks them up by those exact names (2021.5 installed them unconditionally).

SUBPROJECTS       += xorgproto
XORGPROTO_VERSION := 2024.1
DEB_XORGPROTO_V   ?= $(XORGPROTO_VERSION)+ios1

xorgproto-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://xorg.freedesktop.org/archive/individual/proto/xorgproto-$(XORGPROTO_VERSION).tar.xz)
	$(call EXTRACT_TAR,xorgproto-$(XORGPROTO_VERSION).tar.xz,xorgproto-$(XORGPROTO_VERSION),xorgproto)

ifneq ($(wildcard $(BUILD_WORK)/xorgproto/.build_complete),)
xorgproto:
	@echo "Using previously built xorgproto."
else
xorgproto: xorgproto-setup
	cd $(BUILD_WORK)/xorgproto && ./configure -C \
		$(DEFAULT_CONFIGURE_FLAGS) \
		--enable-legacy
	+$(MAKE) -C $(BUILD_WORK)/xorgproto install \
		DESTDIR="$(BUILD_STAGE)/xorgproto"
	$(call AFTER_BUILD,copy)
endif

xorgproto-package: xorgproto-stage
	rm -rf $(BUILD_DIST)/x11proto-dev
	cp -a $(BUILD_STAGE)/xorgproto $(BUILD_DIST)/x11proto-dev
	$(call PACK,x11proto-dev,DEB_XORGPROTO_V)
	rm -rf $(BUILD_DIST)/x11proto-dev

.PHONY: xorgproto xorgproto-package
