ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# Binary is `kgx`. Installs a GSettings schema -- needs glib-compile-schemas in postinst.

SUBPROJECTS            += gnome-console
GNOME-CONSOLE_MAJOR_V  := 46
GNOME-CONSOLE_VERSION  := $(GNOME-CONSOLE_MAJOR_V).0
DEB_GNOME-CONSOLE_V    ?= $(GNOME-CONSOLE_VERSION)+ios1

gnome-console-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/gnome-console/$(GNOME-CONSOLE_MAJOR_V)/gnome-console-$(GNOME-CONSOLE_VERSION).tar.xz)
	$(call EXTRACT_TAR,gnome-console-$(GNOME-CONSOLE_VERSION).tar.xz,gnome-console-$(GNOME-CONSOLE_VERSION),gnome-console)
	mkdir -p $(BUILD_WORK)/gnome-console/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/gnome-console/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/gnome-console/.build_complete),)
gnome-console:
	@echo "Using previously built gnome-console."
else
gnome-console: gnome-console-setup gtk4 libadwaita vte pcre2 libgtop gsettings-desktop-schemas
	cd $(BUILD_WORK)/gnome-console/build && meson \
		--cross-file cross.txt \
		..
	+ninja -C $(BUILD_WORK)/gnome-console/build
	+DESTDIR="$(BUILD_STAGE)/gnome-console" ninja -C $(BUILD_WORK)/gnome-console/build install
	$(call AFTER_BUILD,copy)
endif

gnome-console-package: gnome-console-stage
	rm -rf $(BUILD_DIST)/gnome-console
	mkdir -p $(BUILD_DIST)/gnome-console/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	# app: bin/kgx + share (desktop, icons, gschemas, gresource)
	cp -a $(BUILD_STAGE)/gnome-console/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin $(BUILD_DIST)/gnome-console/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/gnome-console/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share $(BUILD_DIST)/gnome-console/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	$(call SIGN,gnome-console,iosc-gpu-client-ent.xml,,,nogeneral)
	$(call PACK,gnome-console,DEB_GNOME-CONSOLE_V)
	rm -rf $(BUILD_DIST)/gnome-console

.PHONY: gnome-console gnome-console-package
