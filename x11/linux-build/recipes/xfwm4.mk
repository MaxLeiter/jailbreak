ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# xfwm4 — the XFCE window manager. libwnck3 is a HARD dep. Compositor is DISABLED for
# first bring-up (our DDX has no X Composite/GLX yet — SCOPE Stage 3); re-enable later.
# BLOCKED on the GTK3 stack.
SUBPROJECTS   += xfwm4
XFWM4_MAJOR_V := 4.16
XFWM4_VERSION := $(XFWM4_MAJOR_V).1
DEB_XFWM4_V   ?= $(XFWM4_VERSION)+ios1

xfwm4-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://archive.xfce.org/src/xfce/xfwm4/$(XFWM4_MAJOR_V)/xfwm4-$(XFWM4_VERSION).tar.bz2)
	$(call EXTRACT_TAR,xfwm4-$(XFWM4_VERSION).tar.bz2,xfwm4-$(XFWM4_VERSION),xfwm4)

ifneq ($(wildcard $(BUILD_WORK)/xfwm4/.build_complete),)
xfwm4:
	@echo "Using previously built xfwm4."
else
xfwm4: xfwm4-setup gtk+3.0 libxfce4util libxfce4ui xfconf libwnck3 startup-notification libepoxy
	cd $(BUILD_WORK)/xfwm4 && ./configure -C \
		$(DEFAULT_CONFIGURE_FLAGS) \
		--disable-static \
		--disable-gtk-doc \
		--disable-debug \
		--disable-compositor \
		--enable-startup-notification
	+$(MAKE) -C $(BUILD_WORK)/xfwm4
	+$(MAKE) -C $(BUILD_WORK)/xfwm4 install DESTDIR=$(BUILD_STAGE)/xfwm4
	$(call AFTER_BUILD,copy)
endif

xfwm4-package: xfwm4-stage
	rm -rf $(BUILD_DIST)/xfwm4
	mkdir -p $(BUILD_DIST)/xfwm4
	cp -a $(BUILD_STAGE)/xfwm4/$(MEMO_PREFIX) $(BUILD_DIST)/xfwm4/

	rm -rf $(BUILD_DIST)/xfwm4/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/xfwm4/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig \
		$(BUILD_DIST)/xfwm4/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/*.a \
		$(BUILD_DIST)/xfwm4/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/gtk-doc

	$(call SIGN,xfwm4,general.xml)
	$(call PACK,xfwm4,DEB_XFWM4_V)
	rm -rf $(BUILD_DIST)/xfwm4

.PHONY: xfwm4 xfwm4-package
