ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# Links-only shim: libei/libeis are Linux-only (evdev/uinput/eventfd), but Mutter compiles
# its input-capture backend unconditionally and links libeis regardless of that. Ships
# libei's real headers plus no-op stubs of the referenced eis_* symbols so libmutter links.
# Input capture / remote-desktop input is non-functional here; same pattern as the libdrm shim.

SUBPROJECTS  += libei
LIBEI_VERSION := 1.3.0
DEB_LIBEI_V   ?= $(LIBEI_VERSION)+ios1

# eis_* symbols Mutter's unconditional input-capture files reference (grep of meta-input-capture*.c).
EIS_SYMS := eis_backend_fd_add_client eis_client_connect eis_client_disconnect eis_client_get_name \
  eis_client_is_sender eis_client_new_seat eis_client_ref eis_device_add eis_device_button_button \
  eis_device_configure_capability eis_device_configure_name eis_device_frame eis_device_keyboard_key \
  eis_device_new_keymap eis_device_new_region eis_device_pointer_motion eis_device_remove \
  eis_device_resume eis_device_scroll_delta eis_device_scroll_discrete eis_device_scroll_stop \
  eis_device_start_emulating eis_device_stop_emulating eis_dispatch eis_event_get_client \
  eis_event_get_device eis_event_get_type eis_event_seat_has_capability eis_event_unref eis_get_event \
  eis_get_fd eis_keymap_add eis_keymap_unref eis_log_set_handler eis_log_set_priority eis_new eis_now \
  eis_peek_event eis_region_add eis_region_set_offset eis_region_set_physical_scale eis_region_set_size \
  eis_region_unref eis_seat_add eis_seat_configure_capability eis_seat_new_device eis_setup_backend_fd \
  eis_unref eis_client_unref eis_device_unref eis_seat_unref eis_device_ref eis_seat_ref eis_client_seat_ref

libei-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://gitlab.freedesktop.org/libinput/libei/-/archive/$(LIBEI_VERSION)/libei-$(LIBEI_VERSION).tar.gz)
	$(call EXTRACT_TAR,libei-$(LIBEI_VERSION).tar.gz,libei-$(LIBEI_VERSION),libei)

ifneq ($(wildcard $(BUILD_WORK)/libei/.build_complete),)
libei:
	@echo "Using previously built libei (shim)."
else
libei: libei-setup
	rm -rf $(BUILD_STAGE)/libei
	mkdir -p $(BUILD_STAGE)/libei$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/{include,lib/pkgconfig}
	# install REAL libei public headers (libei.h/libeis.h/liboeffis.h are hand-written in src/)
	cp -a $(BUILD_WORK)/libei/src/libei.h $(BUILD_WORK)/libei/src/libeis.h \
		$(BUILD_STAGE)/libei$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/ 2>/dev/null || true
	cp -a $(BUILD_WORK)/libei/src/liboeffis.h $(BUILD_STAGE)/libei$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/ 2>/dev/null || true
	# links-only stub libeis.dylib with the eis_* symbols mutter references
	printf '/* iOS links-only stub: input capture inert (remote-desktop only). */\n' \
		> $(BUILD_WORK)/libei/eis_stub.c
	for s in $(EIS_SYMS); do echo "long $$s(){return 0;}" >> $(BUILD_WORK)/libei/eis_stub.c; done
	$(CC) -dynamiclib -install_name @rpath/libeis.dylib \
		-current_version $(LIBEI_VERSION) -compatibility_version 1.0.0 \
		-o $(BUILD_STAGE)/libei$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libeis.dylib \
		$(BUILD_WORK)/libei/eis_stub.c
	# pc so dependency('libeis-1.0', version: '>= 1.0.901') resolves
	printf 'prefix=$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)\nlibdir=$${prefix}/lib\nincludedir=$${prefix}/include\n\nName: libeis\nDescription: iOS links-only shim (input capture inert)\nVersion: $(LIBEI_VERSION)\nLibs: -L$${libdir} -leis\nCflags: -I$${includedir}\n' \
		> $(BUILD_STAGE)/libei$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig/libeis-1.0.pc
	$(call AFTER_BUILD,copy)
endif

.PHONY: libei
