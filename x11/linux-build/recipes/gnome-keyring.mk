ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# Secret Service provider for Geary and other GTK applications. The iOS port
# only needs the D-Bus secrets component; PAM, SSH agent, systemd, Linux
# capabilities and SELinux integration are deliberately disabled.

SUBPROJECTS              += gnome-keyring
GNOME_KEYRING_MAJOR_V     := 46
GNOME_KEYRING_VERSION     := 46.2
DEB_GNOME_KEYRING_V       ?= $(GNOME_KEYRING_VERSION)+ios1

gnome-keyring-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/gnome-keyring/$(GNOME_KEYRING_MAJOR_V)/gnome-keyring-$(GNOME_KEYRING_VERSION).tar.xz)
	$(call EXTRACT_TAR,gnome-keyring-$(GNOME_KEYRING_VERSION).tar.xz,gnome-keyring-$(GNOME_KEYRING_VERSION),gnome-keyring)

ifneq ($(wildcard $(BUILD_WORK)/gnome-keyring/.build_complete),)
gnome-keyring:
	@echo "Using previously built gnome-keyring."
else
gnome-keyring: gnome-keyring-setup
	cd $(BUILD_WORK)/gnome-keyring && ./configure -C \
		$(DEFAULT_CONFIGURE_FLAGS) \
		--disable-static \
		--disable-pam \
		--disable-ssh-agent \
		--without-libcap-ng \
		--disable-selinux \
		--without-systemd \
		--disable-p11-tests \
		--disable-doc \
		--disable-coverage \
		--disable-valgrind
	+$(MAKE) -C $(BUILD_WORK)/gnome-keyring
	+$(MAKE) -C $(BUILD_WORK)/gnome-keyring install DESTDIR=$(BUILD_STAGE)/gnome-keyring
	$(call AFTER_BUILD,copy)
endif

gnome-keyring-package: gnome-keyring-stage
	rm -rf $(BUILD_DIST)/gnome-keyring
	mkdir -p $(BUILD_DIST)/gnome-keyring/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/gnome-keyring/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/. \
		$(BUILD_DIST)/gnome-keyring/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/
	rm -rf $(BUILD_DIST)/gnome-keyring/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/doc \
		$(BUILD_DIST)/gnome-keyring/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/man
	for f in $$(find $(BUILD_DIST)/gnome-keyring -type f); do \
		if file "$$f" | grep -q "Mach-O"; then \
			$(I_N_T) -add_rpath $(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib "$$f" 2>/dev/null || true; \
			$(I_N_T) -add_rpath @loader_path "$$f" 2>/dev/null || true; \
		fi; \
	done
	$(call SIGN,gnome-keyring,general.xml)
	$(call PACK,gnome-keyring,DEB_GNOME_KEYRING_V)
	rm -rf $(BUILD_DIST)/gnome-keyring

.PHONY: gnome-keyring gnome-keyring-package
