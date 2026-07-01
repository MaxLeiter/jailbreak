ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# libsecret.mk — the Secret Service client library. gnome-shell itself only needs it when
# NetworkManager is on (off here), but gcr/gnome-keyring want it later and it is a cheap
# leaf (glib + libgcrypt, both already in build_base). Mirrors recipes/gnome-desktop.mk.

SUBPROJECTS       += libsecret
LIBSECRET_MAJOR_V := 0.21
LIBSECRET_VERSION := $(LIBSECRET_MAJOR_V).4
DEB_LIBSECRET_V   ?= $(LIBSECRET_VERSION)

libsecret-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/libsecret/$(LIBSECRET_MAJOR_V)/libsecret-$(LIBSECRET_VERSION).tar.xz)
	$(call EXTRACT_TAR,libsecret-$(LIBSECRET_VERSION).tar.xz,libsecret-$(LIBSECRET_VERSION),libsecret)
	mkdir -p $(BUILD_WORK)/libsecret/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/libsecret/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/libsecret/.build_complete),)
libsecret:
	@echo "Using previously built libsecret."
else
libsecret: libsecret-setup glib2.0
	cd $(BUILD_WORK)/libsecret/build && meson \
		--cross-file cross.txt \
		-Dintrospection=false \
		-Dvapi=false \
		-Dgtk_doc=false \
		-Dmanpage=false \
		-Dcrypto=libgcrypt \
		-Dbash_completion=disabled \
		-Dpam=false \
		-Dtpm2=false \
		..
	+ninja -C $(BUILD_WORK)/libsecret/build
	+DESTDIR="$(BUILD_STAGE)/libsecret" ninja -C $(BUILD_WORK)/libsecret/build install
	$(call AFTER_BUILD,copy)
endif

libsecret-package: libsecret-stage
	rm -rf $(BUILD_DIST)/libsecret-1-0 $(BUILD_DIST)/libsecret-dev
	mkdir -p $(BUILD_DIST)/libsecret-1-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libsecret-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# libsecret-1-0 — runtime dylib + the secret-tool CLI
	cp -a $(BUILD_STAGE)/libsecret/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libsecret-1.*.dylib \
		$(BUILD_DIST)/libsecret-1-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	if [ -d "$(BUILD_STAGE)/libsecret/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin" ]; then \
		cp -a $(BUILD_STAGE)/libsecret/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin $(BUILD_DIST)/libsecret-1-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
	fi

	# libsecret-dev — headers + .pc + unversioned symlink
	cp -a $(BUILD_STAGE)/libsecret/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/libsecret-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/libsecret/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig $(BUILD_DIST)/libsecret-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/libsecret/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libsecret-1.dylib \
		$(BUILD_DIST)/libsecret-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	$(call SIGN,libsecret-1-0,general.xml)
	$(call PACK,libsecret-1-0,DEB_LIBSECRET_V)
	$(call PACK,libsecret-dev,DEB_LIBSECRET_V)
	rm -rf $(BUILD_DIST)/libsecret-1-0 $(BUILD_DIST)/libsecret-dev

.PHONY: libsecret libsecret-package
