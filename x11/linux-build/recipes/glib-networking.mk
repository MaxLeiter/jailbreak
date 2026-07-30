ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# GIO TLS module used by libsoup/WebKitGTK. Keep this in our tree instead of
# relying on an optional external package so HTTPS is part of the tested browser
# runtime closure. The environment proxy backend avoids a libproxy dependency.

SUBPROJECTS              += glib-networking
GLIB_NETWORKING_MAJOR_V  := 2.80
GLIB_NETWORKING_VERSION  := $(GLIB_NETWORKING_MAJOR_V).0
DEB_GLIB_NETWORKING_V    ?= $(GLIB_NETWORKING_VERSION)+ios1

glib-networking-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/glib-networking/$(GLIB_NETWORKING_MAJOR_V)/glib-networking-$(GLIB_NETWORKING_VERSION).tar.xz)
	$(call EXTRACT_TAR,glib-networking-$(GLIB_NETWORKING_VERSION).tar.xz,glib-networking-$(GLIB_NETWORKING_VERSION),glib-networking)
	rm -rf $(BUILD_WORK)/glib-networking/build
	mkdir -p $(BUILD_WORK)/glib-networking/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/glib-networking/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/glib-networking/.build_complete),)
glib-networking:
	@echo "Using previously built glib-networking."
else
glib-networking: glib-networking-setup glib2.0 gnutls
	cd $(BUILD_WORK)/glib-networking/build && meson \
		--cross-file cross.txt \
		--buildtype=release \
		-Dgnutls=enabled \
		-Dopenssl=disabled \
		-Denvironment_proxy=enabled \
		-Dlibproxy=disabled \
		-Dgnome_proxy=disabled \
		-Dinstalled_tests=false \
		-Ddebug_logs=false \
		..
	+ninja -C $(BUILD_WORK)/glib-networking/build
	+DESTDIR="$(BUILD_STAGE)/glib-networking" ninja -C $(BUILD_WORK)/glib-networking/build install
	$(call AFTER_BUILD,copy)
endif

glib-networking-package: glib-networking-stage
	rm -rf $(BUILD_DIST)/glib-networking
	mkdir -p $(BUILD_DIST)/glib-networking/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/glib-networking/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/. \
		$(BUILD_DIST)/glib-networking/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/
	rm -rf $(BUILD_DIST)/glib-networking/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/installed-tests

	$(call SIGN,glib-networking,general.xml)
	$(call PACK,glib-networking,DEB_GLIB_NETWORKING_V)
	rm -rf $(BUILD_DIST)/glib-networking

.PHONY: glib-networking glib-networking-package
