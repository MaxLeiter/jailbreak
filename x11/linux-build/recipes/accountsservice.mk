ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# Client library only: accounts-daemon is Linux-only (utmp/crypt/shadow) and dropped; its
# sd-login use is satisfied by a single-session shim compiled in via ports/accountsservice/patches.
# gnome-shell hard-imports gi://AccountsService during boot (js/misc/systemActions.js), so the
# shell won't start without this lib + typelib. Introspection is off; the typelib is generated
# on-device.

SUBPROJECTS      += accountsservice
ACCOUNTSSERVICE_VERSION := 23.13.9
DEB_ACCOUNTSSERVICE_V   ?= $(ACCOUNTSSERVICE_VERSION)+ios1

accountsservice-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://www.freedesktop.org/software/accountsservice/accountsservice-$(ACCOUNTSSERVICE_VERSION).tar.xz)
	$(call EXTRACT_TAR,accountsservice-$(ACCOUNTSSERVICE_VERSION).tar.xz,accountsservice-$(ACCOUNTSSERVICE_VERSION),accountsservice)
	$(call DO_PATCH,accountsservice,accountsservice,-p1)
	rm -rf $(BUILD_WORK)/accountsservice/build && mkdir -p $(BUILD_WORK)/accountsservice/build
	echo -e "[host_machine]\n \
	system = 'darwin'\n \
	cpu_family = '$(shell echo $(GNU_HOST_TRIPLE) | cut -d- -f1)'\n \
	cpu = '$(MEMO_ARCH)'\n \
	endian = 'little'\n \
	[properties]\n \
	root = '$(BUILD_BASE)'\n \
	needs_exe_wrapper = true\n \
	[built-in options]\n \
	prefix ='$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)'\n \
	[binaries]\n \
	c = '$(CC)'\n \
	cpp = '$(CXX)'\n \
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/accountsservice/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/accountsservice/.build_complete),)
accountsservice:
	@echo "Using previously built accountsservice."
else
accountsservice: accountsservice-setup polkit
	cd $(BUILD_WORK)/accountsservice/build && meson \
		--cross-file cross.txt \
		-Dintrospection=false \
		-Dvapi=false \
		-Dsystemdsystemunitdir=no \
		-Ddocbook=false \
		-Dgtk_doc=false \
		..
	+ninja -C $(BUILD_WORK)/accountsservice/build
	+DESTDIR="$(BUILD_STAGE)/accountsservice" ninja -C $(BUILD_WORK)/accountsservice/build install
	$(call AFTER_BUILD,copy)
endif

accountsservice-package: accountsservice-stage
	rm -rf $(BUILD_DIST)/libaccountsservice0 $(BUILD_DIST)/libaccountsservice-dev
	mkdir -p $(BUILD_DIST)/libaccountsservice0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libaccountsservice-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# runtime: the versioned dylib + the D-Bus interface XML the lib reads at runtime
	cp -a $(BUILD_STAGE)/accountsservice/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libaccountsservice.*.dylib \
		$(BUILD_DIST)/libaccountsservice0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/ 2>/dev/null || \
	cp -a $(BUILD_STAGE)/accountsservice/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libaccountsservice.dylib \
		$(BUILD_DIST)/libaccountsservice0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/
	if [ -d "$(BUILD_STAGE)/accountsservice/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/accountsservice" ]; then \
		mkdir -p $(BUILD_DIST)/libaccountsservice0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share; \
		cp -a $(BUILD_STAGE)/accountsservice/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/accountsservice \
			$(BUILD_DIST)/libaccountsservice0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/; \
	fi

	# dev: headers, unversioned symlink, pkgconfig — needed by the ON-DEVICE gir/typelib build
	cp -a $(BUILD_STAGE)/accountsservice/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libaccountsservice-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/ 2>/dev/null || true
	cp -a $(BUILD_STAGE)/accountsservice/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig \
		$(BUILD_DIST)/libaccountsservice-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/ 2>/dev/null || true
	if [ -e "$(BUILD_STAGE)/accountsservice/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libaccountsservice.dylib" ]; then \
		cp -a $(BUILD_STAGE)/accountsservice/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libaccountsservice.dylib \
			$(BUILD_DIST)/libaccountsservice-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/ 2>/dev/null || true; \
	fi

	$(call SIGN,libaccountsservice0,general.xml)
	$(call PACK,libaccountsservice0,DEB_ACCOUNTSSERVICE_V)
	$(call PACK,libaccountsservice-dev,DEB_ACCOUNTSSERVICE_V)
	rm -rf $(BUILD_DIST)/libaccountsservice0 $(BUILD_DIST)/libaccountsservice-dev

.PHONY: accountsservice accountsservice-package
