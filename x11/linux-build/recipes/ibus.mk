ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# ibus.mk — the input-method bus. gnome-shell links libibus-1.0 unconditionally (its
# keyboard/IM plumbing); the daemon comes along for later CJK input. Everything UI-ish is
# OFF: no GTK panels/IM modules, no XIM server, no Wayland frontend, no engines, no
# emoji/unicode dictionaries (those want UCD/CLDR data), no dconf, no python. libibus is
# pure GLib/GDBus. Classic autotools like recipes/startup-notification.mk.

SUBPROJECTS  += ibus
IBUS_VERSION := 1.5.29
DEB_IBUS_V   ?= $(IBUS_VERSION)

ibus-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://github.com/ibus/ibus/releases/download/$(IBUS_VERSION)/ibus-$(IBUS_VERSION).tar.gz)
	$(call EXTRACT_TAR,ibus-$(IBUS_VERSION).tar.gz,ibus-$(IBUS_VERSION),ibus)
	# ibus's configure hard-AC_CHECK_FILEs the X11 Compose locale.dir, which aborts under
	# cross-compile ("cannot check for file existence when cross compiling"). The dir is
	# only used for XIM Compose (disabled); neuter the two cross guards so the check falls
	# through to the default X11_LOCALEDATADIR=$(datadir)/X11/locale.
	sed -i 's/.*cannot check for file existence when cross compiling.*/:/' $(BUILD_WORK)/ibus/configure

ifneq ($(wildcard $(BUILD_WORK)/ibus/.build_complete),)
ibus:
	@echo "Using previously built ibus."
else
ibus: ibus-setup glib2.0
	cd $(BUILD_WORK)/ibus && ./configure -C \
		$(DEFAULT_CONFIGURE_FLAGS) \
		--disable-static \
		--disable-ui \
		--disable-gtk2 \
		--disable-gtk3 \
		--disable-gtk4 \
		--disable-xim \
		--disable-wayland \
		--disable-dconf \
		--disable-memconf \
		--disable-setup \
		--disable-engine \
		--disable-python-library \
		--disable-dbus-python-check \
		--disable-emoji-dict \
		--disable-unicode-dict \
		--disable-appindicator \
		--disable-libnotify \
		--disable-introspection \
		--disable-vala \
		--disable-tests \
		--disable-install-tests \
		--disable-systemd-services \
		--disable-schemas-compile \
		--disable-gtk-doc
	# gen-internal-compose-table is a BUILD-host tool (it runs during the build to emit the
	# compose/sequences-*-endian data bundled into libibus). ibus's CROSS_COMPILING makefile
	# tries to compile it with CC_FOR_BUILD but its target-specific CFLAGS override doesn't
	# reach the per-object rule, so it inherits the global cross -arch arm64 and emits a
	# Mach-O the host linker rejects. Fully generate the sequences data here with the host
	# toolchain forced on the make command line (command-line assignments beat target-specific
	# vars). rm the stale cross objects first (the build dir is not re-extracted between
	# retries). After this the sequences are newest, so the main cross build never re-touches
	# the tool — it just consumes the data into libibus's gresource.
	rm -f $(BUILD_WORK)/ibus/src/gen_internal_compose_table-*.o \
		$(BUILD_WORK)/ibus/src/gen-internal-compose-table
	+$(MAKE) -C $(BUILD_WORK)/ibus/src CC="/usr/bin/cc" CCLD="/usr/bin/cc" \
		CFLAGS="-g -O2" CPPFLAGS="" GLIB_COMPILE_RESOURCES=/usr/bin/glib-compile-resources \
		compose/sequences-little-endian
	# configure resolves GLIB_COMPILE_RESOURCES to the cross-sysroot iOS binary (a Mach-O that
	# can't run on the Linux builder -> Error 126 building ibusresources.c). Point it at the
	# host tool (libglib2.0-dev-bin). glib-mkenums/genmarshal are scripts and run either way.
	+$(MAKE) -C $(BUILD_WORK)/ibus GLIB_COMPILE_RESOURCES=/usr/bin/glib-compile-resources
	+$(MAKE) -C $(BUILD_WORK)/ibus install DESTDIR=$(BUILD_STAGE)/ibus \
		GLIB_COMPILE_RESOURCES=/usr/bin/glib-compile-resources
	$(call AFTER_BUILD,copy)
endif

ibus-package: ibus-stage
	rm -rf $(BUILD_DIST)/libibus-1.0-5 $(BUILD_DIST)/ibus $(BUILD_DIST)/libibus-dev
	mkdir -p $(BUILD_DIST)/libibus-1.0-5/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/ibus/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX) \
		$(BUILD_DIST)/libibus-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# libibus-1.0-5 — the client library gnome-shell links
	cp -a $(BUILD_STAGE)/ibus/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libibus-1.0.*.dylib \
		$(BUILD_DIST)/libibus-1.0-5/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# ibus — daemon + CLI + component/keymap data + D-Bus services + GSettings schema
	if [ -d "$(BUILD_STAGE)/ibus/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin" ]; then \
		cp -a $(BUILD_STAGE)/ibus/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin $(BUILD_DIST)/ibus/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
	fi
	if [ -d "$(BUILD_STAGE)/ibus/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec" ]; then \
		cp -a $(BUILD_STAGE)/ibus/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec $(BUILD_DIST)/ibus/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
	fi
	if [ -d "$(BUILD_STAGE)/ibus/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share" ]; then \
		cp -a $(BUILD_STAGE)/ibus/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share $(BUILD_DIST)/ibus/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
	fi
	if [ -d "$(BUILD_STAGE)/ibus/$(MEMO_PREFIX)/etc" ]; then \
		cp -a $(BUILD_STAGE)/ibus/$(MEMO_PREFIX)/etc $(BUILD_DIST)/ibus/$(MEMO_PREFIX); \
	fi
	rm -rf $(BUILD_DIST)/ibus/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/doc \
		$(BUILD_DIST)/ibus/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/gtk-doc \
		$(BUILD_DIST)/ibus/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/man

	# libibus-dev — headers + .pc + unversioned symlink
	cp -a $(BUILD_STAGE)/ibus/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/libibus-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/ibus/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig $(BUILD_DIST)/libibus-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/ibus/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libibus-1.0.dylib \
		$(BUILD_DIST)/libibus-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	$(call SIGN,libibus-1.0-5,general.xml)
	$(call SIGN,ibus,general.xml)
	$(call PACK,libibus-1.0-5,DEB_IBUS_V)
	$(call PACK,ibus,DEB_IBUS_V)
	$(call PACK,libibus-dev,DEB_IBUS_V)
	rm -rf $(BUILD_DIST)/libibus-1.0-5 $(BUILD_DIST)/ibus $(BUILD_DIST)/libibus-dev

.PHONY: ibus ibus-package
