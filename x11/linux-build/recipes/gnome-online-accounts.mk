ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# Geary consumes the goa-1.0 client API. The provider/backend library embeds a
# browser and platform account integrations, so the first iOS build ships the
# D-Bus client library and daemon-facing data only. Manual Geary accounts remain
# available while OAuth provider UI stays a separate follow-up.

SUBPROJECTS += gnome-online-accounts
GNOME_ONLINE_ACCOUNTS_VERSION := 3.46.0
DEB_GNOME_ONLINE_ACCOUNTS_V   ?= $(GNOME_ONLINE_ACCOUNTS_VERSION)+ios1

gnome-online-accounts-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/gnome-online-accounts/3.46/gnome-online-accounts-$(GNOME_ONLINE_ACCOUNTS_VERSION).tar.xz)
	$(call EXTRACT_TAR,gnome-online-accounts-$(GNOME_ONLINE_ACCOUNTS_VERSION).tar.xz,gnome-online-accounts-$(GNOME_ONLINE_ACCOUNTS_VERSION),gnome-online-accounts)
	rm -rf $(BUILD_WORK)/gnome-online-accounts/build && mkdir -p $(BUILD_WORK)/gnome-online-accounts/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/gnome-online-accounts/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/gnome-online-accounts/.build_complete),)
gnome-online-accounts:
	@echo "Using previously built GNOME Online Accounts."
else
gnome-online-accounts: gnome-online-accounts-setup glib2.0 dbus
	cd $(BUILD_WORK)/gnome-online-accounts/build && meson \
		--cross-file cross.txt \
		--buildtype=release \
		-Dgoabackend=false \
		-Dintrospection=false \
		-Dvapi=false \
		-Dgtk_doc=false \
		-Dman=false \
		-Dlibrest:introspection=false \
		-Dlibrest:examples=false \
		-Dlibrest:gtk_doc=false \
		-Dlibrest:tests=false \
		..
	+ninja -C $(BUILD_WORK)/gnome-online-accounts/build
	+DESTDIR="$(BUILD_STAGE)/gnome-online-accounts" ninja -C $(BUILD_WORK)/gnome-online-accounts/build install
	$(call AFTER_BUILD,copy)
endif

gnome-online-accounts-package: gnome-online-accounts-stage
	rm -rf $(BUILD_DIST)/libgoa-1.0-0b $(BUILD_DIST)/libgoa-1.0-dev
	mkdir -p \
		$(BUILD_DIST)/libgoa-1.0-0b/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libgoa-1.0-0b/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share \
		$(BUILD_DIST)/libgoa-1.0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig
	cp -a $(BUILD_STAGE)/gnome-online-accounts/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libgoa-1.0.0.dylib \
		$(BUILD_DIST)/libgoa-1.0-0b/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/
	cp -a $(BUILD_STAGE)/gnome-online-accounts/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/locale \
		$(BUILD_DIST)/libgoa-1.0-0b/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/
	cp -a $(BUILD_STAGE)/gnome-online-accounts/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libgoa-1.0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/
	mkdir -p $(BUILD_DIST)/libgoa-1.0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/goa-1.0
	cp -a $(BUILD_STAGE)/gnome-online-accounts/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/goa-1.0/include \
		$(BUILD_DIST)/libgoa-1.0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/goa-1.0/
	cp -a $(BUILD_STAGE)/gnome-online-accounts/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig/goa-1.0.pc \
		$(BUILD_DIST)/libgoa-1.0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig/
	cp -a $(BUILD_STAGE)/gnome-online-accounts/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libgoa-1.0.dylib \
		$(BUILD_DIST)/libgoa-1.0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/
	$(call SIGN,libgoa-1.0-0b)
	$(call PACK,libgoa-1.0-0b,DEB_GNOME_ONLINE_ACCOUNTS_V)
	$(call PACK,libgoa-1.0-dev,DEB_GNOME_ONLINE_ACCOUNTS_V)
	rm -rf $(BUILD_DIST)/libgoa-1.0-0b $(BUILD_DIST)/libgoa-1.0-dev

.PHONY: gnome-online-accounts gnome-online-accounts-package
