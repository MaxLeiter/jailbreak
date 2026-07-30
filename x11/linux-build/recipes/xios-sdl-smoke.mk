ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# Signed clients that prove SDL2/SDL3 can create Wayland GLES windows through
# the Xios ANGLE shim before large game ports are attempted.

SUBPROJECTS            += xios-sdl-smoke
XIOS_SDL_SMOKE_VERSION := 1.0.1
DEB_XIOS_SDL_SMOKE_V   ?= $(XIOS_SDL_SMOKE_VERSION)

xios-sdl-smoke-setup: setup
	rm -rf $(BUILD_WORK)/xios-sdl-smoke
	mkdir -p $(BUILD_WORK)/xios-sdl-smoke
	cp /work/recipes/xios-sdl2-smoke.c $(BUILD_WORK)/xios-sdl-smoke/
	cp /work/recipes/xios-sdl3-smoke.c $(BUILD_WORK)/xios-sdl-smoke/

ifneq ($(wildcard $(BUILD_WORK)/xios-sdl-smoke/.build_complete),)
xios-sdl-smoke:
	@echo "Using previously built Xios SDL smoke clients."
else
xios-sdl-smoke: xios-sdl-smoke-setup sdl2 sdl3
	$(CC) $(CFLAGS) \
		-I$(BUILD_BASE)/var/jb/usr/include \
		-L$(BUILD_BASE)/var/jb/usr/lib \
		-o $(BUILD_WORK)/xios-sdl-smoke/xios-sdl2-smoke \
		$(BUILD_WORK)/xios-sdl-smoke/xios-sdl2-smoke.c \
		-lSDL2 -L$(BUILD_BASE)/var/jb/lib/angle -lEGL -lGLESv2
	$(CC) $(CFLAGS) \
		-I$(BUILD_BASE)/var/jb/usr/include \
		-L$(BUILD_BASE)/var/jb/usr/lib \
		-o $(BUILD_WORK)/xios-sdl-smoke/xios-sdl3-smoke \
		$(BUILD_WORK)/xios-sdl-smoke/xios-sdl3-smoke.c \
		-lSDL3 -L$(BUILD_BASE)/var/jb/lib/angle -lEGL -lGLESv2
	mkdir -p $(BUILD_STAGE)/xios-sdl-smoke/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin
	cp $(BUILD_WORK)/xios-sdl-smoke/xios-sdl2-smoke \
		$(BUILD_WORK)/xios-sdl-smoke/xios-sdl3-smoke \
		$(BUILD_STAGE)/xios-sdl-smoke/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/
	$(call AFTER_BUILD,copy)
endif

xios-sdl-smoke-package: xios-sdl-smoke-stage
	rm -rf $(BUILD_DIST)/xios-sdl-smoke
	mkdir -p \
		$(BUILD_DIST)/xios-sdl-smoke/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin \
		$(BUILD_DIST)/xios-sdl-smoke/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/applications
	cp $(BUILD_STAGE)/xios-sdl-smoke/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/xios-sdl*-smoke \
		$(BUILD_DIST)/xios-sdl-smoke/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/
	cp $(BUILD_INFO)/xios-sdl2-smoke.desktop \
		$(BUILD_INFO)/xios-sdl3-smoke.desktop \
		$(BUILD_DIST)/xios-sdl-smoke/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/applications/

	$(call SIGN,xios-sdl-smoke,iosc-gpu-client-ent.xml,,,nogeneral)
	$(call PACK,xios-sdl-smoke,DEB_XIOS_SDL_SMOKE_V)
	rm -rf $(BUILD_DIST)/xios-sdl-smoke

.PHONY: xios-sdl-smoke xios-sdl-smoke-package
