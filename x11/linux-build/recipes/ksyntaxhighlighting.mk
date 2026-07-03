ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# ksyntaxhighlighting.mk - KF6 SyntaxHighlighting for KTextEditor/KWrite.

SUBPROJECTS += ksyntaxhighlighting
KSYNTAXHIGHLIGHTING_VERSION = $(KF6_VERSION)
DEB_KSYNTAXHIGHLIGHTING_V ?= $(KSYNTAXHIGHLIGHTING_VERSION)+ios1

ksyntaxhighlighting-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),$(call KF6_URL,syntax-highlighting))
	$(call EXTRACT_TAR,syntax-highlighting-$(KF6_VERSION).tar.xz,syntax-highlighting-$(KF6_VERSION),ksyntaxhighlighting)
	sed -i 's/Core Network Test/Core Network/' $(BUILD_WORK)/ksyntaxhighlighting/CMakeLists.txt
	sed -i '/^[[:space:]]*ecm_install_po_files_as_qm(/s/^/# ios-bringup-no-linguist: /' $(BUILD_WORK)/ksyntaxhighlighting/CMakeLists.txt
	sed -i 's/add_subdirectory(examples)/# ios-bringup-no-examples: add_subdirectory(examples)/' $(BUILD_WORK)/ksyntaxhighlighting/CMakeLists.txt
	$(call QT6_WRITE_IOSEXEC_FIXUP)
	$(call QT6_RM_SHADOW_HEADERS)

ifneq ($(wildcard $(BUILD_WORK)/ksyntaxhighlighting/.build_complete),)
ksyntaxhighlighting:
	@echo "Using previously built ksyntaxhighlighting."
else
ksyntaxhighlighting: ksyntaxhighlighting-setup
	mkdir -p $(BUILD_TOOLS)/ksyntaxhighlighting-host
	/usr/bin/c++ -std=c++17 -O2 -fPIC -DQT_CORE_LIB \
		-I$(QT6_HOST_PATH)/include \
		-I$(QT6_HOST_PATH)/include/QtCore \
		-I$(BUILD_WORK)/ksyntaxhighlighting/src/lib \
		$(BUILD_WORK)/ksyntaxhighlighting/src/indexer/katehighlightingindexer.cpp \
		$(BUILD_WORK)/ksyntaxhighlighting/src/lib/worddelimiters.cpp \
		-L$(QT6_HOST_PATH)/lib -Wl,-rpath,$(QT6_HOST_PATH)/lib -lQt6Core \
		-o $(BUILD_TOOLS)/ksyntaxhighlighting-host/katehighlightingindexer
	rm -rf $(BUILD_WORK)/ksyntaxhighlighting/build
	mkdir -p $(BUILD_WORK)/ksyntaxhighlighting/build
	cd $(BUILD_WORK)/ksyntaxhighlighting/build && cmake .. \
		-G Ninja \
		$(KF6_CMAKE_FLAGS) \
		-DKATEHIGHLIGHTINGINDEXER_EXECUTABLE=$(BUILD_TOOLS)/ksyntaxhighlighting-host/katehighlightingindexer \
		-DKSYNTAXHIGHLIGHTING_USE_GUI=ON \
		-DQRC_SYNTAX=ON \
		-DNO_STANDARD_PATHS=OFF \
		-DBUILD_QCH=OFF
	+ninja -C $(BUILD_WORK)/ksyntaxhighlighting/build
	+DESTDIR="$(BUILD_STAGE)/ksyntaxhighlighting" ninja -C $(BUILD_WORK)/ksyntaxhighlighting/build install
	$(call AFTER_BUILD,copy)
endif

ksyntaxhighlighting-package: ksyntaxhighlighting-stage
	rm -rf $(BUILD_DIST)/kf6-syntax-highlighting $(BUILD_DIST)/kf6-syntax-highlighting-dev
	$(call KF6_COPY_RUNTIME,ksyntaxhighlighting,kf6-syntax-highlighting)
	$(call KF6_COPY_DEV,ksyntaxhighlighting,kf6-syntax-highlighting)
	$(call SIGN,kf6-syntax-highlighting,general.xml)
	$(call PACK,kf6-syntax-highlighting,DEB_KSYNTAXHIGHLIGHTING_V)
	$(call PACK,kf6-syntax-highlighting-dev,DEB_KSYNTAXHIGHLIGHTING_V)
	rm -rf $(BUILD_DIST)/kf6-syntax-highlighting $(BUILD_DIST)/kf6-syntax-highlighting-dev

.PHONY: ksyntaxhighlighting ksyntaxhighlighting-package
