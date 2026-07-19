ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# dconf.mk — the GSettings dconf backend (libdconfsettings.so GIO module + dconf-service +
# dconf CLI + libdconf). Without it GSettings falls back to the non-persistent "memory"
# backend, so this is what makes desktop settings actually persist. C + glib only (talks
# GDBus, NOT libdbus), so it compiles against glib alone; it needs the dbus SESSION bus at
# RUNTIME (provided by the `dbus` package from the XFCE track). GTK-independent.
# See docs/gnome-plan.md, Stage A.
#
# BUILT/PUBLISHED — `dconf 0.40.0+ios1` is in the package repo. A fresh
# 2026-07-18 cross probe also configured cleanly and entered compilation before
# Docker became unresponsive; use the published artifact as current package truth.
# Simplified single runtime package; Debian splits into dconf-gsettings-backend /
# dconf-service / dconf-cli / libdconf1 — split later if a finer dependency graph is wanted.

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
	# dconf.mk Package Structure
	rm -rf $(BUILD_DIST)/dconf $(BUILD_DIST)/dconf-dev
	mkdir -p $(BUILD_DIST)/dconf/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/dconf-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# dconf.mk Prep dconf (runtime: lib, GIO backend module, dconf-service, dconf CLI, dbus svc)
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

	# dconf.mk Prep dconf-dev (unversioned symlink, headers, .pc)
	cp -a $(BUILD_STAGE)/dconf/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/!(libdconf.1.dylib|gio) $(BUILD_DIST)/dconf-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/dconf/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/dconf-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	# dconf.mk Sign
	$(call SIGN,dconf,general.xml)

	# dconf.mk Make .debs
	$(call PACK,dconf,DEB_DCONF_V)
	$(call PACK,dconf-dev,DEB_DCONF_V)

	# dconf.mk Build cleanup
	rm -rf $(BUILD_DIST)/dconf $(BUILD_DIST)/dconf-dev

.PHONY: dconf dconf-package
