ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

SUBPROJECTS  += atk
ATK_MAJOR_V  := 2.38
ATK_VERSION  := $(ATK_MAJOR_V).0
DEB_LIBATK_V ?= $(ATK_VERSION)

atk-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://ftp.gnome.org/pub/gnome/sources/atk/$(ATK_MAJOR_V)/atk-$(ATK_VERSION).tar.xz)
	$(call EXTRACT_TAR,atk-$(ATK_VERSION).tar.xz,atk-$(ATK_VERSION),atk)
	mkdir -p $(BUILD_WORK)/atk/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/atk/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/atk/.build_complete),)
atk:
	@echo "Using previously built atk."
else
atk: atk-setup glib2.0
	cd $(BUILD_WORK)/atk/build && meson \
		--cross-file cross.txt \
		-Dintrospection=false \
		-Ddocs=false \
		..
	cd $(BUILD_WORK)/atk/build; \
		DESTDIR="$(BUILD_STAGE)/atk" meson install
	$(call AFTER_BUILD,copy)
endif

atk-package: atk-stage
	# atk.mk Package Structure
	rm -rf $(BUILD_DIST)/libatk1.0-0 $(BUILD_DIST)/libatk1.0-dev
	mkdir -p $(BUILD_DIST)/libatk1.0-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libatk1.0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# atk.mk Prep libatk1.0-0 (runtime dylib)
	cp -a $(BUILD_STAGE)/atk/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/*-1.0.0.dylib $(BUILD_DIST)/libatk1.0-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# atk.mk Prep libatk1.0-dev (headers, symlinks, .pc)
	cp -a $(BUILD_STAGE)/atk/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/libatk1.0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/atk/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/!(*-1.0.0.dylib) $(BUILD_DIST)/libatk1.0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	if [ -d "$(BUILD_STAGE)/atk/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share" ]; then \
		cp -a $(BUILD_STAGE)/atk/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share $(BUILD_DIST)/libatk1.0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
	fi

	# atk.mk Sign
	$(call SIGN,libatk1.0-0,general.xml)
	$(call SIGN,libatk1.0-dev,general.xml)

	# atk.mk Make .debs
	$(call PACK,libatk1.0-0,DEB_LIBATK_V)
	$(call PACK,libatk1.0-dev,DEB_LIBATK_V)

	# atk.mk Build cleanup
	rm -rf $(BUILD_DIST)/libatk1.0-0 $(BUILD_DIST)/libatk1.0-dev

.PHONY: atk atk-package
