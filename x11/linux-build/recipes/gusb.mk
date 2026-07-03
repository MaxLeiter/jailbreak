ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# gusb.mk — GObject wrapper over libusb. colord 1.4.7 requires it even for the client lib
# (meson.build:120). USB access never works in the iOS sandbox, but gusb/libusb only need to
# LINK for colord -> mutter -> the introspection scan; runtime USB is irrelevant here.

SUBPROJECTS  += gusb
GUSB_VERSION := 0.4.8
DEB_GUSB_V   ?= $(GUSB_VERSION)+ios1

gusb-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/gusb/$(basename $(GUSB_VERSION))/gusb-$(GUSB_VERSION).tar.xz)
	$(call EXTRACT_TAR,gusb-$(GUSB_VERSION).tar.xz,gusb-$(GUSB_VERSION),gusb)
	rm -rf $(BUILD_WORK)/gusb/build && mkdir -p $(BUILD_WORK)/gusb/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/gusb/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/gusb/.build_complete),)
gusb:
	@echo "Using previously built gusb."
else
gusb: gusb-setup glib2.0 libusb
	cd $(BUILD_WORK)/gusb/build && meson \
		--cross-file cross.txt \
		-Dintrospection=false \
		-Ddocs=false \
		-Dtests=false \
		-Dvapi=false \
		.. ; \
		DESTDIR="$(BUILD_STAGE)/gusb" ninja install
	$(call AFTER_BUILD,copy)
endif

gusb-package: gusb-stage
	rm -rf $(BUILD_DIST)/libgusb2 $(BUILD_DIST)/libgusb-dev
	mkdir -p $(BUILD_DIST)/libgusb2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libgusb-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/{include,lib}
	cp -a $(BUILD_STAGE)/gusb/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libgusb*.dylib $(BUILD_DIST)/libgusb2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib 2>/dev/null || true
	cp -a $(BUILD_STAGE)/gusb/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/libgusb-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX) 2>/dev/null || true
	cp -a $(BUILD_STAGE)/gusb/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig $(BUILD_DIST)/libgusb-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib 2>/dev/null || true
	$(call SIGN,libgusb2,general.xml)
	$(call PACK,libgusb2,DEB_GUSB_V)
	$(call PACK,libgusb-dev,DEB_GUSB_V)
	rm -rf $(BUILD_DIST)/libgusb2 $(BUILD_DIST)/libgusb-dev

.PHONY: gusb gusb-package
