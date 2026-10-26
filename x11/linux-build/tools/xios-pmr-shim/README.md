# xios-pmr-shim

`std::pmr` (memory_resource, monotonic_buffer_resource, unsynchronized/synchronized_pool_resource,
new_delete_resource, get_default_resource ...) landed in Apple's libc++ DYLIB with iOS 17. Our SDK and device floor
are the iPhoneOS 16.5 libc++, so the out-of-line pmr symbols are missing at link time even though the LLVM-19
libc++ HEADERS (libc++ "mode B") compile pmr code happily. KF6, Kate and other KDE code uses std::pmr widely.

This directory holds the one upstream translation unit that defines those symbols, unmodified:
`memory_resource.cpp` + `memory_resource_init_helper.h` from LLVM 19.1.7 `libcxx/src` (Apache-2.0 WITH
LLVM-exception, see LICENSE.TXT). `build.sh` compiles it into a STATIC archive, `libxios-pmr.a`, in the build volume.

Rules (agreed with main):
- static only, KDE lane only (wired in `kde-lane-env.sh` via `kde_lane_pmr_setup`, NOT in xios-clang19-env.sh);
- linked with ld64's `-hidden-lxios-pmr`, so every symbol it provides is private to the image that pulls it in:
  no KDE dylib re-exports std::pmr (verify: `nm -gU <dylib> | grep pmr` prints nothing);
- nothing ships as a dylib and nothing shadows a base-system package.
