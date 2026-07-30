# Procursus cross-build environment for iphoneos-arm64 (rootless, CFVER 1900 / iOS 16).
# Built natively for the host arch (arm64 on Apple Silicon) — no qemu emulation.
# The toolchain layer is heavy but cacheable; the actual package build runs via
# build.sh at `docker run` time so patches can be iterated without rebuilding this.
FROM debian:bookworm

ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-c"]

# Procursus build deps + cctools-port/ldid build deps (Debian-native GNU userland).
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential clang llvm-dev libclang-dev cmake ninja-build \
      git curl wget ca-certificates \
      autoconf automake autopoint libtool-bin bison flex gawk gperf \
      gnupg po4a docbook-xsl docbook-xml groff gzip xz-utils zstd bzip2 \
      pkg-config python3 python3-pip python3-setuptools \
      libssl-dev libxml2-dev uuid-dev zlib1g-dev libplist-dev \
      fakeroot dpkg-dev rsync patch m4 file sudo bash \
  && rm -rf /var/lib/apt/lists/*

# triehash (Procursus requires it; Julian Klode's perl script, also used by APT).
RUN if ! command -v triehash >/dev/null 2>&1; then \
      curl -fsSL -o /usr/local/bin/triehash \
        https://raw.githubusercontent.com/julian-klode/triehash/master/triehash.pl && \
      chmod +x /usr/local/bin/triehash; \
    fi

# ldid (ad-hoc Mach-O signing), from source.
RUN git clone --depth 1 https://github.com/ProcursusTeam/ldid /tmp/ldid && \
    make -C /tmp/ldid -j"$(nproc)" && install -m0755 /tmp/ldid/ldid /usr/local/bin/ldid && \
    rm -rf /tmp/ldid

# cctools-port cross toolchain (aarch64-apple-darwin), using YOUR staged iOS SDK.
# run.sh copies $THEOS/sdks/iPhoneOS16.5.sdk -> ./sdk/iPhoneOS.sdk before building.
COPY sdk/iPhoneOS.sdk /tmp/iPhoneOS16.5.sdk
RUN tar -C /tmp -czf /tmp/iPhoneOS16.5.sdk.tar.gz iPhoneOS16.5.sdk && \
    git clone --depth 1 https://github.com/tpoechtrager/cctools-port /tmp/cctools-port && \
    cd /tmp/cctools-port/usage_examples/ios_toolchain && \
    sed -i 's/arm-apple-darwin11/aarch64-apple-darwin/g' build.sh && \
    ./build.sh /tmp/iPhoneOS16.5.sdk.tar.gz arm64 && \
    mkdir -p /root/cctools && \
    cp -a target/. /root/cctools/ && \
    cd /root/cctools/SDK && \
    ln -sf "$(ls -d iPhoneOS*.sdk | head -1)" iPhoneOS.sdk && \
    ln -sf iPhoneOS.sdk MacOSX.sdk && \
    rm -rf /tmp/cctools-port /tmp/iPhoneOS16.5.sdk /tmp/iPhoneOS16.5.sdk.tar.gz
ENV PATH="/root/cctools/bin:${PATH}"
ENV LD_LIBRARY_PATH="/root/cctools/lib"

# Real macOS SDK — Procursus's `setup` harvests framework/legacy headers from it
# (FSEvents, Kernel, IOKit, Security, sys/ttydev.h, ...). Replace the iOS-SDK stub
# symlink with the staged macOS SDK. (Separate layer; keeps the cctools layer cached.)
COPY sdk/MacOSX.sdk /opt/MacOSX.sdk
RUN rm -f /root/cctools/SDK/MacOSX.sdk && ln -s /opt/MacOSX.sdk /root/cctools/SDK/MacOSX.sdk

# mesa's build system (meson) + its codegen templating (python3-mako). Added late so
# the heavy cctools/SDK layers stay cached.
RUN apt-get update && apt-get install -y --no-install-recommends meson python3-mako \
  && rm -rf /var/lib/apt/lists/*

# Modern clang (clang-19) from apt.llvm.org. Debian bookworm's stock clang is ~14,
# too old for C++23 codebases like Ladybird (needs clang >= 19). This adds ONLY a
# newer compiler front end; the cross toolchain is unchanged — cctools-port `ld64`
# stays the linker and the staged iPhoneOS16.5.sdk stays the sysroot. Cross-compiles
# drive it as `clang-19 --target=arm64-apple-ios<v> -isysroot <sdk> ...`. The existing
# `aarch64-apple-darwin-clang` cctools wrapper (clang-14 based) is left in place for
# the rest of the project. Placed last so it never busts the heavy cctools/SDK layers.
RUN apt-get update && apt-get install -y --no-install-recommends lsb-release wget software-properties-common gnupg \
  && wget -qO /tmp/llvm.sh https://apt.llvm.org/llvm.sh \
  && chmod +x /tmp/llvm.sh \
  && /tmp/llvm.sh 19 \
  && rm -f /tmp/llvm.sh \
  && clang-19 --version \
  && rm -rf /var/lib/apt/lists/*

# Target-matrix defaults for the container-side build scripts. Baking it in means
# a bare `docker run ... /work/build-foo.sh` still resolves the build_base/work/
# stage/dist paths without the caller having to mount anything; the host wrappers
# bind-mount over it so edits here take effect without an image rebuild. Last
# layer — it is 3 KB and changes far more often than the toolchain above it.
COPY target-env.sh /work/target-env.sh

WORKDIR /work
ENTRYPOINT ["/bin/bash"]
