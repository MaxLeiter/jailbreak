ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# Pinned to 46.2: the newest release whose gtk4 requirement (>= 4.13.8) is satisfied by our
# gtk4 4.14.5. 47.x bumped the floor to gtk4 4.15.2, 48.x to 4.17.1 — both newer than our base.
#
# Papers 46.x builds its shell as a Rust crate. The docs-app driver installs a
# pinned native Linux/arm64 Rust toolchain plus the aarch64-apple-ios standard
# library; the source patch selects that Cargo target while Meson cross-builds
# the C libraries with Procursus.

SUBPROJECTS      += papers
PAPERS_MAJOR_V   := 46
PAPERS_VERSION   := 46.2
DEB_PAPERS_V     ?= $(PAPERS_VERSION)+ios1

papers-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/papers/$(PAPERS_MAJOR_V)/papers-$(PAPERS_VERSION).tar.xz)
	$(call EXTRACT_TAR,papers-$(PAPERS_VERSION).tar.xz,papers-$(PAPERS_VERSION),papers)
	$(call DO_PATCH,papers,papers,-p1)
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
	# Put the unprefixed gettext ABI shim ahead of GLib's bundled proxy-libintl
	# for the final Rust link. Its install name remains @rpath/libgtkintl.dylib.
	ln -sf /work/Procursus/build_tools/papers-gettext$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libgtkintl.dylib \
		$(BUILD_BASE)/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libintl.dylib
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
