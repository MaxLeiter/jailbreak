ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# LuaJIT 2.1 rolling release for rootless iOS. Upstream has an explicit
# TARGET_SYS=iOS path; the only Darwin cross-build adjustment here is disabling
# the upstream strip step, which fails on ld64 dylibs with indirect symbols.

SUBPROJECTS       += luajit
LUAJIT_COMMIT     := a2bde60819d83e6f75130ac2c93ee4b3c7615800
LUAJIT_RELVER     := 1782726002
LUAJIT_VERSION    := 2.1.$(LUAJIT_RELVER)
DEB_LUAJIT_V      ?= $(LUAJIT_VERSION)+ios1

LUAJIT_MAKE_ARGS = \
	HOST_CC=cc \
	CC="$(CC)" \
	CFLAGS= \
	LDFLAGS= \
	TARGET_SYS=iOS \
	TARGET_FLAGS="$(CFLAGS)" \
	TARGET_LDFLAGS="$(LDFLAGS)" \
	TARGET_SHLDFLAGS="$(LDFLAGS)" \
	TARGET_AR="$(AR) rcus" \
	TARGET_STRIP=true \
	PREFIX=$(MEMO_PREFIX)$(MEMO_SUB_PREFIX) \
	MULTILIB=lib \
	BUILDMODE=dynamic

luajit-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://github.com/LuaJIT/LuaJIT/archive/$(LUAJIT_COMMIT).tar.gz)
	$(call EXTRACT_TAR,$(LUAJIT_COMMIT).tar.gz,LuaJIT-$(LUAJIT_COMMIT),luajit)

ifneq ($(wildcard $(BUILD_WORK)/luajit/.build_complete),)
luajit:
	@echo "Using previously built luajit."
else
luajit: luajit-setup
	+$(MAKE) -C $(BUILD_WORK)/luajit $(LUAJIT_MAKE_ARGS)
	+$(MAKE) -C $(BUILD_WORK)/luajit install DESTDIR=$(BUILD_STAGE)/luajit $(LUAJIT_MAKE_ARGS)
	$(call AFTER_BUILD,copy)
endif

luajit-package: luajit-stage
	rm -rf $(BUILD_DIST)/luajit $(BUILD_DIST)/luajit-dev
	mkdir -p $(BUILD_DIST)/luajit/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/luajit-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	cp -a $(BUILD_STAGE)/luajit/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin \
		$(BUILD_DIST)/luajit/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/luajit/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share \
		$(BUILD_DIST)/luajit/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/luajit/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libluajit-5.1.*.dylib \
		$(BUILD_DIST)/luajit/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	cp -a $(BUILD_STAGE)/luajit/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/luajit-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/luajit/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig \
		$(BUILD_DIST)/luajit-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/luajit/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libluajit-5.1.dylib \
		$(BUILD_DIST)/luajit-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	$(call SIGN,luajit,general.xml)
	$(call PACK,luajit,DEB_LUAJIT_V)
	$(call PACK,luajit-dev,DEB_LUAJIT_V)
	rm -rf $(BUILD_DIST)/luajit $(BUILD_DIST)/luajit-dev

.PHONY: luajit luajit-package
