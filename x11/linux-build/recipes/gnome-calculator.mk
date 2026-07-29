ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# Validation target for the vendored-.vapi cross-Vala build flow: valac transpiles Vala->C
# on the build HOST (add valac to the Dockerfile apt list), then the cross CC compiles the C.
# No target binary runs during the build.
#
# VAPI precondition: version-matched dependency .vapi files must be on valac's search path.
# We vendor gtk4/gdk4/gsk4/libadwaita-1/gtksourceview-5/libsoup-3.0 vapi from Ubuntu 24.04
# (gtk4 4.14.5, exact version match) into the host valac vapidir; gee-0.8.vapi comes from our
# libgee build. See linux-build/vapi/README.md for provisioning.

SUBPROJECTS               += gnome-calculator
GNOME-CALCULATOR_MAJOR_V  := 46
GNOME-CALCULATOR_VERSION  := $(GNOME-CALCULATOR_MAJOR_V).2
DEB_GNOME-CALCULATOR_V    ?= $(GNOME-CALCULATOR_VERSION)+ios1

gnome-calculator-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/gnome-calculator/$(GNOME-CALCULATOR_MAJOR_V)/gnome-calculator-$(GNOME-CALCULATOR_VERSION).tar.xz)
	$(call EXTRACT_TAR,gnome-calculator-$(GNOME-CALCULATOR_VERSION).tar.xz,gnome-calculator-$(GNOME-CALCULATOR_VERSION),gnome-calculator)
	mkdir -p $(BUILD_WORK)/gnome-calculator/build
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
	vala = 'valac'\n \
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/gnome-calculator/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/gnome-calculator/.build_complete),)
gnome-calculator:
	@echo "Using previously built gnome-calculator."
else
gnome-calculator: gnome-calculator-setup gtk4 libadwaita gtksourceview5 libsoup3 libgee mpfr4 mpclib3
	cd $(BUILD_WORK)/gnome-calculator/build && meson \
		--cross-file cross.txt \
		-Dui-tests=false \
		-Ddisable-introspection=true \
		..
	+ninja -C $(BUILD_WORK)/gnome-calculator/build
	+DESTDIR="$(BUILD_STAGE)/gnome-calculator" ninja -C $(BUILD_WORK)/gnome-calculator/build install
	$(call AFTER_BUILD,copy)
endif

gnome-calculator-package: gnome-calculator-stage
	rm -rf $(BUILD_DIST)/gnome-calculator
	mkdir -p $(BUILD_DIST)/gnome-calculator/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	# app: bin/gnome-calculator + libexec/gcalccmd? + share (desktop, icons, gschemas, gresource)
	cp -a $(BUILD_STAGE)/gnome-calculator/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin $(BUILD_DIST)/gnome-calculator/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/gnome-calculator/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share $(BUILD_DIST)/gnome-calculator/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	$(call SIGN,gnome-calculator,iosc-gpu-client-ent.xml,,,nogeneral)
	$(call PACK,gnome-calculator,DEB_GNOME-CALCULATOR_V)
	rm -rf $(BUILD_DIST)/gnome-calculator

.PHONY: gnome-calculator gnome-calculator-package
