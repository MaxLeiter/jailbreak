ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# phonon.mk - Phonon4Qt6 library for Gwenview.

SUBPROJECTS += phonon
PHONON_VERSION = 4.12.0
DEB_PHONON_V ?= $(PHONON_VERSION)+ios1

phonon-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.kde.org/stable/phonon/$(PHONON_VERSION)/phonon-$(PHONON_VERSION).tar.xz)
	$(call EXTRACT_TAR,phonon-$(PHONON_VERSION).tar.xz,phonon-$(PHONON_VERSION),phonon)
	sed -i '/^[[:space:]]*ecm_install_po_files_as_qm(/s/^/# ios-bringup-no-linguist: /' $(BUILD_WORK)/phonon/CMakeLists.txt
	$(call QT6_WRITE_IOSEXEC_FIXUP)
	$(call QT6_RM_SHADOW_HEADERS)

ifneq ($(wildcard $(BUILD_WORK)/phonon/.build_complete),)
phonon:
	@echo "Using previously built phonon."
else
phonon: phonon-setup
	mkdir -p $(BUILD_WORK)/phonon/build
	cd $(BUILD_WORK)/phonon/build && cmake .. \
		-G Ninja \
		$(KF6_CMAKE_FLAGS) \
		-DPHONON_BUILD_QT5=OFF \
		-DPHONON_BUILD_QT6=ON \
		-DPHONON_BUILD_EXPERIMENTAL=OFF \
		-DPHONON_BUILD_DEMOS=OFF \
		-DPHONON_BUILD_DESIGNER_PLUGIN=OFF \
		-DPHONON_BUILD_DOC=OFF \
		-DPHONON_BUILD_SETTINGS=OFF \
		-DPHONON_PULSESUPPORT=OFF \
		-DPHONON_NO_PLATFORMPLUGIN=ON
	+ninja -C $(BUILD_WORK)/phonon/build
	+DESTDIR="$(BUILD_STAGE)/phonon" ninja -C $(BUILD_WORK)/phonon/build install
	$(call AFTER_BUILD,copy)
endif

phonon-package: phonon-stage
	rm -rf $(BUILD_DIST)/phonon4qt6 $(BUILD_DIST)/phonon4qt6-dev
	mkdir -p $(BUILD_DIST)/phonon4qt6/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/phonon4qt6-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/phonon/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libphonon4qt6*.dylib \
		$(BUILD_DIST)/phonon4qt6/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/
	for d in include lib/cmake lib/pkgconfig share/phonon4qt6; do \
		if [ -e "$(BUILD_STAGE)/phonon/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d" ]; then \
			mkdir -p "$(BUILD_DIST)/phonon4qt6-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$(dirname $$d)"; \
			cp -a "$(BUILD_STAGE)/phonon/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d" \
				"$(BUILD_DIST)/phonon4qt6-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d"; \
		fi; \
	done
	$(call SIGN,phonon4qt6,general.xml)
	$(call PACK,phonon4qt6,DEB_PHONON_V)
	$(call PACK,phonon4qt6-dev,DEB_PHONON_V)
	rm -rf $(BUILD_DIST)/phonon4qt6 $(BUILD_DIST)/phonon4qt6-dev

.PHONY: phonon phonon-package
