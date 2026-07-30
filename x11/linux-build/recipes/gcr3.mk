ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# Geary 46 uses the gcr-3/gck-1 API family. Keep it parallel-installable with
# the gcr-4/gck-2 package already used by GNOME Shell.

SUBPROJECTS  += gcr3
GCR3_VERSION := 3.41.1
DEB_GCR3_V   ?= $(GCR3_VERSION)+ios1

gcr3-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/gcr/3.41/gcr-$(GCR3_VERSION).tar.xz)
	$(call EXTRACT_TAR,gcr-$(GCR3_VERSION).tar.xz,gcr-$(GCR3_VERSION),gcr3)
	$(call DO_PATCH,gcr3,gcr3,-p1)
	rm -rf $(BUILD_WORK)/gcr3/build && mkdir -p $(BUILD_WORK)/gcr3/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/gcr3/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/gcr3/.build_complete),)
gcr3:
	@echo "Using previously built gcr-3."
else
gcr3: gcr3-setup glib2.0 gtk+3.0
	cd $(BUILD_WORK)/gcr3/build && meson \
		--cross-file cross.txt \
		--buildtype=release \
		-Dintrospection=false \
		-Dgtk=true \
		-Dgtk_doc=false \
		-Dssh_agent=false \
		-Dsystemd=disabled \
		-Dgpg_path=$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/gpg \
		..
	+ninja -C $(BUILD_WORK)/gcr3/build
	+DESTDIR="$(BUILD_STAGE)/gcr3" ninja -C $(BUILD_WORK)/gcr3/build install
	$(call AFTER_BUILD,copy)
endif

gcr3-package: gcr3-stage
	rm -rf $(BUILD_DIST)/libgck-1-0 $(BUILD_DIST)/libgcr-3-1 $(BUILD_DIST)/libgcr-3-dev
	mkdir -p \
		$(BUILD_DIST)/libgck-1-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libgcr-3-1/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX) \
		$(BUILD_DIST)/libgcr-3-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/gcr3/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libgck-1.0.dylib \
		$(BUILD_DIST)/libgck-1-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/
	cp -a $(BUILD_STAGE)/gcr3/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin \
		$(BUILD_STAGE)/gcr3/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec \
		$(BUILD_STAGE)/gcr3/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share \
		$(BUILD_DIST)/libgcr-3-1/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/
	mkdir -p $(BUILD_DIST)/libgcr-3-1/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/gcr3/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libgcr-base-3.1.dylib \
		$(BUILD_STAGE)/gcr3/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libgcr-ui-3.1.dylib \
		$(BUILD_DIST)/libgcr-3-1/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/
	cp -a $(BUILD_STAGE)/gcr3/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libgcr-3-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/
	cp -a $(BUILD_STAGE)/gcr3/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig \
		$(BUILD_STAGE)/gcr3/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libgck-1.dylib \
		$(BUILD_STAGE)/gcr3/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libgcr-base-3.dylib \
		$(BUILD_STAGE)/gcr3/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libgcr-ui-3.dylib \
		$(BUILD_DIST)/libgcr-3-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/
	$(call SIGN,libgck-1-0)
	$(call SIGN,libgcr-3-1,iosc-gpu-client-ent.xml,,,nogeneral)
	$(call PACK,libgck-1-0,DEB_GCR3_V)
	$(call PACK,libgcr-3-1,DEB_GCR3_V)
	$(call PACK,libgcr-3-dev,DEB_GCR3_V)
	rm -rf $(BUILD_DIST)/libgck-1-0 $(BUILD_DIST)/libgcr-3-1 $(BUILD_DIST)/libgcr-3-dev

.PHONY: gcr3 gcr3-package
