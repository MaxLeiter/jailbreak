ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# Required by nautilus (extract/compress); libarchive comes prebuilt from Procursus.

SUBPROJECTS           += gnome-autoar
GNOME-AUTOAR_MAJOR_V  := 0.4
GNOME-AUTOAR_VERSION  := $(GNOME-AUTOAR_MAJOR_V).5
DEB_GNOME-AUTOAR_V    ?= $(GNOME-AUTOAR_VERSION)+ios1

gnome-autoar-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/gnome-autoar/$(GNOME-AUTOAR_MAJOR_V)/gnome-autoar-$(GNOME-AUTOAR_VERSION).tar.xz)
	$(call EXTRACT_TAR,gnome-autoar-$(GNOME-AUTOAR_VERSION).tar.xz,gnome-autoar-$(GNOME-AUTOAR_VERSION),gnome-autoar)
	# Procursus' libarchive.pc requires iconv.pc, but iOS libiconv lives in libSystem with no
	# iconv.pc staged; without it pkg-config can't resolve libarchive and meson reports it
	# "not found". Stage a minimal stub here (idempotent); the SDK's libiconv satisfies -liconv.
	mkdir -p $(BUILD_BASE)$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig
	if [ ! -f $(BUILD_BASE)$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig/iconv.pc ]; then \
		printf 'prefix=%s\nexec_prefix=$${prefix}\nlibdir=$${exec_prefix}/lib\nincludedir=$${prefix}/include\n\nName: iconv\nDescription: iOS SDK libiconv (pc stub for Requires.private resolution)\nVersion: 1.17\nLibs: -liconv\nCflags:\n' '$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)' > $(BUILD_BASE)$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig/iconv.pc; \
	fi
	mkdir -p $(BUILD_WORK)/gnome-autoar/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/gnome-autoar/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/gnome-autoar/.build_complete),)
gnome-autoar:
	@echo "Using previously built gnome-autoar."
else
gnome-autoar: gnome-autoar-setup glib2.0 gtk4
	cd $(BUILD_WORK)/gnome-autoar/build && meson \
		--cross-file cross.txt \
		-Dintrospection=disabled \
		-Dvapi=false \
		-Dtests=false \
		-Dgtk_doc=false \
		..
	+ninja -C $(BUILD_WORK)/gnome-autoar/build
	+DESTDIR="$(BUILD_STAGE)/gnome-autoar" ninja -C $(BUILD_WORK)/gnome-autoar/build install
	$(call AFTER_BUILD,copy)
endif

gnome-autoar-package: gnome-autoar-stage
	rm -rf $(BUILD_DIST)/libgnome-autoar-0-0 $(BUILD_DIST)/libgnome-autoar-dev
	mkdir -p $(BUILD_DIST)/libgnome-autoar-0-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libgnome-autoar-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# libgnome-autoar-0-0 (core + gtk widget dylibs, if built)
	cp -a $(BUILD_STAGE)/gnome-autoar/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libgnome-autoar*.0.dylib $(BUILD_DIST)/libgnome-autoar-0-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# libgnome-autoar-dev (headers, symlinks, .pc)
	cp -a $(BUILD_STAGE)/gnome-autoar/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/!(libgnome-autoar*.0.dylib) $(BUILD_DIST)/libgnome-autoar-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/gnome-autoar/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/libgnome-autoar-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	$(call SIGN,libgnome-autoar-0-0,general.xml)
	$(call PACK,libgnome-autoar-0-0,DEB_GNOME-AUTOAR_V)
	$(call PACK,libgnome-autoar-dev,DEB_GNOME-AUTOAR_V)
	rm -rf $(BUILD_DIST)/libgnome-autoar-0-0 $(BUILD_DIST)/libgnome-autoar-dev

.PHONY: gnome-autoar gnome-autoar-package
