ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

SUBPROJECTS        += mesa-demos
MESA_DEMOS_VERSION := 8.4.0
DEB_MESA_DEMOS_V   ?= $(MESA_DEMOS_VERSION)+xios1

mesa-demos-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://archive.mesa3d.org/demos/mesa-demos-$(MESA_DEMOS_VERSION).tar.gz)
	$(call EXTRACT_TAR,mesa-demos-$(MESA_DEMOS_VERSION).tar.gz,mesa-demos-$(MESA_DEMOS_VERSION),mesa-demos)
	$(call DO_PATCH,mesa-demos,mesa-demos,-p1)
	bash /work/recipes/mesa-demos-generate-xdg-shell.sh "$(BUILD_WORK)/mesa-demos"

ifneq ($(wildcard $(BUILD_WORK)/mesa-demos/.build_complete),)
mesa-demos:
	@echo "Using previously built mesa-demos."
else
mesa-demos: mesa-demos-setup mesa libglu glew libx11 libxext freetype wayland
	cd $(BUILD_WORK)/mesa-demos && ./configure -C \
		$(DEFAULT_CONFIGURE_FLAGS) \
		--enable-x11 \
		--enable-egl \
		--enable-gles2 \
		--enable-wayland \
		--disable-osmesa \
		--disable-glut
	+$(MAKE) -C $(BUILD_WORK)/mesa-demos
	+$(MAKE) -C $(BUILD_WORK)/mesa-demos install \
		DESTDIR=$(BUILD_STAGE)/mesa-demos
	$(call AFTER_BUILD)
endif

mesa-demos-package: mesa-demos-stage
	# mesa-demos.mk Package Structure
	rm -rf $(BUILD_DIST)/mesa-demos
	mkdir -p $(BUILD_DIST)/mesa-demos

	# mesa-demos.mk Prep mesa-demos
	cp -a $(BUILD_STAGE)/mesa-demos $(BUILD_DIST)
	if [ -e "$(BUILD_DIST)/mesa-demos/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/es2gears_wayland" ]; then \
		$(I_N_T) -change /var/jb/usr/lib/libEGL.dylib /var/jb/lib/angle/libEGL.dylib \
			"$(BUILD_DIST)/mesa-demos/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/es2gears_wayland" 2>/dev/null || true; \
		$(I_N_T) -change /var/jb/usr/lib/libGLESv2.dylib /var/jb/lib/angle/libGLESv2.dylib \
			"$(BUILD_DIST)/mesa-demos/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/es2gears_wayland" 2>/dev/null || true; \
		$(I_N_T) -change /var/jb/usr/lib/libGLESv2.2.dylib /var/jb/lib/angle/libGLESv2.dylib \
			"$(BUILD_DIST)/mesa-demos/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/es2gears_wayland" 2>/dev/null || true; \
		$(I_N_T) -add_rpath /var/jb/lib/angle \
			"$(BUILD_DIST)/mesa-demos/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/es2gears_wayland" 2>/dev/null || true; \
	fi

	# mesa-demos.mk Sign
	$(call SIGN,mesa-demos,iosc-gpu-client-ent.xml,,,nogeneral)

	# mesa-demos.mk Make .debs
	$(call PACK,mesa-demos,DEB_MESA_DEMOS_V)

	# mesa-demos.mk Build cleanup
	rm -rf $(BUILD_DIST)/mesa-demos

.PHONY: mesa-demos mesa-demos-package
