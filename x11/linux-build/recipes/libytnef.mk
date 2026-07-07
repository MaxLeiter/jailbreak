ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# libytnef.mk — TNEF/winmail.dat parser library used by Geary when TNEF support is on.
# GitHub tag tarballs do not ship a generated configure script, so autoreconf is part of
# the build like iso-codes.

SUBPROJECTS      += libytnef
LIBYTNEF_VERSION := 2.1.2
DEB_LIBYTNEF_V   ?= $(LIBYTNEF_VERSION)+ios1

libytnef-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://github.com/Yeraze/ytnef/archive/refs/tags/v$(LIBYTNEF_VERSION).tar.gz)
	$(call EXTRACT_TAR,v$(LIBYTNEF_VERSION).tar.gz,ytnef-$(LIBYTNEF_VERSION),libytnef)

ifneq ($(wildcard $(BUILD_WORK)/libytnef/.build_complete),)
libytnef:
	@echo "Using previously built libytnef."
else
libytnef: libytnef-setup
	cd $(BUILD_WORK)/libytnef && [ -f configure ] || autoreconf -fi
	cd $(BUILD_WORK)/libytnef && ./configure -C \
		$(DEFAULT_CONFIGURE_FLAGS) \
		--disable-static
	+$(MAKE) -C $(BUILD_WORK)/libytnef
	+$(MAKE) -C $(BUILD_WORK)/libytnef install DESTDIR=$(BUILD_STAGE)/libytnef
	$(call AFTER_BUILD,copy)
endif

libytnef-package: libytnef-stage
	rm -rf $(BUILD_DIST)/libytnef0 $(BUILD_DIST)/libytnef-dev
	mkdir -p $(BUILD_DIST)/libytnef0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libytnef-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	cp -a $(BUILD_STAGE)/libytnef/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libytnef.*.dylib \
		$(BUILD_DIST)/libytnef0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	cp -a $(BUILD_STAGE)/libytnef/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/!(libytnef.*.dylib) \
		$(BUILD_DIST)/libytnef-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/libytnef/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libytnef-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	$(call SIGN,libytnef0,general.xml)
	$(call PACK,libytnef0,DEB_LIBYTNEF_V)
	$(call PACK,libytnef-dev,DEB_LIBYTNEF_V)
	rm -rf $(BUILD_DIST)/libytnef0 $(BUILD_DIST)/libytnef-dev

.PHONY: libytnef libytnef-package
