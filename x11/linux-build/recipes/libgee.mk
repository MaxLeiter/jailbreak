ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# First proof of the cross-Vala flow: VALAC=valac runs on the host to transpile Vala->C,
# then our cross CC compiles the C; valac never runs target code. Emits gee-0.8.vapi
# (share/vala/vapi), which gnome-calculator consumes directly; only needs glib's vapi,
# which ships with valac. valac is a build-host apt package -- add to the Dockerfile, like sassc.

SUBPROJECTS    += libgee
LIBGEE_MAJOR_V := 0.20
LIBGEE_VERSION := $(LIBGEE_MAJOR_V).8
DEB_LIBGEE_V   ?= $(LIBGEE_VERSION)+ios1

libgee-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/libgee/$(LIBGEE_MAJOR_V)/libgee-$(LIBGEE_VERSION).tar.xz)
	$(call EXTRACT_TAR,libgee-$(LIBGEE_VERSION).tar.xz,libgee-$(LIBGEE_VERSION),libgee)

ifneq ($(wildcard $(BUILD_WORK)/libgee/.build_complete),)
libgee:
	@echo "Using previously built libgee."
else
libgee: libgee-setup glib2.0
	cd $(BUILD_WORK)/libgee && VALAC=valac ./configure -C \
		$(DEFAULT_CONFIGURE_FLAGS) \
		--disable-static \
		--disable-introspection
	+$(MAKE) -C $(BUILD_WORK)/libgee
	+$(MAKE) -C $(BUILD_WORK)/libgee install DESTDIR=$(BUILD_STAGE)/libgee
	$(call AFTER_BUILD,copy)
endif

libgee-package: libgee-stage
	rm -rf $(BUILD_DIST)/libgee-0.8-2 $(BUILD_DIST)/libgee-0.8-dev
	mkdir -p $(BUILD_DIST)/libgee-0.8-2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libgee-0.8-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	cp -a $(BUILD_STAGE)/libgee/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libgee-0.8.2.dylib $(BUILD_DIST)/libgee-0.8-2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# -dev: headers, symlink, .pc, AND the generated gee-0.8.vapi (+ .deps) under share/vala
	cp -a $(BUILD_STAGE)/libgee/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/!(libgee-0.8.2.dylib) $(BUILD_DIST)/libgee-0.8-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/libgee/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/libgee-0.8-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	if [ -d "$(BUILD_STAGE)/libgee/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/vala" ]; then \
		mkdir -p $(BUILD_DIST)/libgee-0.8-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share; \
		cp -a $(BUILD_STAGE)/libgee/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/vala $(BUILD_DIST)/libgee-0.8-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share; \
	fi

	$(call SIGN,libgee-0.8-2,general.xml)
	$(call PACK,libgee-0.8-2,DEB_LIBGEE_V)
	$(call PACK,libgee-0.8-dev,DEB_LIBGEE_V)
	rm -rf $(BUILD_DIST)/libgee-0.8-2 $(BUILD_DIST)/libgee-0.8-dev

.PHONY: libgee libgee-package
