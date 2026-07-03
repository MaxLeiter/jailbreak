ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# qcoro.mk - QCoro 6 for rootless iOS (Plasma Desktop shell-layer support).
# plasma-workspace 6.1.5 hard-requires QCoro6 Core+DBus. Keep this package
# narrow for first-light: no QtQuick/QML/WebSockets/examples/tests.

SUBPROJECTS += qcoro
QCORO_VERSION = 0.10.0
DEB_QCORO_V ?= $(QCORO_VERSION)+ios1

qcoro-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://github.com/danvratil/qcoro/archive/refs/tags/v$(QCORO_VERSION).tar.gz)
	$(call EXTRACT_TAR,v$(QCORO_VERSION).tar.gz,qcoro-$(QCORO_VERSION),qcoro)
	$(call QT6_WRITE_IOSEXEC_FIXUP)
	$(call QT6_RM_SHADOW_HEADERS)

ifneq ($(wildcard $(BUILD_WORK)/qcoro/.build_complete),)
qcoro:
	@echo "Using previously built qcoro."
else
qcoro: qcoro-setup
	rm -rf $(BUILD_WORK)/qcoro/build
	mkdir -p $(BUILD_WORK)/qcoro/build
	cd $(BUILD_WORK)/qcoro/build && cmake .. \
		-G Ninja \
		$(KF6_CMAKE_FLAGS) \
		-DUSE_QT_VERSION=6 \
		-DQCORO_BUILD_EXAMPLES=OFF \
		-DBUILD_TESTING=OFF \
		-DQCORO_WITH_QTDBUS=ON \
		-DQCORO_WITH_QTNETWORK=OFF \
		-DQCORO_WITH_QTWEBSOCKETS=OFF \
		-DQCORO_WITH_QTQUICK=OFF \
		-DQCORO_WITH_QML=OFF \
		-DQCORO_WITH_QTTEST=OFF
	+ninja -C $(BUILD_WORK)/qcoro/build
	+DESTDIR="$(BUILD_STAGE)/qcoro" ninja -C $(BUILD_WORK)/qcoro/build install
	$(call AFTER_BUILD,copy)
endif

qcoro-package: qcoro-stage
	rm -rf $(BUILD_DIST)/qcoro6 $(BUILD_DIST)/qcoro6-dev
	$(call KF6_COPY_RUNTIME,qcoro,qcoro6)
	$(call KF6_COPY_DEV,qcoro,qcoro6)
	$(call SIGN,qcoro6,general.xml)
	$(call SIGN,qcoro6-dev,general.xml)
	$(call PACK,qcoro6,DEB_QCORO_V)
	$(call PACK,qcoro6-dev,DEB_QCORO_V)
	rm -rf $(BUILD_DIST)/qcoro6 $(BUILD_DIST)/qcoro6-dev

.PHONY: qcoro qcoro-package
