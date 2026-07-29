ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# Without this, GSettings falls back to the non-persistent "memory" backend. Talks GDBus only
# (no libdbus link); needs a dbus session bus at runtime. Single runtime package here instead
# of Debian's dconf-gsettings-backend/dconf-service/dconf-cli/libdconf1 split — nothing else
# consumes the finer split.

SUBPROJECTS   += dconf
DCONF_VERSION := 0.40.0
DEB_DCONF_V   ?= $(DCONF_VERSION)+ios1

dconf-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/dconf/$(shell echo $(DCONF_VERSION) | cut -f-2 -d.)/dconf-$(DCONF_VERSION).tar.xz)
	$(call EXTRACT_TAR,dconf-$(DCONF_VERSION).tar.xz,dconf-$(DCONF_VERSION),dconf)
	mkdir -p $(BUILD_WORK)/dconf/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/dconf/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/dconf/.build_complete),)
dconf:
	@echo "Using previously built dconf."
else
dconf: dconf-setup glib2.0
	cd $(BUILD_WORK)/dconf/build && meson \
		--cross-file cross.txt \
		-Dbash_completion=false \
		-Dman=false \
		-Dvapi=false \
		-Dgtk_doc=false \
		..
	+ninja -C $(BUILD_WORK)/dconf/build
	+DESTDIR="$(BUILD_STAGE)/dconf" ninja -C $(BUILD_WORK)/dconf/build install
	$(call AFTER_BUILD,copy)
endif

dconf-package: dconf-stage
	rm -rf $(BUILD_DIST)/dconf $(BUILD_DIST)/dconf-dev
	mkdir -p $(BUILD_DIST)/dconf/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/dconf-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	cp -a $(BUILD_STAGE)/dconf/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libdconf.1.dylib $(BUILD_DIST)/dconf/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/dconf/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/gio $(BUILD_DIST)/dconf/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	if [ -d "$(BUILD_STAGE)/dconf/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin" ]; then \
		cp -a $(BUILD_STAGE)/dconf/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin $(BUILD_DIST)/dconf/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
	fi
	if [ -d "$(BUILD_STAGE)/dconf/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec" ]; then \
		cp -a $(BUILD_STAGE)/dconf/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec $(BUILD_DIST)/dconf/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
	fi
	if [ -d "$(BUILD_STAGE)/dconf/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/dbus-1" ]; then \
		mkdir -p $(BUILD_DIST)/dconf/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share; \
		cp -a $(BUILD_STAGE)/dconf/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/dbus-1 $(BUILD_DIST)/dconf/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share; \
	fi

	cp -a $(BUILD_STAGE)/dconf/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/!(libdconf.1.dylib|gio) $(BUILD_DIST)/dconf-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/dconf/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/dconf-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	$(call SIGN,dconf,general.xml)

	$(call PACK,dconf,DEB_DCONF_V)
	$(call PACK,dconf-dev,DEB_DCONF_V)

	rm -rf $(BUILD_DIST)/dconf $(BUILD_DIST)/dconf-dev

.PHONY: dconf dconf-package
