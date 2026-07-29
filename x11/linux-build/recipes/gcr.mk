ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# gnome-shell links gcr-4 unconditionally (ShellKeyringPrompt/GcrPrompt), so it's required.
# ssh_agent is disabled: it would drag in libsecret + host ssh probes.
# gpg_path is set explicitly so configure doesn't probe the host for a gpg binary.

SUBPROJECTS  += gcr
GCR_MAJOR_V  := 4.2
GCR_VERSION  := $(GCR_MAJOR_V).1
DEB_GCR_V    ?= $(GCR_VERSION)+ios1

gcr-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/gcr/$(GCR_MAJOR_V)/gcr-$(GCR_VERSION).tar.xz)
	$(call EXTRACT_TAR,gcr-$(GCR_VERSION).tar.xz,gcr-$(GCR_VERSION),gcr)
	mkdir -p $(BUILD_WORK)/gcr/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/gcr/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/gcr/.build_complete),)
gcr:
	@echo "Using previously built gcr."
else
gcr: gcr-setup glib2.0
	cd $(BUILD_WORK)/gcr/build && meson \
		--cross-file cross.txt \
		-Dintrospection=false \
		-Dvapi=false \
		-Dgtk4=false \
		-Dgtk_doc=false \
		-Dssh_agent=false \
		-Dsystemd=disabled \
		-Dgpg_path=$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/gpg \
		..
	+ninja -C $(BUILD_WORK)/gcr/build
	+DESTDIR="$(BUILD_STAGE)/gcr" ninja -C $(BUILD_WORK)/gcr/build install
	$(call AFTER_BUILD,copy)
endif

gcr-package: gcr-stage
	rm -rf $(BUILD_DIST)/libgcr-4-4 $(BUILD_DIST)/gcr4-dev
	mkdir -p $(BUILD_DIST)/libgcr-4-4/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/gcr4-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# libgcr-4-4 — the gcr-4 + gck-2 runtime dylibs (+ any libexec/D-Bus service data)
	cp -a $(BUILD_STAGE)/gcr/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libgcr-4.*.dylib \
		$(BUILD_STAGE)/gcr/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libgck-2.*.dylib \
		$(BUILD_DIST)/libgcr-4-4/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	if [ -d "$(BUILD_STAGE)/gcr/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec" ]; then \
		cp -a $(BUILD_STAGE)/gcr/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec $(BUILD_DIST)/libgcr-4-4/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
	fi
	if [ -d "$(BUILD_STAGE)/gcr/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/dbus-1" ]; then \
		mkdir -p $(BUILD_DIST)/libgcr-4-4/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share; \
		cp -a $(BUILD_STAGE)/gcr/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/dbus-1 $(BUILD_DIST)/libgcr-4-4/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share; \
	fi

	# gcr4-dev — headers + .pc + unversioned symlinks (on-device introspection build)
	cp -a $(BUILD_STAGE)/gcr/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/gcr4-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/gcr/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig $(BUILD_DIST)/gcr4-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/gcr/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libgcr-4.dylib \
		$(BUILD_STAGE)/gcr/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libgck-2.dylib \
		$(BUILD_DIST)/gcr4-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	$(call SIGN,libgcr-4-4,general.xml)
	$(call PACK,libgcr-4-4,DEB_GCR_V)
	$(call PACK,gcr4-dev,DEB_GCR_V)
	rm -rf $(BUILD_DIST)/libgcr-4-4 $(BUILD_DIST)/gcr4-dev

.PHONY: gcr gcr-package
