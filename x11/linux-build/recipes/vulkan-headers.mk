ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# vulkan-headers.mk - Khronos Vulkan headers (header-only). KWin 6.7 compiles its Vulkan render path (vulkan_raii.hpp)
# unconditionally; the nested iOS backend never creates a Vulkan device, so headers are all that is needed at build time
# (vk::raii::Context dlopens the loader lazily; there is no loader on iOS and none is shipped). Build-time-only package.

SUBPROJECTS += vulkan-headers
VULKANHEADERS_VERSION := 1.4.328
DEB_VULKANHEADERS_V   ?= $(VULKANHEADERS_VERSION)+ios1

vulkan-headers-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://github.com/KhronosGroup/Vulkan-Headers/archive/refs/tags/v$(VULKANHEADERS_VERSION).tar.gz)
	$(call EXTRACT_TAR,v$(VULKANHEADERS_VERSION).tar.gz,Vulkan-Headers-$(VULKANHEADERS_VERSION),vulkan-headers)

ifneq ($(wildcard $(BUILD_WORK)/vulkan-headers/.build_complete),)
vulkan-headers:
	@echo "Using previously built vulkan-headers."
else
vulkan-headers: vulkan-headers-setup
	rm -rf $(BUILD_WORK)/vulkan-headers/build
	mkdir -p $(BUILD_WORK)/vulkan-headers/build
	cd $(BUILD_WORK)/vulkan-headers/build && cmake .. -G Ninja $(DEFAULT_CMAKE_FLAGS)
	DESTDIR="$(BUILD_STAGE)/vulkan-headers" ninja -C $(BUILD_WORK)/vulkan-headers/build install
	$(call AFTER_BUILD,copy)
endif

vulkan-headers-package: vulkan-headers-stage
	rm -rf $(BUILD_DIST)/vulkan-headers
	mkdir -p $(BUILD_DIST)/vulkan-headers/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/vulkan-headers/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/. $(BUILD_DIST)/vulkan-headers/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/
	$(call PACK,vulkan-headers,DEB_VULKANHEADERS_V)
	rm -rf $(BUILD_DIST)/vulkan-headers

.PHONY: vulkan-headers vulkan-headers-package
