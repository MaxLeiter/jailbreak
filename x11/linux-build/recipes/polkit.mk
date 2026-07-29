ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# -Dlibs-only=true also disables polkitagent upstream; the port patch re-enables
# it since gnome-shell needs the agent library to link (not the setuid auth
# helper — iOS has no PAM/shadow). Source is the gitlab archive since
# freedesktop stopped tarball releases at 0.120.

SUBPROJECTS    += polkit
POLKIT_VERSION := 124
DEB_POLKIT_V   ?= $(POLKIT_VERSION)+ios1

polkit-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://gitlab.freedesktop.org/polkit/polkit/-/archive/$(POLKIT_VERSION)/polkit-$(POLKIT_VERSION).tar.gz)
	$(call EXTRACT_TAR,polkit-$(POLKIT_VERSION).tar.gz,polkit-$(POLKIT_VERSION),polkit)
	# Keep the libs-only agent library source edits in the port patch stack.
	$(call DO_PATCH,polkit,polkit,-p1)
	mkdir -p $(BUILD_WORK)/polkit/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/polkit/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/polkit/.build_complete),)
polkit:
	@echo "Using previously built polkit."
else
polkit: polkit-setup glib2.0
	cd $(BUILD_WORK)/polkit/build && meson \
		--cross-file cross.txt \
		-Dlibs-only=true \
		-Dauthfw=shadow \
		-Dsession_tracking=ConsoleKit \
		-Dintrospection=false \
		-Dexamples=false \
		-Dtests=false \
		-Dman=false \
		-Dgtk_doc=false \
		-Dpolkitd_user=mobile \
		..
	+ninja -C $(BUILD_WORK)/polkit/build
	+DESTDIR="$(BUILD_STAGE)/polkit" ninja -C $(BUILD_WORK)/polkit/build install
	$(call AFTER_BUILD,copy)
endif

polkit-package: polkit-stage
	rm -rf $(BUILD_DIST)/libpolkit-gobject-1-0 $(BUILD_DIST)/libpolkit-agent-1-0 \
		$(BUILD_DIST)/polkit-dev
	mkdir -p $(BUILD_DIST)/libpolkit-gobject-1-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libpolkit-agent-1-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/polkit-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# libpolkit-gobject-1-0 — authority client lib + the polkit-1 data dirs
	cp -a $(BUILD_STAGE)/polkit/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libpolkit-gobject-1.*.dylib \
		$(BUILD_DIST)/libpolkit-gobject-1-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	if [ -d "$(BUILD_STAGE)/polkit/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/polkit-1" ]; then \
		mkdir -p $(BUILD_DIST)/libpolkit-gobject-1-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share; \
		cp -a $(BUILD_STAGE)/polkit/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/polkit-1 $(BUILD_DIST)/libpolkit-gobject-1-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share; \
	fi

	# libpolkit-agent-1-0 — the agent lib gnome-shell links
	cp -a $(BUILD_STAGE)/polkit/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libpolkit-agent-1.*.dylib \
		$(BUILD_DIST)/libpolkit-agent-1-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# polkit-dev — headers + .pc + unversioned symlinks
	cp -a $(BUILD_STAGE)/polkit/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/polkit-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/polkit/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig $(BUILD_DIST)/polkit-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/polkit/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libpolkit-gobject-1.dylib \
		$(BUILD_STAGE)/polkit/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libpolkit-agent-1.dylib \
		$(BUILD_DIST)/polkit-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	$(call SIGN,libpolkit-gobject-1-0,general.xml)
	$(call SIGN,libpolkit-agent-1-0,general.xml)
	$(call PACK,libpolkit-gobject-1-0,DEB_POLKIT_V)
	$(call PACK,libpolkit-agent-1-0,DEB_POLKIT_V)
	$(call PACK,polkit-dev,DEB_POLKIT_V)
	rm -rf $(BUILD_DIST)/libpolkit-gobject-1-0 $(BUILD_DIST)/libpolkit-agent-1-0 \
		$(BUILD_DIST)/polkit-dev

.PHONY: polkit polkit-package
