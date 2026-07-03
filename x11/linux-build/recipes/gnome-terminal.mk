ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# gnome-terminal.mk — the classic GTK3 terminal (still GTK3 in the GNOME 45 era). Reachable
# SOONER than the GTK4 apps because it only needs GTK3 + vte(gtk3) + our Stage-A dconf/
# gsettings-desktop-schemas. Ships a gnome-terminal-server (D-Bus activated) + GSettings
# schema (→ glib-compile-schemas in postinst).
#
# DEPENDS (target): gtk+3.0 (gtk-builder) + vte (gtk3 flavour) + pcre2 +
#   gsettings-desktop-schemas + dconf (our Stage-A recipes).
# BUILD-HOST TOOLS: itstool + desktop-file-utils (desktop-file-validate) on the build host.
#
# DRAFT — Phase 1, NOT built/verified. Mirrors recipes/pango.mk style.

SUBPROJECTS             += gnome-terminal
GNOME-TERMINAL_MAJOR_V  := 3.50
GNOME-TERMINAL_VERSION  := $(GNOME-TERMINAL_MAJOR_V).1
DEB_GNOME-TERMINAL_V    ?= $(GNOME-TERMINAL_VERSION)+ios1

gnome-terminal-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/gnome-terminal/$(GNOME-TERMINAL_MAJOR_V)/gnome-terminal-$(GNOME-TERMINAL_VERSION).tar.xz)
	$(call EXTRACT_TAR,gnome-terminal-$(GNOME-TERMINAL_VERSION).tar.xz,gnome-terminal-$(GNOME-TERMINAL_VERSION),gnome-terminal)
	mkdir -p $(BUILD_WORK)/gnome-terminal/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/gnome-terminal/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/gnome-terminal/.build_complete),)
gnome-terminal:
	@echo "Using previously built gnome-terminal."
else
gnome-terminal: gnome-terminal-setup gtk+3.0 vte pcre2 gsettings-desktop-schemas dconf
	cd $(BUILD_WORK)/gnome-terminal/build && meson \
		--cross-file cross.txt \
		-Dsearch_provider=false \
		-Dnautilus_extension=false \
		..
	+ninja -C $(BUILD_WORK)/gnome-terminal/build
	+DESTDIR="$(BUILD_STAGE)/gnome-terminal" ninja -C $(BUILD_WORK)/gnome-terminal/build install
	$(call AFTER_BUILD,copy)
endif

gnome-terminal-package: gnome-terminal-stage
	rm -rf $(BUILD_DIST)/gnome-terminal
	mkdir -p $(BUILD_DIST)/gnome-terminal/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	# app: bin/gnome-terminal + libexec/gnome-terminal-server + share
	cp -a $(BUILD_STAGE)/gnome-terminal/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin $(BUILD_DIST)/gnome-terminal/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	if [ -d "$(BUILD_STAGE)/gnome-terminal/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec" ]; then \
		cp -a $(BUILD_STAGE)/gnome-terminal/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec $(BUILD_DIST)/gnome-terminal/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
	fi
	cp -a $(BUILD_STAGE)/gnome-terminal/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share $(BUILD_DIST)/gnome-terminal/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	$(call SIGN,gnome-terminal,general.xml)
	$(call PACK,gnome-terminal,DEB_GNOME-TERMINAL_V)
	rm -rf $(BUILD_DIST)/gnome-terminal

.PHONY: gnome-terminal gnome-terminal-package
