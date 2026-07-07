ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# GTK3 gtk-layer-shell: zwlr_layer_shell_v1 integration required by Waybar.
# This is distinct from the existing GTK4 gtk4-layer-shell package.

SUBPROJECTS                 += gtk-layer-shell
GTK-LAYER-SHELL_VERSION     := 0.9.2
DEB_GTK-LAYER-SHELL_V       ?= $(GTK-LAYER-SHELL_VERSION)+ios1

gtk-layer-shell-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://github.com/wmww/gtk-layer-shell/archive/refs/tags/v$(GTK-LAYER-SHELL_VERSION).tar.gz)
	$(call EXTRACT_TAR,v$(GTK-LAYER-SHELL_VERSION).tar.gz,gtk-layer-shell-$(GTK-LAYER-SHELL_VERSION),gtk-layer-shell)
	rm -rf $(BUILD_WORK)/gtk-layer-shell/build
	mkdir -p $(BUILD_WORK)/gtk-layer-shell/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/gtk-layer-shell/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/gtk-layer-shell/.build_complete),)
gtk-layer-shell:
	@echo "Using previously built gtk-layer-shell."
else
gtk-layer-shell: gtk-layer-shell-setup gtk+3.0 wayland wayland-protocols
	cd $(BUILD_WORK)/gtk-layer-shell/build && meson \
		--cross-file cross.txt \
		-Dexamples=false \
		-Ddocs=false \
		-Dtests=false \
		-Dintrospection=false \
		-Dvapi=false \
		..
	+ninja -C $(BUILD_WORK)/gtk-layer-shell/build
	+DESTDIR="$(BUILD_STAGE)/gtk-layer-shell" ninja -C $(BUILD_WORK)/gtk-layer-shell/build install
	for f in $$(find $(BUILD_STAGE)/gtk-layer-shell/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib -type f 2>/dev/null); do \
		$(I_N_T) -change @rpath/libintl.dylib @rpath/libgtkintl.dylib $$f 2>/dev/null || true; \
	done
	$(call AFTER_BUILD,copy)
endif

gtk-layer-shell-package: gtk-layer-shell-stage
	rm -rf $(BUILD_DIST)/libgtk-layer-shell0 $(BUILD_DIST)/libgtk-layer-shell-dev
	mkdir -p $(BUILD_DIST)/libgtk-layer-shell0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libgtk-layer-shell-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	cp -a $(BUILD_STAGE)/gtk-layer-shell/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libgtk-layer-shell.0.dylib \
		$(BUILD_DIST)/libgtk-layer-shell0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	cp -a $(BUILD_STAGE)/gtk-layer-shell/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libgtk-layer-shell-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/gtk-layer-shell/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/!(libgtk-layer-shell.0.dylib) \
		$(BUILD_DIST)/libgtk-layer-shell-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	$(call SIGN,libgtk-layer-shell0,general.xml)
	$(call PACK,libgtk-layer-shell0,DEB_GTK-LAYER-SHELL_V)
	$(call PACK,libgtk-layer-shell-dev,DEB_GTK-LAYER-SHELL_V)
	rm -rf $(BUILD_DIST)/libgtk-layer-shell0 $(BUILD_DIST)/libgtk-layer-shell-dev

.PHONY: gtk-layer-shell gtk-layer-shell-package
