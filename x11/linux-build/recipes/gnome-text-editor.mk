ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# Ships a GSettings schema (needs glib-compile-schemas in postinst).
# enchant builds with no dict backend, so spell-check is a silent no-op -- fine for first-light.
# Build-host tools required: desktop-file-utils + appstream.

SUBPROJECTS               += gnome-text-editor
GNOME-TEXT-EDITOR_MAJOR_V := 46
GNOME-TEXT-EDITOR_VERSION := $(GNOME-TEXT-EDITOR_MAJOR_V).3
DEB_GNOME-TEXT-EDITOR_V   ?= $(GNOME-TEXT-EDITOR_VERSION)+ios1

gnome-text-editor-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/gnome-text-editor/$(GNOME-TEXT-EDITOR_MAJOR_V)/gnome-text-editor-$(GNOME-TEXT-EDITOR_VERSION).tar.xz)
	$(call EXTRACT_TAR,gnome-text-editor-$(GNOME-TEXT-EDITOR_VERSION).tar.xz,gnome-text-editor-$(GNOME-TEXT-EDITOR_VERSION),gnome-text-editor)
	$(call DO_PATCH,gnome-text-editor,gnome-text-editor,-p1)
	rm -rf $(BUILD_WORK)/gnome-text-editor/build && mkdir -p $(BUILD_WORK)/gnome-text-editor/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/gnome-text-editor/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/gnome-text-editor/.build_complete),)
gnome-text-editor:
	@echo "Using previously built gnome-text-editor."
else
gnome-text-editor: gnome-text-editor-setup gtk4 libadwaita gtksourceview5 editorconfig enchant
	cd $(BUILD_WORK)/gnome-text-editor/build && meson \
		--cross-file cross.txt \
		-Ddevelopment=false \
		-Denchant=enabled \
		..
	+ninja -C $(BUILD_WORK)/gnome-text-editor/build
	+DESTDIR="$(BUILD_STAGE)/gnome-text-editor" ninja -C $(BUILD_WORK)/gnome-text-editor/build install
	$(call AFTER_BUILD,copy)
endif

gnome-text-editor-package: gnome-text-editor-stage
	rm -rf $(BUILD_DIST)/gnome-text-editor
	mkdir -p $(BUILD_DIST)/gnome-text-editor/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	# app: bin/gnome-text-editor + share
	cp -a $(BUILD_STAGE)/gnome-text-editor/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin $(BUILD_DIST)/gnome-text-editor/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/gnome-text-editor/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share $(BUILD_DIST)/gnome-text-editor/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	$(call SIGN,gnome-text-editor,iosc-gpu-client-ent.xml,,,nogeneral)
	$(call PACK,gnome-text-editor,DEB_GNOME-TEXT-EDITOR_V)
	rm -rf $(BUILD_DIST)/gnome-text-editor

.PHONY: gnome-text-editor gnome-text-editor-package
