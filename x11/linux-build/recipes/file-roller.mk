ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# file-roller.mk — File Roller, GNOME's archive manager. As of 44.x it is a clean C **GTK4**
# /libadwaita app (the GTK3 days are over). The archive engine is libarchive; Procursus ships a
# native libarchive recipe (3.7.2 -> libarchive13), built from lz4/lzo2/zstd/xz/nettle which we
# already have — so the only "new" sub-dep is that one stock lib.
#
# Optional-feature trims (verified against file-roller 44.7 meson_options.txt) to keep the dep
# tree minimal and iOS-clean:
#   -Dpackagekit=false       -> no PackageKit "install missing utility" path (no PK on iOS)
#   -Dnautilus-actions=disabled -> drops libnautilus-extension-4 (we don't build nautilus here)
#   -Dnotification=disabled  -> drops libnotify
#   -Dintrospection=disabled -> typelibs can't be cross-generated for Mach-O (gnome-plan.md #2)
#   -Duse_native_appchooser=false (default) -> no libportal/libportal-gtk4 dep
# libarchive stays auto -> it links our libarchive build. json-glib is auto/required:false and we
# have it, so it links too. file-roller still shells out to CLI archivers (tar/gzip/xz/zip/7z)
# for formats libarchive doesn't cover; those are Recommends, not hard deps.
#
# DEPENDS (target): gtk4 + libadwaita + libarchive + json-glib (+ glib, prebuilt).

SUBPROJECTS         += file-roller
FILE-ROLLER_MAJOR_V := 44
FILE-ROLLER_VERSION := $(FILE-ROLLER_MAJOR_V).7
DEB_FILE-ROLLER_V   ?= $(FILE-ROLLER_VERSION)

file-roller-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/file-roller/$(FILE-ROLLER_MAJOR_V)/file-roller-$(FILE-ROLLER_VERSION).tar.xz)
	$(call EXTRACT_TAR,file-roller-$(FILE-ROLLER_VERSION).tar.xz,file-roller-$(FILE-ROLLER_VERSION),file-roller)
	# Procursus' libarchive.pc carries `Requires.private: iconv`, but on iOS libiconv lives in
	# libSystem so no separate lib (and no iconv.pc) is staged. Without iconv.pc, pkg-config
	# errors resolving `--libs libarchive` -> meson reports libarchive "not found" and file-roller
	# silently loses its archive engine (links json-glib/gtk only). Stage a minimal iconv.pc
	# (idempotent) so the dependency resolves. The SDK's libiconv satisfies any -liconv.
	mkdir -p $(BUILD_BASE)$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig
	if [ ! -f $(BUILD_BASE)$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig/iconv.pc ]; then \
		printf 'prefix=%s\nexec_prefix=$${prefix}\nlibdir=$${exec_prefix}/lib\nincludedir=$${prefix}/include\n\nName: iconv\nDescription: iOS SDK libiconv (pc stub for Requires.private resolution)\nVersion: 1.17\nLibs: -liconv\nCflags:\n' '$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)' > $(BUILD_BASE)$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig/iconv.pc; \
	fi
	mkdir -p $(BUILD_WORK)/file-roller/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/file-roller/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/file-roller/.build_complete),)
file-roller:
	@echo "Using previously built file-roller."
else
file-roller: file-roller-setup gtk4 libadwaita libarchive json-glib
	cd $(BUILD_WORK)/file-roller/build && meson \
		--cross-file cross.txt \
		-Dpackagekit=false \
		-Dnautilus-actions=disabled \
		-Dnotification=disabled \
		-Dintrospection=disabled \
		-Duse_native_appchooser=false \
		..
	+ninja -C $(BUILD_WORK)/file-roller/build
	+DESTDIR="$(BUILD_STAGE)/file-roller" ninja -C $(BUILD_WORK)/file-roller/build install
	$(call AFTER_BUILD,copy)
endif

file-roller-package: file-roller-stage
	rm -rf $(BUILD_DIST)/file-roller
	mkdir -p $(BUILD_DIST)/file-roller/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	# app: bin/file-roller + libexec (if any) + share (desktop, icons, gschemas, gresource, ui)
	cp -a $(BUILD_STAGE)/file-roller/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin $(BUILD_DIST)/file-roller/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	if [ -d "$(BUILD_STAGE)/file-roller/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec" ]; then \
		cp -a $(BUILD_STAGE)/file-roller/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec $(BUILD_DIST)/file-roller/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
	fi
	cp -a $(BUILD_STAGE)/file-roller/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share $(BUILD_DIST)/file-roller/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	$(call SIGN,file-roller,general.xml)
	$(call PACK,file-roller,DEB_FILE-ROLLER_V)
	rm -rf $(BUILD_DIST)/file-roller

.PHONY: file-roller file-roller-package
