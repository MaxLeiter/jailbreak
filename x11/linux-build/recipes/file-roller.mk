ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# The archive engine is libarchive, already built by Procursus (3.7.2 -> libarchive13) — the
# only "new" sub-dep this needs. file-roller still shells out to CLI archivers (tar/gzip/xz/
# zip/7z) for formats libarchive doesn't cover; those are Recommends, not hard deps.

SUBPROJECTS         += file-roller
FILE-ROLLER_MAJOR_V := 44
FILE-ROLLER_VERSION := $(FILE-ROLLER_MAJOR_V).7
DEB_FILE-ROLLER_V   ?= $(FILE-ROLLER_VERSION)+ios1

file-roller-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/file-roller/$(FILE-ROLLER_MAJOR_V)/file-roller-$(FILE-ROLLER_VERSION).tar.xz)
	$(call EXTRACT_TAR,file-roller-$(FILE-ROLLER_VERSION).tar.xz,file-roller-$(FILE-ROLLER_VERSION),file-roller)
	# Procursus' libarchive.pc requires iconv via pkg-config, but iOS has no separate libiconv
	# (it's in libSystem) so no iconv.pc is staged. Without it, meson silently reports
	# libarchive "not found" and file-roller builds without its archive engine. Stage a
	# minimal iconv.pc stub so the dependency resolves.
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
	cp -a $(BUILD_STAGE)/file-roller/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin $(BUILD_DIST)/file-roller/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	if [ -d "$(BUILD_STAGE)/file-roller/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec" ]; then \
		cp -a $(BUILD_STAGE)/file-roller/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec $(BUILD_DIST)/file-roller/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
	fi
	cp -a $(BUILD_STAGE)/file-roller/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share $(BUILD_DIST)/file-roller/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	$(call SIGN,file-roller,iosc-gpu-client-ent.xml,,,nogeneral)
	$(call PACK,file-roller,DEB_FILE-ROLLER_V)
	rm -rf $(BUILD_DIST)/file-roller

.PHONY: file-roller file-roller-package
