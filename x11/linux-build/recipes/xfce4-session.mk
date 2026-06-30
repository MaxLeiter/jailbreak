ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# xfce4-session — XFCE session manager (xfce4-session + xfce4-session-logout etc).
# Uses libSM/libICE (in Procursus). logind/ConsoleKit/polkit/upower are absent (we launch
# components directly, not via a seat) and auto-disable. BLOCKED on the GTK3 stack.
SUBPROJECTS          += xfce4-session
XFCE4SESSION_MAJOR_V := 4.16
XFCE4SESSION_VERSION := $(XFCE4SESSION_MAJOR_V).0
DEB_XFCE4SESSION_V   ?= $(XFCE4SESSION_VERSION)

xfce4-session-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://archive.xfce.org/src/xfce/xfce4-session/$(XFCE4SESSION_MAJOR_V)/xfce4-session-$(XFCE4SESSION_VERSION).tar.bz2)
	$(call EXTRACT_TAR,xfce4-session-$(XFCE4SESSION_VERSION).tar.bz2,xfce4-session-$(XFCE4SESSION_VERSION),xfce4-session)

ifneq ($(wildcard $(BUILD_WORK)/xfce4-session/.build_complete),)
xfce4-session:
	@echo "Using previously built xfce4-session."
else
xfce4-session: xfce4-session-setup gtk+3.0 libxfce4util libxfce4ui xfconf libsm libice
	cd $(BUILD_WORK)/xfce4-session && ./configure -C \
		$(DEFAULT_CONFIGURE_FLAGS) \
		--disable-static \
		--disable-gtk-doc \
		--disable-debug \
		--disable-legacy-sm
	+$(MAKE) -C $(BUILD_WORK)/xfce4-session
	+$(MAKE) -C $(BUILD_WORK)/xfce4-session install DESTDIR=$(BUILD_STAGE)/xfce4-session
	$(call AFTER_BUILD,copy)
endif

xfce4-session-package: xfce4-session-stage
	rm -rf $(BUILD_DIST)/xfce4-session
	mkdir -p $(BUILD_DIST)/xfce4-session
	cp -a $(BUILD_STAGE)/xfce4-session/$(MEMO_PREFIX) $(BUILD_DIST)/xfce4-session/

	rm -rf $(BUILD_DIST)/xfce4-session/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/xfce4-session/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig \
		$(BUILD_DIST)/xfce4-session/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/*.a \
		$(BUILD_DIST)/xfce4-session/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/gtk-doc

	$(call SIGN,xfce4-session,general.xml)
	$(call PACK,xfce4-session,DEB_XFCE4SESSION_V)
	rm -rf $(BUILD_DIST)/xfce4-session

.PHONY: xfce4-session xfce4-session-package
