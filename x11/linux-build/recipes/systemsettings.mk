ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# systemsettings.mk - KDE System Settings shell for Xios.

SUBPROJECTS += systemsettings
SYSTEMSETTINGS_VERSION = $(PLASMA_VERSION)
DEB_SYSTEMSETTINGS_V ?= $(SYSTEMSETTINGS_VERSION)+ios3

systemsettings-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),$(call PLASMA_URL,systemsettings))
	$(call EXTRACT_TAR,systemsettings-$(PLASMA_VERSION).tar.xz,systemsettings-$(PLASMA_VERSION),systemsettings)
	bash /work/recipes/systemsettings-ios-fixes.sh $(BUILD_WORK)/systemsettings
	$(call QT6_WRITE_IOSEXEC_FIXUP)
	$(call QT6_RM_SHADOW_HEADERS)

ifneq ($(wildcard $(BUILD_WORK)/systemsettings/.build_complete),)
systemsettings:
	@echo "Using previously built systemsettings."
else
systemsettings: systemsettings-setup
	rm -rf $(BUILD_WORK)/systemsettings/build
	mkdir -p $(BUILD_WORK)/systemsettings/build
	cd $(BUILD_WORK)/systemsettings/build && cmake .. \
		-G Ninja \
		$(KF6_CMAKE_FLAGS) \
		-DBUILD_QCH=OFF \
		-DBUILD_TESTING=OFF \
		-DCMAKE_DISABLE_FIND_PACKAGE_KF6DocTools=TRUE
	+ninja -C $(BUILD_WORK)/systemsettings/build
	+DESTDIR="$(BUILD_STAGE)/systemsettings" ninja -C $(BUILD_WORK)/systemsettings/build install
	$(call AFTER_BUILD,copy)
endif

systemsettings-package: systemsettings-stage
	rm -rf $(BUILD_DIST)/systemsettings $(BUILD_DIST)/systemsettings-dev
	$(call KF6_COPY_RUNTIME,systemsettings,systemsettings)
	$(call KF6_COPY_DEV,systemsettings,systemsettings)
	if [ -d "$(BUILD_STAGE)/systemsettings/Applications/KDE/systemsettings.app" ]; then \
		mkdir -p "$(BUILD_DIST)/systemsettings$(MEMO_PREFIX)/Applications/KDE"; \
		cp -a "$(BUILD_STAGE)/systemsettings/Applications/KDE/systemsettings.app" "$(BUILD_DIST)/systemsettings$(MEMO_PREFIX)/Applications/KDE/systemsettings.app"; \
	fi
	mkdir -p $(BUILD_DIST)/systemsettings/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin
	printf '%s\n' '#!/bin/sh' 'export QT_QPA_PLATFORM="$${QT_QPA_PLATFORM:-wayland}"' 'export QT_WAYLAND_DISABLE_WINDOWDECORATION="$${QT_WAYLAND_DISABLE_WINDOWDECORATION:-1}"' 'exec $(MEMO_PREFIX)/Applications/KDE/systemsettings.app/systemsettings "$$@"' \
		> $(BUILD_DIST)/systemsettings/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/systemsettings
	chmod 0755 $(BUILD_DIST)/systemsettings/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/systemsettings
	python3 /work/recipes/systemsettings-prune-actions.py \
		$(BUILD_DIST)/systemsettings/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/applications/systemsettings.desktop \
		kcm-users kcm-screenlocker kcm-powerdevilprofilesconfig
	$(call SIGN,systemsettings,iosc-gpu-client-ent.xml,,,nogeneral)
	$(call SIGN,systemsettings-dev,general.xml)
	$(call PACK,systemsettings,DEB_SYSTEMSETTINGS_V)
	$(call PACK,systemsettings-dev,DEB_SYSTEMSETTINGS_V)
	rm -rf $(BUILD_DIST)/systemsettings $(BUILD_DIST)/systemsettings-dev

.PHONY: systemsettings systemsettings-package
