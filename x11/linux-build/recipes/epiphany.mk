ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# GNOME Web 43 is the last GTK3 release and uses WebKitGTK 4.1/libsoup3. That
# makes it the natural full browser for the already-shipped Xios WebKit stack;
# newer releases require GTK4 and WebKitGTK 6.0.

SUBPROJECTS       += epiphany
EPIPHANY_MAJOR_V  := 43
EPIPHANY_VERSION  := $(EPIPHANY_MAJOR_V).1
DEB_EPIPHANY_V    ?= $(EPIPHANY_VERSION)+ios4

epiphany-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/epiphany/$(EPIPHANY_MAJOR_V)/epiphany-$(EPIPHANY_VERSION).tar.xz)
	$(call EXTRACT_TAR,epiphany-$(EPIPHANY_VERSION).tar.xz,epiphany-$(EPIPHANY_VERSION),epiphany)
	$(call DO_PATCH,epiphany,epiphany,-p1)
	rm -rf $(BUILD_WORK)/epiphany/build
	mkdir -p $(BUILD_WORK)/epiphany/build
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
	c_link_args = ['-L$(BUILD_BASE)/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib', '-Wl,-rpath,$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/epiphany']\n \
	[binaries]\n \
	c = '$(CC)'\n \
	cpp = '$(CXX)'\n \
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n \
	exe_wrapper = '/bin/true'\n" > $(BUILD_WORK)/epiphany/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/epiphany/.build_complete),)
epiphany:
	@echo "Using previously built GNOME Web."
else
epiphany: epiphany-setup libhandy libdazzle libportal
	cd $(BUILD_WORK)/epiphany/build && meson \
		--cross-file cross.txt \
		--buildtype=release \
		-Dunit_tests=disabled \
		-Dnetwork_tests=disabled \
		-Ddeveloper_mode=false \
		-Dtech_preview=false \
		..
	+ninja -C $(BUILD_WORK)/epiphany/build
	+DESTDIR="$(BUILD_STAGE)/epiphany" ninja -C $(BUILD_WORK)/epiphany/build install
	$(call AFTER_BUILD,copy)
endif

epiphany-package: epiphany-stage
	rm -rf $(BUILD_DIST)/epiphany
	mkdir -p $(BUILD_DIST)/epiphany/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/epiphany/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/. \
		$(BUILD_DIST)/epiphany/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/
	rm -rf $(BUILD_DIST)/epiphany/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/help \
		$(BUILD_DIST)/epiphany/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/man

	# The executable, private UI library, helpers, and WebKit web-process
	# extension are all Mach-O images and must carry the GPU client profile.
	$(call SIGN,epiphany,iosc-gpu-client-ent.xml,,,nogeneral)
	$(call PACK,epiphany,DEB_EPIPHANY_V)
	rm -rf $(BUILD_DIST)/epiphany

.PHONY: epiphany epiphany-package
