ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# Three iOS accommodations, handled by ports/gnome-session/patches:
#   1. systemd made optional (-Dsystemd=false -Dsystemd_session=disable); falls back to the
#      built-in gsm_manager_start path (RequiredComponents from .session, spawned as children).
#   2. gnome-desktop-3.0 -> gnome-desktop-4 (exports the two symbols gnome-session needs:
#      gnome_idle_monitor_new + gnome_start_systemd_scope).
#   3. gnome-session-check-accelerated* helpers dropped (need GL/GLX/xcomposite; dead code
#      when DISPLAY is unset).
# GTK3 is only pulled in for the X11 fail-whale helper; main.c never calls gtk_init.

SUBPROJECTS           += gnome-session
GNOME-SESSION_MAJOR_V := 46
GNOME-SESSION_VERSION := $(GNOME-SESSION_MAJOR_V).0
DEB_GNOME-SESSION_V   ?= $(GNOME-SESSION_VERSION)+ios1

gnome-session-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/gnome-session/$(GNOME-SESSION_MAJOR_V)/gnome-session-$(GNOME-SESSION_VERSION).tar.xz)
	$(call EXTRACT_TAR,gnome-session-$(GNOME-SESSION_VERSION).tar.xz,gnome-session-$(GNOME-SESSION_VERSION),gnome-session)
	$(call DO_PATCH,gnome-session,gnome-session,-p1)
	rm -rf $(BUILD_WORK)/gnome-session/build && mkdir -p $(BUILD_WORK)/gnome-session/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n \
	exe_wrapper = '/bin/true'\n" > $(BUILD_WORK)/gnome-session/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/gnome-session/.build_complete),)
gnome-session:
	@echo "Using previously built gnome-session."
else
gnome-session: gnome-session-setup gtk+3.0 gnome-desktop json-glib
	cd $(BUILD_WORK)/gnome-session/build && meson \
		--cross-file cross.txt \
		-Dsystemd=false \
		-Dsystemd_session=disable \
		-Dsystemd_journal=false \
		-Dconsolekit=false \
		-Dsession_selector=false \
		-Ddocbook=false \
		-Dman=false \
		..
	+ninja -C $(BUILD_WORK)/gnome-session/build
	+DESTDIR="$(BUILD_STAGE)/gnome-session" ninja -C $(BUILD_WORK)/gnome-session/build install
	# Relink the bundled proxy-libintl onto the libgtkintl shim (same pass as gtk4/mutter).
	for f in $$(find $(BUILD_STAGE)/gnome-session/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin \
			$(BUILD_STAGE)/gnome-session/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec -type f 2>/dev/null); do \
		$(I_N_T) -change @rpath/libintl.dylib @rpath/libgtkintl.dylib $$f 2>/dev/null || true; \
	done
	$(call AFTER_BUILD,copy)
endif

gnome-session-package: gnome-session-stage
	rm -rf $(BUILD_DIST)/gnome-session
	mkdir -p $(BUILD_DIST)/gnome-session$(MEMO_PREFIX)

	# Copy the CONTENTS of the staged prefix, not $(MEMO_PREFIX) itself -- that would drop
	# the leading var/ from /var/jb.
	cp -a $(BUILD_STAGE)/gnome-session$(MEMO_PREFIX)/. $(BUILD_DIST)/gnome-session$(MEMO_PREFIX)/
	rm -rf $(BUILD_DIST)/gnome-session$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/man \
		$(BUILD_DIST)/gnome-session$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/doc

	$(call SIGN,gnome-session,general.xml)
	$(call PACK,gnome-session,DEB_GNOME-SESSION_V)
	rm -rf $(BUILD_DIST)/gnome-session

.PHONY: gnome-session gnome-session-package
