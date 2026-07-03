ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# papers.mk — Papers, the GTK4/libadwaita GNOME document viewer (the GTK4 successor to Evince).
# Pinned to 46.2: the newest release whose gtk4 requirement (>= 4.13.8) is satisfied by our
# gtk4 4.14.5. 47.x bumped the floor to gtk4 4.15.2 and 48.x to 4.17.1 — both newer than our
# base — so 46.2 is the ceiling. (libadwaita >= 1.5.0 and poppler-glib >= 22.05.0 are both met
# by our libadwaita 1.5.0 and the poppler 24.08.0 built by poppler.mk.)
#
# ############################################################################################
# ## BLOCKED: Papers 46.x cannot build in the current image. Every GTK4 Papers release, from  #
# ## 46.0 onward, builds its shell as a Rust crate (subdir('shell-rs'), gated only by the     #
# ## always-true `viewer` option). shell-rs pulls the gtk-rs / gtk4-rs / libadwaita-rs stack  #
# ## from git master and must be cross-compiled to aarch64-apple-ios. The procursus-xbuild    #
# ## image ships NO Rust toolchain (no rustc/cargo, no iOS target), and there is no pure-C     #
# ## GTK4 Papers to fall back to (pre-46 is GTK3 Evince). Building Papers therefore requires   #
# ## a separate Rust->iOS cross toolchain effort (rustup + aarch64-apple-ios target + cargo    #
# ## ld64/pkg-config wiring + the gtk-rs -sys crates resolving our iOS gtk4/glib/adwaita .pc). #
# ## This recipe encodes the correct meson feature surface so it is ready the moment a Rust    #
# ## cross toolchain + a `rust` entry in cross.txt exist; UNTESTED until then.                 #
# ############################################################################################
#
# Feature surface (minimal, PDF-only): pdf backend on (poppler-glib); ps/tiff/djvu/xps/comics
# off; introspection/tests/gtk_doc/user_doc off (on-device/host-exec avoidance); thumbnailer
# and nautilus extension off (host-exec / libnautilus-extension-4 we don't ship); keyring off
# (no libsecret) and gtk_unix_print off (no CUPS print stack). exempi is UNCONDITIONAL and is
# supplied by exempi.mk (libexempi8).

SUBPROJECTS      += papers
PAPERS_MAJOR_V   := 46
PAPERS_VERSION   := 46.2
DEB_PAPERS_V     ?= $(PAPERS_VERSION)+ios1

papers-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/papers/$(PAPERS_MAJOR_V)/papers-$(PAPERS_VERSION).tar.xz)
	$(call EXTRACT_TAR,papers-$(PAPERS_VERSION).tar.xz,papers-$(PAPERS_VERSION),papers)
	mkdir -p $(BUILD_WORK)/papers/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/papers/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/papers/.build_complete),)
papers:
	@echo "Using previously built papers."
else
# Deps (gtk4/libadwaita/poppler-glib/exempi/gsettings-desktop-schemas) pre-staged in build_base;
# the driver sequences poppler/exempi before papers. No make-level prereqs.
papers: papers-setup
	cd $(BUILD_WORK)/papers/build && meson \
		--cross-file cross.txt \
		-Dintrospection=false \
		-Dtests=false \
		-Dgtk_doc=false \
		-Duser_doc=false \
		-Dthumbnailer=false \
		-Dnautilus=false \
		-Dpdf=enabled \
		-Dps=disabled \
		-Dtiff=disabled \
		-Ddjvu=disabled \
		-Dxps=disabled \
		-Dcomics=disabled \
		-Dkeyring=disabled \
		-Dgtk_unix_print=disabled \
		..
	+ninja -C $(BUILD_WORK)/papers/build
	+DESTDIR="$(BUILD_STAGE)/papers" ninja -C $(BUILD_WORK)/papers/build install
	$(call AFTER_BUILD,copy)
endif

papers-package: papers-stage
	rm -rf $(BUILD_DIST)/papers
	mkdir -p $(BUILD_DIST)/papers/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/papers/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin $(BUILD_DIST)/papers/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/papers/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib $(BUILD_DIST)/papers/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX) 2>/dev/null || true
	cp -a $(BUILD_STAGE)/papers/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share $(BUILD_DIST)/papers/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	$(call SIGN,papers,iosc-gpu-client-ent.xml,,,nogeneral)
	$(call PACK,papers,DEB_PAPERS_V)
	rm -rf $(BUILD_DIST)/papers

.PHONY: papers papers-package
