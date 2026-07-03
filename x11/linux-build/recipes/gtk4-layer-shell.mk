ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# gtk4-layer-shell.mk — the Layer Shell Wayland protocol for GTK4 apps. Lets a GTK4
# window become a zwlr_layer_surface_v1 (anchored panel / overview / background),
# which the iosc desktop shell uses for its richer (toolkit) chrome. See
# x11/docs/iosc-shell.md §4 and x11/apps/iosc-shell/.
#
# v1.3.0 is shim-based (src/libwayland-shim.c + xdg-surface-server.c): it intercepts
# libwayland-client and translates xdg-shell -> layer-shell, so — unlike the old
# gtk-priv approach — it needs NO private GTK/GDK headers and is not pinned to an exact
# GTK micro version. Deps are just gtk4 + wayland-client (both already built here).
#
# Build knobs: introspection/vapi OFF (the gnome module's g-ir-scanner is the on-device
# scan path, not needed for the C API the overview uses); examples/tests/docs OFF;
# smoke-tests OFF (they RUN example binaries — impossible when cross-compiling for iOS).
# Mirrors recipes/json-glib.mk / gtk4.mk style.

SUBPROJECTS         += gtk4-layer-shell
GTK4-LAYER-SHELL_VERSION := 1.3.0
DEB_GTK4-LAYER-SHELL_V   ?= $(GTK4-LAYER-SHELL_VERSION)+ios1

gtk4-layer-shell-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://github.com/wmww/gtk4-layer-shell/archive/refs/tags/v$(GTK4-LAYER-SHELL_VERSION).tar.gz)
	$(call EXTRACT_TAR,v$(GTK4-LAYER-SHELL_VERSION).tar.gz,gtk4-layer-shell-$(GTK4-LAYER-SHELL_VERSION),gtk4-layer-shell)
	rm -rf $(BUILD_WORK)/gtk4-layer-shell/build
	mkdir -p $(BUILD_WORK)/gtk4-layer-shell/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/gtk4-layer-shell/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/gtk4-layer-shell/.build_complete),)
gtk4-layer-shell:
	@echo "Using previously built gtk4-layer-shell."
else
gtk4-layer-shell: gtk4-layer-shell-setup gtk4
	cd $(BUILD_WORK)/gtk4-layer-shell/build && meson \
		--cross-file cross.txt \
		-Dintrospection=false \
		-Dvapi=false \
		-Dexamples=false \
		-Dtests=false \
		-Ddocs=false \
		-Dsmoke-tests=false \
		..
	+ninja -C $(BUILD_WORK)/gtk4-layer-shell/build
	+DESTDIR="$(BUILD_STAGE)/gtk4-layer-shell" ninja -C $(BUILD_WORK)/gtk4-layer-shell/build install
	# Like the rest of the GTK stack, anything linking the proxy-libintl gets relinked
	# onto the libgtkintl shim. gtk4-layer-shell pulls gtk4 transitively; harmless if no
	# @rpath/libintl.dylib reference exists (install_name_tool -change is a no-op then).
	for f in $$(find $(BUILD_STAGE)/gtk4-layer-shell/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib -type f 2>/dev/null); do \
		$(I_N_T) -change @rpath/libintl.dylib @rpath/libgtkintl.dylib $$f 2>/dev/null || true; \
	done
	$(call AFTER_BUILD,copy)
endif

# Single combined lib+dev deb — a desktop component we own; both the runtime .dylib and
# the dev headers/.pc ship together (the overview links it at build time, loads it at run
# time). Split into -0 / -dev later if Procursus-style separation is wanted.
gtk4-layer-shell-package: gtk4-layer-shell-stage
	rm -rf $(BUILD_DIST)/gtk4-layer-shell
	mkdir -p $(BUILD_DIST)/gtk4-layer-shell/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/gtk4-layer-shell/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/gtk4-layer-shell/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/
	cp -a $(BUILD_STAGE)/gtk4-layer-shell/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/gtk4-layer-shell/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/ 2>/dev/null || true

	$(call SIGN,gtk4-layer-shell,general.xml)
	$(call PACK,gtk4-layer-shell,DEB_GTK4-LAYER-SHELL_V)
	rm -rf $(BUILD_DIST)/gtk4-layer-shell

.PHONY: gtk4-layer-shell gtk4-layer-shell-package
