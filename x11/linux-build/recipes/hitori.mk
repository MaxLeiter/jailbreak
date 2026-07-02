ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# hitori.mk — Hitori, a GNOME logic puzzle (cross out cells so no number repeats in a row/column).
# The one genuinely cheap "real game" win: pure C, and its ONLY deps are glib/gio/gmodule/cairo +
# gtk+-3.0 (>=3.22) — all already in our tree (the GTK3 stack) — so it adds ZERO new sub-deps.
# It is GTK3 (never ported to GTK4; upstream's GTK4 games all pull librsvg, which is Rust). GTK3
# renders software under Xios, same as hello-gtk(3). 44.0 is the latest release.
#
# DEPENDS (target): gtk+3.0 (+ glib/cairo, prebuilt). Ships a GSettings schema (org.gnome.hitori)
# -> glib-compile-schemas needed on install, like the other GNOME apps.

SUBPROJECTS    += hitori
HITORI_MAJOR_V := 44
HITORI_VERSION := $(HITORI_MAJOR_V).0
DEB_HITORI_V   ?= $(HITORI_VERSION)

hitori-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/hitori/$(HITORI_MAJOR_V)/hitori-$(HITORI_VERSION).tar.xz)
	$(call EXTRACT_TAR,hitori-$(HITORI_VERSION).tar.xz,hitori-$(HITORI_VERSION),hitori)
	mkdir -p $(BUILD_WORK)/hitori/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/hitori/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/hitori/.build_complete),)
hitori:
	@echo "Using previously built hitori."
else
hitori: hitori-setup gtk+3.0
	cd $(BUILD_WORK)/hitori/build && meson \
		--cross-file cross.txt \
		..
	+ninja -C $(BUILD_WORK)/hitori/build
	+DESTDIR="$(BUILD_STAGE)/hitori" ninja -C $(BUILD_WORK)/hitori/build install
	$(call AFTER_BUILD,copy)
endif

hitori-package: hitori-stage
	rm -rf $(BUILD_DIST)/hitori
	mkdir -p $(BUILD_DIST)/hitori/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	# app: bin/hitori + share (desktop, icons, gschemas, help)
	cp -a $(BUILD_STAGE)/hitori/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin $(BUILD_DIST)/hitori/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/hitori/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share $(BUILD_DIST)/hitori/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	$(call SIGN,hitori,iosc-gpu-client-ent.xml,,,nogeneral)
	$(call PACK,hitori,DEB_HITORI_V)
	rm -rf $(BUILD_DIST)/hitori

.PHONY: hitori hitori-package
