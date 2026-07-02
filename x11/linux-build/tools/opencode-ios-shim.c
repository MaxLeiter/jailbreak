#include <libkern/OSCacheControl.h>

void __clear_cache(void *start, void *end) {
  sys_icache_invalidate(start, (char *)end - (char *)start);
}

void pthread_jit_write_protect_np(int enabled) {
  (void)enabled;
}

int pthread_jit_write_protect_supported_np(void) {
  return 0;
}
