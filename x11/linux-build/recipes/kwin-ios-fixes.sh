#!/usr/bin/env bash
set -euo pipefail

src=${1:?usage: kwin-ios-fixes.sh <kwin-source-dir>}

# No host Qt LinguistTools in this bring-up stack.
sed -i '/^[[:space:]]*ecm_install_po_files_as_qm(/s/^/# ios-bringup-no-linguist: /' "$src/CMakeLists.txt"

# First-light target: nested Wayland compositor. Keep Linux-only dependencies out of
# feature_summary and avoid probing X11 as a required package when KWIN_BUILD_X11=OFF.
perl -0pi -e 's/set_package_properties\(Libinput PROPERTIES TYPE REQUIRED/set_package_properties(Libinput PROPERTIES TYPE OPTIONAL/g' "$src/CMakeLists.txt"
perl -0pi -e 's/TYPE REQUIRED\n([ \t]*PURPOSE "Required for input handling on Wayland\."\n\))/TYPE OPTIONAL\n$1/g' "$src/CMakeLists.txt"
perl -0pi -e 's/find_package\(X11\)\nset_package_properties\(X11 PROPERTIES\n    DESCRIPTION "X11 libraries"\n    URL "https:\/\/www\.x\.org"\n    TYPE REQUIRED\n\)/find_package(X11)\nset_package_properties(X11 PROPERTIES\n    DESCRIPTION "X11 libraries"\n    URL "https:\/\/www.x.org"\n    TYPE OPTIONAL\n)/g' "$src/CMakeLists.txt"
sed -i '/^[[:space:]]*UDev::UDev[[:space:]]*$/d' "$src/src/CMakeLists.txt"

# Only the nested Wayland and fake-input backends are useful on iOS right now. The
# DRM/libinput/virtual backends pull Linux kernel APIs that cannot work on-device.
cat > "$src/src/backends/CMakeLists.txt" <<'EOF'
add_subdirectory(fakeinput)
add_subdirectory(wayland)

if (KWIN_BUILD_X11)
    add_subdirectory(x11)
endif()
EOF

# The nested Wayland backend still includes DRM fourcc helpers and opens a DRM render
# node when the host compositor advertises linux-dmabuf. Link the inert libdrm/gbm
# shims and epoll-shim's eventfd provider for the shared kwin library.
cat > "$src/src/backends/wayland/CMakeLists.txt" <<'EOF'
target_sources(kwin PRIVATE
    wayland_backend.cpp
    wayland_display.cpp
    wayland_egl_backend.cpp
    wayland_logging.cpp
    wayland_output.cpp
    wayland_qpainter_backend.cpp
)

find_library(EPOLL_SHIM_LIBRARY epoll-shim)
target_link_libraries(kwin PRIVATE Plasma::KWaylandClient Wayland::Client gbm::gbm Libdrm::Libdrm)
if (EPOLL_SHIM_LIBRARY)
    target_link_libraries(kwin PRIVATE ${EPOLL_SHIM_LIBRARY})
endif()
EOF

# src/plugins/CMakeLists.txt is left as UPSTREAM ships it.
#
# It used to be overwritten with just qpa + kglobalaccel, to keep the static
# plugin surface small "until the compositor itself runs". The compositor runs
# now (GL compositing through ANGLE/IOSurface), and that reduction was why the
# kwin deb contained no effects, no scripts and no decoration plugin at all --
# every one of the ~70 subdirectories below qpa was simply never configured.
#
# Upstream's own file already guards the parts that genuinely cannot build here:
# screencast behind PipeWire_FOUND (absent), krunner-integration behind
# KWIN_BUILD_RUNNERS (OFF), eis behind KWIN_BUILD_EIS (OFF), kdecorations behind
# KWIN_BUILD_DECORATIONS (ON, which is what supplies the decoration plugin). So
# let cmake's conditionals decide rather than hand-maintaining a subset list;
# anything that fails to compile on iOS gets pruned individually, with a reason.

# KWin's private QPA plugin must include Qt's real QOpenGL/QPA classes. epoxy's
# EGL header includes epoxy/gl.h, whose GL macro layer collides with QtGui's iOS
# OpenGLES headers, so use the plain ANGLE/Khronos EGL headers in QPA only.
for f in \
    "$src/src/plugins/qpa/eglhelpers.h" \
    "$src/src/plugins/qpa/eglplatformcontext.h" \
    "$src/src/plugins/qpa/integration.h" \
    "$src/src/plugins/qpa/offscreensurface.h"; do
    sed -i 's@#include <epoxy/egl.h>@#include <EGL/egl.h>@' "$f"
done

# First-light keeps the private QPA plugin on the raster/backing-store path.
# The QPA OpenGL context code mixes QtGui's iOS OpenGLES private headers with
# KWin's libepoxy OpenGL wrappers in the same translation units. That is a
# separate GL polish track; the compositor can still boot nested Wayland with
# QPainter surfaces while the main kwin binary keeps the GPU entitlements.
perl -0pi -e 's/[ \t]*eglhelpers\.cpp\n//g; s/[ \t]*eglplatformcontext\.cpp\n//g' "$src/src/plugins/qpa/CMakeLists.txt"
perl -0pi -e 's/#include <EGL\/egl\.h>\n\n//g' "$src/src/plugins/qpa/integration.h"
perl -0pi -e 's/#include "eglplatformcontext\.h"\n//g; s/#include "core\/outputbackend\.h"\n//g; s/#include <QtGui\/private\/qgenericunixthemes_p\.h>\n//g' "$src/src/plugins/qpa/integration.cpp"
perl -0pi -e 's/case OpenGL:\n        return true;/case OpenGL:\n        return false;/g' "$src/src/plugins/qpa/integration.cpp"
perl -0pi -e 's/QPlatformTheme \*Integration::createPlatformTheme\(const QString &name\) const\n\{\n    return QGenericUnixTheme::createUnixTheme\(name\);\n\}/QPlatformTheme *Integration::createPlatformTheme(const QString \&name) const\n{\n    Q_UNUSED(name)\n    return nullptr;\n}/g' "$src/src/plugins/qpa/integration.cpp"
perl -0pi -e 's/QStringList Integration::themeNames\(\) const\n\{\n    if \(qEnvironmentVariableIsSet\("KDE_FULL_SESSION"\)\) \{\n        return QStringList\(\{QStringLiteral\("kde"\)\}\);\n    \}\n    return QStringList\(\{QLatin1String\(QGenericUnixTheme::name\)\}\);\n\}/QStringList Integration::themeNames() const\n{\n    return {};\n}/g' "$src/src/plugins/qpa/integration.cpp"
perl -0pi -e 's/QPlatformOpenGLContext \*Integration::createPlatformOpenGLContext\(QOpenGLContext \*context\) const\n\{\n    if \(kwinApp\(\)->outputBackend\(\)->sceneEglGlobalShareContext\(\) == EGL_NO_CONTEXT\) \{\n        qCWarning\(KWIN_QPA\) << "Attempting to create a QOpenGLContext before the scene is initialized";\n        return nullptr;\n    \}\n    const auto eglDisplay = kwinApp\(\)->outputBackend\(\)->sceneEglDisplayObject\(\);\n    if \(eglDisplay\) \{\n        EGLPlatformContext \*platformContext = new EGLPlatformContext\(context, eglDisplay\);\n        return platformContext;\n    \}\n    return nullptr;\n\}/QPlatformOpenGLContext *Integration::createPlatformOpenGLContext(QOpenGLContext *context) const\n{\n    Q_UNUSED(context)\n    qCWarning(KWIN_QPA) << "QPA OpenGL contexts are disabled on the iOS first-light build";\n    return nullptr;\n}/g' "$src/src/plugins/qpa/integration.cpp"
perl -0pi -e 's/#include "core\/outputbackend\.h"\n//g; s/#include "main\.h"\n//g; s/#include "opengl\/egldisplay\.h"\n//g' "$src/src/plugins/qpa/offscreensurface.cpp"
perl -0pi -e 's@// this needs to be on top, epoxy has an error if you include it after GL/gl.h,\n// which Qt does include\n#include "utils/drm_format_helper\.h"\n\n@@g; s/#include "core\/drmdevice\.h"\n//g; s/#include "core\/renderbackend\.h"\n//g' "$src/src/plugins/qpa/window.cpp"
perl -0pi -e 's/        GraphicsBufferAllocator \*allocator;\n        if \(software\) \{\n            static ShmGraphicsBufferAllocator shmAllocator;\n            allocator = \&shmAllocator;\n        \} else \{\n            allocator = Compositor::self\(\)->backend\(\)->drmDevice\(\)->allocator\(\);\n        \}\n\n        for \(auto it = formats\.begin\(\); it != formats\.end\(\); it\+\+\) \{\n            if \(auto info = FormatInfo::get\(it\.key\(\)\); info && info->bitsPerColor == 8 && info->alphaBits == 8\) \{\n                const auto options = GraphicsBufferOptions\{\n                    \.size = nativeSize,\n                    \.format = it\.key\(\),\n                    \.modifiers = it\.value\(\),\n                    \.software = software,\n                \};\n                auto buffer = allocator->allocate\(options\);\n                if \(!buffer\) \{\n                    continue;\n                \}\n                m_swapchain = std::make_unique<Swapchain>\(allocator, options, buffer\);\n                m_eglContext = context;\n                break;\n            \}\n        \}/        if (!software) {\n            qCWarning(KWIN_QPA) << "QPA OpenGL windows are disabled on the iOS first-light build";\n            return nullptr;\n        }\n\n        static ShmGraphicsBufferAllocator shmAllocator;\n        GraphicsBufferAllocator *allocator = \&shmAllocator;\n        const auto modifiers = formats.value(DRM_FORMAT_ARGB8888, {DRM_FORMAT_MOD_LINEAR});\n        const auto options = GraphicsBufferOptions{\n            .size = nativeSize,\n            .format = DRM_FORMAT_ARGB8888,\n            .modifiers = modifiers,\n            .software = true,\n        };\n        auto buffer = allocator->allocate(options);\n        if (buffer) {\n            m_swapchain = std::make_unique<Swapchain>(allocator, options, buffer);\n            m_eglContext = context;\n        }/g' "$src/src/plugins/qpa/window.cpp"

# The killer helper includes private Qt X11 headers unconditionally. It is not on the
# critical compositor path, so drop it for the iOS first-light build.
cat > "$src/src/helpers/CMakeLists.txt" <<'EOF'
add_subdirectory(wayland_wrapper)
EOF

# Decorations are part of the supported KDE Desktop path now. Keep upstream's
# runtime default so KWin loads the configured decoration plugin unless the user
# explicitly sets NoPlugin=true.

# Upstream's native qtwaylandscanner_kde helper guesses KF6_HOST_TOOLING as the complete
# host prefix. Our host Qt lives beside it, so let the recipe pass NATIVE_PREFIX explicitly.

# GL-enabled build: libkwin now compiles WITH Qt OpenGL. The former
# target_compile_definitions(kwin PRIVATE QT_NO_OPENGL=1) blunt disable is gone; the
# epoxy<->QtGui-GLES header collision is resolved by the ios-bringup-gl-coexist shim in
# kwin-ios-compat.h, ENABLED only on the kwin library target so CMake's GLESv2 probes
# stay clean. Strip any stale QT_NO_OPENGL from an older tree, then scope-enable the shim.
perl -0pi -e 's/^target_compile_definitions\(kwin PRIVATE QT_NO_OPENGL=1\).*# ios-bringup-target-no-qt-opengl\n//mg' "$src/src/CMakeLists.txt"
if ! grep -q 'ios-bringup-gl-coexist-target' "$src/src/CMakeLists.txt"; then
    perl -0pi -e 's/add_library\(kwin SHARED\)/add_library(kwin SHARED)\ntarget_compile_definitions(kwin PRIVATE KWIN_IOS_GL_COEXIST=1) # ios-bringup-gl-coexist-target/g' "$src/src/CMakeLists.txt"
fi

# iOS/ANGLE clients use the local iosc_iosurface protocol instead of dma-buf.
# For KWin first-light, expose the global and wrap imported IOSurfaces as a
# CPU-readable GraphicsBuffer so the existing QPainter compositor can copy them.
cp /work/recipes/build_info/iosc-iosurface.xml "$src/src/wayland/protocols/iosc-iosurface.xml"
if ! grep -q 'ios-bringup-iosurface-protocol' "$src/src/wayland/CMakeLists.txt"; then
    perl -0pi -e 's/target_sources\(kwin PRIVATE/ecm_add_qtwayland_server_protocol_kde(WaylandProtocols_xml\n    PROTOCOL \${PROJECT_SOURCE_DIR}\/src\/wayland\/protocols\/iosc-iosurface.xml\n    BASENAME iosc-iosurface\n) # ios-bringup-iosurface-protocol\n\ntarget_sources(kwin PRIVATE\n    ioscclientbuffer.cpp/g' "$src/src/wayland/CMakeLists.txt"
fi
if ! grep -q 'ios-bringup-iosurface-display' "$src/src/wayland/display.cpp"; then
    perl -0pi -e 's/#include "linuxdmabufv1clientbuffer_p\.h"/#include "linuxdmabufv1clientbuffer_p.h"\n#include "ioscclientbuffer.h" \/\/ ios-bringup-iosurface-display/g' "$src/src/wayland/display.cpp"
    perl -0pi -e 's/    new ShmClientBufferIntegration\(this\);/    new ShmClientBufferIntegration(this);\n    new IoscClientBufferIntegration(this); \/\/ ios-bringup-iosurface-display/g' "$src/src/wayland/display.cpp"
    perl -0pi -e 's/    \} else if \(auto buffer = ShmClientBuffer::get\(resource\)\) \{\n        return buffer;/    } else if (auto buffer = ShmClientBuffer::get(resource)) {\n        return buffer;\n    } else if (auto buffer = IoscClientBuffer::get(resource)) {\n        return buffer;/g' "$src/src/wayland/display.cpp"
fi
cat > "$src/src/wayland/ioscclientbuffer.h" <<'EOF'
/*
    iOS first-light support: iosc_iosurface client buffers for KWin.
    SPDX-License-Identifier: GPL-2.0-or-later
*/
#pragma once

#include "core/graphicsbuffer.h"

#include <QByteArray>
#include <QObject>
#include <wayland-server-protocol.h>

struct wl_client;
struct wl_resource;

namespace KWin
{

class Display;
class IoscClientBufferIntegrationPrivate;

class IoscClientBufferIntegration : public QObject
{
public:
    explicit IoscClientBufferIntegration(Display *display);
    ~IoscClientBufferIntegration() override;

private:
    std::unique_ptr<IoscClientBufferIntegrationPrivate> d;
};

class IoscClientBuffer : public GraphicsBuffer
{
public:
    IoscClientBuffer(void *iosurface, const QSize &size, uint32_t id, wl_client *client);
    ~IoscClientBuffer() override;

    Map map(MapFlags flags) override;
    void unmap() override;

    QSize size() const override;
    bool hasAlphaChannel() const override;
    const ShmAttributes *shmAttributes() const override;

    static IoscClientBuffer *get(wl_resource *resource);
    static const struct wl_buffer_interface implementation;

private:
    static void bufferDestroyResource(wl_resource *resource);
    static void bufferDestroy(wl_client *client, wl_resource *resource);

    wl_resource *m_resource = nullptr;
    void *m_iosurface = nullptr;
    ShmAttributes m_attributes;
    QByteArray m_flippedData;
};

} // namespace KWin
EOF
cat > "$src/src/wayland/ioscclientbuffer.cpp" <<'EOF'
/*
    iOS first-light support: iosc_iosurface client buffers for KWin.
    SPDX-License-Identifier: GPL-2.0-or-later
*/

#include "ioscclientbuffer.h"
#include "display.h"

#include "qwayland-server-iosc-iosurface.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOSurface/IOSurfaceRef.h>
#include <QDebug>
#include <drm_fourcc.h>
#include <mach/mach.h>
#include <cstring>
#include <wayland-server.h>
#include <wayland-server-protocol.h>

namespace KWin
{

static constexpr uint32_t xiosLockReadOnly = 0x00000001u;

static void *importClientIOSurface(int pid, uint32_t portName, int *width, int *height)
{
    task_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr != KERN_SUCCESS) {
        qWarning("kwin_iosurface: task_for_pid(%d) failed: 0x%x (%s)", pid, kr, mach_error_string(kr));
        return nullptr;
    }

    mach_port_t sendPort = MACH_PORT_NULL;
    mach_msg_type_name_t acquired = 0;
    kr = mach_port_extract_right(task, static_cast<mach_port_name_t>(portName), MACH_MSG_TYPE_COPY_SEND, &sendPort, &acquired);
    mach_port_deallocate(mach_task_self(), task);
    if (kr != KERN_SUCCESS) {
        qWarning("kwin_iosurface: mach_port_extract_right(pid=%d port=0x%x) failed: 0x%x (%s)", pid, portName, kr, mach_error_string(kr));
        return nullptr;
    }

    IOSurfaceRef surface = IOSurfaceLookupFromMachPort(sendPort);
    mach_port_deallocate(mach_task_self(), sendPort);
    if (!surface) {
        qWarning("kwin_iosurface: IOSurfaceLookupFromMachPort returned NULL");
        return nullptr;
    }

    if (width) {
        *width = static_cast<int>(IOSurfaceGetWidth(surface));
    }
    if (height) {
        *height = static_cast<int>(IOSurfaceGetHeight(surface));
    }
    qWarning("kwin_iosurface: imported client IOSurface id=%u %zux%zu stride=%zu",
             static_cast<unsigned>(IOSurfaceGetID(surface)),
             IOSurfaceGetWidth(surface),
             IOSurfaceGetHeight(surface),
             IOSurfaceGetBytesPerRow(surface));
    return surface;
}

class IoscClientBufferIntegrationPrivate : public QtWaylandServer::iosc_iosurface
{
public:
    explicit IoscClientBufferIntegrationPrivate(Display *display)
        : QtWaylandServer::iosc_iosurface(*display, 1)
    {
    }

protected:
    void iosc_iosurface_destroy(Resource *resource) override
    {
        wl_resource_destroy(resource->handle);
    }

    void iosc_iosurface_create_buffer(Resource *resource, uint32_t id, uint32_t machPortName, int32_t width, int32_t height, uint32_t format) override
    {
        Q_UNUSED(width)
        Q_UNUSED(height)
        Q_UNUSED(format)

        pid_t pid = 0;
        wl_client_get_credentials(resource->client(), &pid, nullptr, nullptr);

        int importedWidth = 0;
        int importedHeight = 0;
        void *surface = importClientIOSurface(static_cast<int>(pid), machPortName, &importedWidth, &importedHeight);
        if (!surface) {
            wl_resource *bufferResource = wl_resource_create(resource->client(), &::wl_buffer_interface, 1, id);
            if (!bufferResource) {
                wl_client_post_no_memory(resource->client());
                return;
            }
            wl_resource_set_implementation(bufferResource, &IoscClientBuffer::implementation, nullptr, nullptr);
            wl_resource_post_error(resource->handle, 0, "could not import IOSurface from mach port 0x%x", machPortName);
            return;
        }

        new IoscClientBuffer(surface, QSize(importedWidth, importedHeight), id, resource->client());
    }
};

const struct wl_buffer_interface IoscClientBuffer::implementation = {
    .destroy = bufferDestroy,
};

IoscClientBuffer::IoscClientBuffer(void *iosurface, const QSize &size, uint32_t id, wl_client *client)
    : m_iosurface(iosurface)
{
    const IOSurfaceRef surface = static_cast<IOSurfaceRef>(m_iosurface);
    m_attributes.stride = static_cast<int>(IOSurfaceGetBytesPerRow(surface));
    m_attributes.offset = 0;
    m_attributes.size = size;
    m_attributes.format = DRM_FORMAT_ARGB8888;

    connect(this, &GraphicsBuffer::released, [this]() {
        if (m_resource) {
            wl_buffer_send_release(m_resource);
        }
    });

    m_resource = wl_resource_create(client, &::wl_buffer_interface, 1, id);
    if (!m_resource) {
        wl_client_post_no_memory(client);
        drop();
        return;
    }
    wl_resource_set_implementation(m_resource, &implementation, this, bufferDestroyResource);
}

IoscClientBuffer::~IoscClientBuffer()
{
    if (m_iosurface) {
        CFRelease(static_cast<IOSurfaceRef>(m_iosurface));
    }
}

GraphicsBuffer::Map IoscClientBuffer::map(MapFlags flags)
{
    if (!m_iosurface || flags.testFlag(Write)) {
        return {};
    }
    IOSurfaceRef surface = static_cast<IOSurfaceRef>(m_iosurface);
    if (IOSurfaceLock(surface, xiosLockReadOnly, nullptr) != KERN_SUCCESS) {
        return {};
    }

    const size_t stride = IOSurfaceGetBytesPerRow(surface);
    const int height = m_attributes.size.height();
    const size_t byteCount = stride * static_cast<size_t>(height);
    m_flippedData.resize(static_cast<qsizetype>(byteCount));

    const auto *src = static_cast<const unsigned char *>(IOSurfaceGetBaseAddress(surface));
    auto *dst = reinterpret_cast<unsigned char *>(m_flippedData.data());
    for (int y = 0; y < height; ++y) {
        std::memcpy(dst + static_cast<size_t>(y) * stride,
                    src + static_cast<size_t>(height - 1 - y) * stride,
                    stride);
    }

    IOSurfaceUnlock(surface, xiosLockReadOnly, nullptr);
    return Map{
        .data = m_flippedData.data(),
        .stride = static_cast<uint32_t>(stride),
    };
}

void IoscClientBuffer::unmap()
{
}

QSize IoscClientBuffer::size() const
{
    return m_attributes.size;
}

bool IoscClientBuffer::hasAlphaChannel() const
{
    return true;
}

const ShmAttributes *IoscClientBuffer::shmAttributes() const
{
    return &m_attributes;
}

IoscClientBuffer *IoscClientBuffer::get(wl_resource *resource)
{
    if (wl_resource_instance_of(resource, &::wl_buffer_interface, &implementation)) {
        return static_cast<IoscClientBuffer *>(wl_resource_get_user_data(resource));
    }
    return nullptr;
}

void IoscClientBuffer::bufferDestroyResource(wl_resource *resource)
{
    if (IoscClientBuffer *buffer = IoscClientBuffer::get(resource)) {
        buffer->m_resource = nullptr;
        buffer->drop();
    }
}

void IoscClientBuffer::bufferDestroy(wl_client *client, wl_resource *resource)
{
    Q_UNUSED(client)
    wl_resource_destroy(resource);
}

IoscClientBufferIntegration::IoscClientBufferIntegration(Display *display)
    : QObject(display)
    , d(std::make_unique<IoscClientBufferIntegrationPrivate>(display))
{
}

IoscClientBufferIntegration::~IoscClientBufferIntegration() = default;

} // namespace KWin
EOF

# KWin has Linux/FreeBSD executable path backends only. The sysctl backend is the closest
# Darwin-family implementation and compiles against the iOS SDK.
perl -0pi -e 's/elseif\(CMAKE_SYSTEM_NAME MATCHES "FreeBSD"\)\n    target_sources\(kwin PRIVATE executable_path_sysctl\.cpp\)\nelse\(\)\n    message\(FATAL_ERROR "Unsupported platform \$\{CMAKE_SYSTEM_NAME\}"\)\nendif\(\)/elseif(CMAKE_SYSTEM_NAME MATCHES "FreeBSD")\n    target_sources(kwin PRIVATE executable_path_sysctl.cpp)\nelseif(CMAKE_SYSTEM_NAME MATCHES "Darwin")\n    target_sources(kwin PRIVATE executable_path_sysctl.cpp)\nelse()\n    message(FATAL_ERROR "Unsupported platform \${CMAKE_SYSTEM_NAME}")\nendif()/g' "$src/src/utils/CMakeLists.txt"
cat > "$src/src/utils/executable_path_sysctl.cpp" <<'EOF'
/*
   SPDX-FileCopyrightText: 2021 Tobias C. Berner <tcberner@FreeBSD.org>

   SPDX-License-Identifier: LGPL-2.1-only OR LGPL-3.0-only OR LicenseRef-KDE-Accepted-LGPL
*/

#include "executable_path.h"

#include <sys/types.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdlib.h>

QString executablePathFromPid(pid_t pid)
{
    if (pid != getpid()) {
        return QString();
    }

    char buf[PATH_MAX];
    uint32_t size = sizeof(buf);
    if (_NSGetExecutablePath(buf, &size) != 0) {
        return QString();
    }

    char *resolved = realpath(buf, nullptr);
    if (!resolved) {
        return QString::fromLocal8Bit(buf);
    }

    const QString path = QString::fromLocal8Bit(resolved);
    free(resolved);
    return path;
}
#else
#include <sys/param.h>
#include <sys/sysctl.h>

QString executablePathFromPid(pid_t pid)
{
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PATHNAME, static_cast<int>(pid)};
    char buf[MAXPATHLEN];
    size_t cb = sizeof(buf);
    if (sysctl(mib, 4, buf, &cb, nullptr, 0) == 0) {
        return QString::fromLocal8Bit(realpath(buf, nullptr));
    }
    return QString();
}
#endif
EOF

# qtx11extras_p.h is only needed inside the KWIN_BUILD_X11 sections.
if ! grep -q 'ios-bringup-qtx11extras' "$src/src/main.cpp"; then
    perl -0pi -e 's/#include <private\/qtx11extras_p\.h>/#if KWIN_BUILD_X11\n#include <private\/qtx11extras_p.h>\n#endif \/\/ ios-bringup-qtx11extras/g' "$src/src/main.cpp"
fi
if ! grep -q 'ios-bringup-xcb-cursor' "$src/src/cursor.cpp"; then
    perl -0pi -e 's/#include <xcb\/xcb_cursor\.h>/#if KWIN_BUILD_X11\n#include <xcb\/xcb_cursor.h>\n#endif \/\/ ios-bringup-xcb-cursor/g' "$src/src/cursor.cpp"
fi

if ! grep -q 'ios-bringup-no-drm-lease' "$src/src/wayland/CMakeLists.txt"; then
    perl -0pi -e 's/    drmlease_v1\.cpp\n/    # ios-bringup-no-drm-lease: disabled with the DRM backend on Apple\n/g' "$src/src/wayland/CMakeLists.txt"
    perl -0pi -e 's/    drmlease_v1\.h\n/    # ios-bringup-no-drm-lease-header: disabled with the DRM backend on Apple\n/g' "$src/src/wayland/CMakeLists.txt"
fi
if ! grep -q 'ios-bringup-no-drm-lease' "$src/src/wayland_server.cpp"; then
    perl -0pi -e 's/#include "wayland\/drmlease_v1\.h"/#if !defined(__APPLE__)\n#include "wayland\/drmlease_v1.h"\n#endif \/\/ ios-bringup-no-drm-lease/g' "$src/src/wayland_server.cpp"
    perl -0pi -e 's/    if \(auto backend = qobject_cast<DrmBackend \*>\(kwinApp\(\)->outputBackend\(\)\)\) {\n        m_leaseManager = new DrmLeaseManagerV1\(backend, m_display, m_display\);\n    }/#if !defined(__APPLE__)\n    if (auto backend = qobject_cast<DrmBackend *>(kwinApp()->outputBackend())) {\n        m_leaseManager = new DrmLeaseManagerV1(backend, m_display, m_display);\n    }\n#endif/g' "$src/src/wayland_server.cpp"
fi
if ! grep -q 'ios-bringup-no-drm-lease' "$src/src/wayland_server.h"; then
    perl -0pi -e 's/class DrmLeaseManagerV1;/#if !defined(__APPLE__)\nclass DrmLeaseManagerV1;\n#endif \/\/ ios-bringup-no-drm-lease/g' "$src/src/wayland_server.h"
    perl -0pi -e 's/    DrmLeaseManagerV1 \*m_leaseManager = nullptr;/#if !defined(__APPLE__)\n    DrmLeaseManagerV1 *m_leaseManager = nullptr;\n#endif/g' "$src/src/wayland_server.h"
fi
perl -0pi -e 's/target_link_libraries\(kwin_wayland\n(?:(?:    (?:KWinQpaPlugin|KF6WindowSystemKWinPlugin|KF6IdleTimeKWinPlugin)\n)|(?:    # ios-bringup-no-qpa-link:[^\n]*\n))+\)/target_link_libraries(kwin_wayland\n    KWinQpaPlugin\n    # ios-bringup-no-qpa-link: KWindowSystem\/IdleTime static plugins disabled for first-light\n)/g' "$src/src/CMakeLists.txt"

perl -0pi -e 's@#include "backends/drm/drm_backend\.h"\n#include "backends/virtual/virtual_backend\.h"@#if !defined(__APPLE__)\n#include "backends/drm/drm_backend.h"\n#include "backends/virtual/virtual_backend.h"\n#endif // ios-bringup-main-wayland@g' "$src/src/main_wayland.cpp"
perl -0pi -e 's@Q_IMPORT_PLUGIN\(KWindowSystemKWinPlugin\)\nQ_IMPORT_PLUGIN\(KWinIdleTimePoller\)@#if !defined(__APPLE__)\nQ_IMPORT_PLUGIN(KWindowSystemKWinPlugin)\nQ_IMPORT_PLUGIN(KWinIdleTimePoller)\n#endif // ios-bringup-main-wayland@g' "$src/src/main_wayland.cpp"
perl -0pi -e 's@    if \(parser\.isSet\(drmOption\)\) {\n        backendType = BackendType::Kms;@    if (parser.isSet(drmOption)) {\n#if defined(__APPLE__)\n        std::cerr << "FATAL ERROR: drm backend is not built on Apple/iOS first-light KWin" << std::endl;\n        return 1;\n#else\n        backendType = BackendType::Kms;\n#endif@g' "$src/src/main_wayland.cpp"
perl -0pi -e 's@    } else if \(parser\.isSet\(virtualFbOption\)\) {\n        backendType = BackendType::Virtual;@    } else if (parser.isSet(virtualFbOption)) {\n#if defined(__APPLE__)\n        std::cerr << "FATAL ERROR: virtual backend is not built on Apple/iOS first-light KWin; use --wayland-display" << std::endl;\n        return 1;\n#else\n        backendType = BackendType::Virtual;\n#endif@g' "$src/src/main_wayland.cpp"
perl -0pi -e 's@        } else if \(qEnvironmentVariableIsSet\("DISPLAY"\)\) {\n            qInfo\("No backend specified, automatically choosing X11 because DISPLAY is set"\);\n            backendType = BackendType::X11;\n        } else {\n            qInfo\("No backend specified, automatically choosing drm"\);\n            backendType = BackendType::Kms;\n        }@        }\n#if KWIN_BUILD_X11\n        else if (qEnvironmentVariableIsSet("DISPLAY")) {\n            qInfo("No backend specified, automatically choosing X11 because DISPLAY is set");\n            backendType = BackendType::X11;\n        }\n#endif\n        else {\n#if defined(__APPLE__)\n            qInfo("No backend specified, automatically choosing nested Wayland on Apple/iOS");\n            backendType = BackendType::Wayland;\n#else\n            qInfo("No backend specified, automatically choosing drm");\n            backendType = BackendType::Kms;\n#endif\n        }@g' "$src/src/main_wayland.cpp"
perl -0pi -e 's@    switch \(backendType\) {\n    case BackendType::Kms:@    switch (backendType) {\n#if !defined(__APPLE__)\n    case BackendType::Kms:@g' "$src/src/main_wayland.cpp"
perl -0pi -e 's@        a\.setOutputBackend\(std::make_unique<KWin::DrmBackend>\(a\.session\(\)\)\);\n        break;\n    case BackendType::Virtual:@        a.setOutputBackend(std::make_unique<KWin::DrmBackend>(a.session()));\n        break;\n    case BackendType::Virtual:@g' "$src/src/main_wayland.cpp"
perl -0pi -e 's@        a\.setOutputBackend\(std::move\(outputBackend\)\);\n        break;\n    }\n#if KWIN_BUILD_X11@        a.setOutputBackend(std::move(outputBackend));\n        break;\n    }\n#endif // ios-bringup-main-wayland\n#if KWIN_BUILD_X11@g' "$src/src/main_wayland.cpp"

if ! grep -q 'ios-bringup-no-opengl-quickview' "$src/src/effect/offscreenquickview.cpp"; then
    perl -0pi -e 's/#include "opengl\/glutils\.h"\n#include "opengl\/openglcontext\.h"/#include "opengl\/glutils.h"\n#if !defined(KWIN_IOS_QT_NO_OPENGL)\n#include "opengl\/openglcontext.h"\n#endif \/\/ ios-bringup-no-opengl-quickview/g' "$src/src/effect/offscreenquickview.cpp"
    perl -0pi -e 's/#include <QOpenGLContext>\n#include <QOpenGLFramebufferObject>\n#include <QQuickGraphicsDevice>\n#include <QQuickOpenGLUtils>\n#include <QQuickRenderTarget>/#if !defined(KWIN_IOS_QT_NO_OPENGL)\n#include <QOpenGLContext>\n#include <QOpenGLFramebufferObject>\n#include <QQuickGraphicsDevice>\n#include <QQuickOpenGLUtils>\n#include <QQuickRenderTarget>\n#endif/g' "$src/src/effect/offscreenquickview.cpp"
    perl -0pi -e 's/    std::unique_ptr<QOpenGLContext> m_glcontext;\n    std::unique_ptr<QOpenGLFramebufferObject> m_fbo;/#if !defined(KWIN_IOS_QT_NO_OPENGL)\n    std::unique_ptr<QOpenGLContext> m_glcontext;\n    std::unique_ptr<QOpenGLFramebufferObject> m_fbo;\n#endif/g' "$src/src/effect/offscreenquickview.cpp"
    perl -0pi -e 's/    const bool usingGl = d->m_view->rendererInterface\(\)->graphicsApi\(\) == QSGRendererInterface::OpenGL;/#if defined(KWIN_IOS_QT_NO_OPENGL)\n    const bool usingGl = false;\n#else\n    const bool usingGl = d->m_view->rendererInterface()->graphicsApi() == QSGRendererInterface::OpenGL;\n#endif/g' "$src/src/effect/offscreenquickview.cpp"
    perl -0pi -e 's/    } else {\n        QSurfaceFormat format;(.+?)    }\n\n    auto updateSize/    }\n#if !defined(KWIN_IOS_QT_NO_OPENGL)\n    else {\n        QSurfaceFormat format;$1    }\n#endif\n\n    auto updateSize/s' "$src/src/effect/offscreenquickview.cpp"
    perl -0pi -e 's/    if \(d->m_glcontext\) {\n        \/\/ close the view whilst we have an active GL context\n        d->m_glcontext->makeCurrent\(d->m_offscreenSurface\.get\(\)\);\n    }/#if !defined(KWIN_IOS_QT_NO_OPENGL)\n    if (d->m_glcontext) {\n        \/\/ close the view whilst we have an active GL context\n        d->m_glcontext->makeCurrent(d->m_offscreenSurface.get());\n    }\n#endif/g' "$src/src/effect/offscreenquickview.cpp"
    perl -0pi -e 's/    bool usingGl = d->m_glcontext != nullptr;\n    OpenGlContext \*previousContext = OpenGlContext::currentContext\(\);/#if defined(KWIN_IOS_QT_NO_OPENGL)\n    bool usingGl = false;\n#else\n    bool usingGl = d->m_glcontext != nullptr;\n    OpenGlContext *previousContext = OpenGlContext::currentContext();\n#endif/g' "$src/src/effect/offscreenquickview.cpp"
    perl -0pi -e 's/    if \(usingGl\) {\n        if \(!d->m_glcontext->makeCurrent\(d->m_offscreenSurface\.get\(\)\)\) {(.+?)        d->m_view->setRenderTarget\(renderTarget\);\n    }/#if !defined(KWIN_IOS_QT_NO_OPENGL)\n    if (usingGl) {\n        if (!d->m_glcontext->makeCurrent(d->m_offscreenSurface.get())) {$1        d->m_view->setRenderTarget(renderTarget);\n    }\n#endif/s' "$src/src/effect/offscreenquickview.cpp"
    perl -0pi -e 's/    if \(usingGl\) {\n        QQuickOpenGLUtils::resetOpenGLState\(\);\n    }/#if !defined(KWIN_IOS_QT_NO_OPENGL)\n    if (usingGl) {\n        QQuickOpenGLUtils::resetOpenGLState();\n    }\n#endif/g' "$src/src/effect/offscreenquickview.cpp"
    perl -0pi -e 's/        if \(usingGl\) {\n            d->m_image = d->m_fbo->toImage\(\);\n            d->m_image\.setDevicePixelRatio\(d->m_view->devicePixelRatio\(\)\);\n        } else {\n            d->m_image = d->m_view->grabWindow\(\);\n        }/#if !defined(KWIN_IOS_QT_NO_OPENGL)\n        if (usingGl) {\n            d->m_image = d->m_fbo->toImage();\n            d->m_image.setDevicePixelRatio(d->m_view->devicePixelRatio());\n        } else\n#endif\n        {\n            d->m_image = d->m_view->grabWindow();\n        }/g' "$src/src/effect/offscreenquickview.cpp"
    perl -0pi -e 's/    if \(usingGl\) {\n        QOpenGLFramebufferObject::bindDefault\(\);\n        d->m_glcontext->doneCurrent\(\);\n        if \(previousContext\) {\n            previousContext->makeCurrent\(\);\n        }\n    }/#if !defined(KWIN_IOS_QT_NO_OPENGL)\n    if (usingGl) {\n        QOpenGLFramebufferObject::bindDefault();\n        d->m_glcontext->doneCurrent();\n        if (previousContext) {\n            previousContext->makeCurrent();\n        }\n    }\n#endif/g' "$src/src/effect/offscreenquickview.cpp"
    perl -0pi -e 's/GLTexture \*OffscreenQuickView::bufferAsTexture\(\)\n\{\n    if \(d->m_useBlit\) {/GLTexture *OffscreenQuickView::bufferAsTexture()\n{\n#if defined(KWIN_IOS_QT_NO_OPENGL)\n    return nullptr;\n#else\n    if (d->m_useBlit) {/g' "$src/src/effect/offscreenquickview.cpp"
    perl -0pi -e 's/    return d->m_textureExport\.get\(\);\n}\n\nQImage OffscreenQuickView::bufferAsImage/    return d->m_textureExport.get();\n#endif\n}\n\nQImage OffscreenQuickView::bufferAsImage/g' "$src/src/effect/offscreenquickview.cpp"
    perl -0pi -e 's/    if \(m_glcontext\) {\n        m_glcontext->makeCurrent\(m_offscreenSurface\.get\(\)\);\n        m_view->releaseResources\(\);\n        m_glcontext->doneCurrent\(\);\n    } else {\n        m_view->releaseResources\(\);\n    }/#if !defined(KWIN_IOS_QT_NO_OPENGL)\n    if (m_glcontext) {\n        m_glcontext->makeCurrent(m_offscreenSurface.get());\n        m_view->releaseResources();\n        m_glcontext->doneCurrent();\n    } else\n#endif\n    {\n        m_view->releaseResources();\n    }/g' "$src/src/effect/offscreenquickview.cpp"
fi

if ! grep -q 'ios-bringup-no-libinput' "$src/src/input.cpp"; then
    perl -0pi -e 's/#include "backends\/libinput\/connection\.h"\n#include "backends\/libinput\/device\.h"/#if !defined(KWIN_IOS_NO_LIBINPUT)\n#include "backends\/libinput\/connection.h"\n#include "backends\/libinput\/device.h"\n#endif \/\/ ios-bringup-no-libinput/g' "$src/src/input.cpp"
    perl -0pi -e 's/    void integrateDevice\(InputDevice \*inputDevice\)\n    \{\n        auto device = qobject_cast<LibInput::Device \*>\(inputDevice\);/    void integrateDevice(InputDevice *inputDevice)\n    {\n#if defined(KWIN_IOS_NO_LIBINPUT)\n        Q_UNUSED(inputDevice)\n        return;\n#else\n        auto device = qobject_cast<LibInput::Device *>(inputDevice);/g' "$src/src/input.cpp"
    perl -0pi -e 's/(            tabletSeat->addTabletPad\(device->sysName\(\), device->name\(\), \{QString::fromUtf8\(devnode\)\}, buttonsCount, ringsCount, stripsCount, modes, libinput_tablet_pad_mode_group_get_mode\(firstGroup\), tablet\);\n        \}\n)    \}\n\n    static void trackNextOutput/$1#endif \/\/ ios-bringup-no-libinput-integrate\n    }\n\n    static void trackNextOutput/s' "$src/src/input.cpp"
    perl -0pi -e 's/    void removeDevice\(InputDevice \*inputDevice\)\n    \{\n        auto device = qobject_cast<LibInput::Device \*>\(inputDevice\);/    void removeDevice(InputDevice *inputDevice)\n    {\n#if defined(KWIN_IOS_NO_LIBINPUT)\n        Q_UNUSED(inputDevice)\n        return;\n#else\n        auto device = qobject_cast<LibInput::Device *>(inputDevice);/g' "$src/src/input.cpp"
    perl -0pi -e 's/(            \}\n        \}\n)    \}\n\n    TabletToolV2Interface::Type getType/$1#endif \/\/ ios-bringup-no-libinput-remove\n    }\n\n    TabletToolV2Interface::Type getType/s' "$src/src/input.cpp"
fi
if ! grep -q 'ios-bringup-inputdevice-include' "$src/src/input.cpp"; then
    perl -0pi -e 's/#include "core\/inputbackend\.h"/#include "core\/inputbackend.h"\n#include "core\/inputdevice.h" \/\/ ios-bringup-inputdevice-include/g' "$src/src/input.cpp"
fi

if ! grep -q 'ios-bringup-no-opengl-thumbnails' "$src/src/scripting/windowthumbnailitem.cpp"; then
    perl -0pi -e 's/static bool useGlThumbnails\(\)\n\{\n    static bool qtQuickIsSoftware/static bool useGlThumbnails()\n{\n#if defined(KWIN_IOS_QT_NO_OPENGL)\n    return false;\n#endif \/\/ ios-bringup-no-opengl-thumbnails\n    static bool qtQuickIsSoftware/g' "$src/src/scripting/windowthumbnailitem.cpp"
    perl -0pi -e 's/    if \(m_nativeTexture != nativeTexture\) {\n        const GLuint textureId = nativeTexture->texture\(\);/ #if defined(KWIN_IOS_QT_NO_OPENGL)\n    Q_UNUSED(nativeTexture)\n    m_nativeTexture = nullptr;\n    m_texture.reset();\n#else\n    if (m_nativeTexture != nativeTexture) {\n        const GLuint textureId = nativeTexture->texture();/g' "$src/src/scripting/windowthumbnailitem.cpp"
    perl -0pi -e 's/    }\n\n    \/\/ The textureChanged signal must be emitted also if only texture data changes\.\n    Q_EMIT textureChanged\(\);\n}/    }\n#endif\n\n    \/\/ The textureChanged signal must be emitted also if only texture data changes.\n    Q_EMIT textureChanged();\n}/g' "$src/src/scripting/windowthumbnailitem.cpp"
fi

if ! grep -q 'ios-bringup-no-libinput' "$src/src/tabletmodemanager.cpp"; then
    perl -0pi -e 's/#include "backends\/libinput\/device\.h"/#if !defined(KWIN_IOS_NO_LIBINPUT)\n#include "backends\/libinput\/device.h"\n#endif \/\/ ios-bringup-no-libinput/g' "$src/src/tabletmodemanager.cpp"
    perl -0pi -e 's/    auto libinput_device = qobject_cast<LibInput::Device \*>\(device\);/#if defined(KWIN_IOS_NO_LIBINPUT)\n    Q_UNUSED(device)\n    return false;\n#else\n    auto libinput_device = qobject_cast<LibInput::Device *>(device);/g' "$src/src/tabletmodemanager.cpp"
    perl -0pi -e 's/    return ignore;\n}/    return ignore;\n#endif\n}/g' "$src/src/tabletmodemanager.cpp"
fi

if ! grep -q 'ios-bringup-no-sealed-ramfile' "$src/src/utils/ramfile.cpp"; then
    perl -0pi -e 's/    int seals = F_SEAL_SHRINK \| F_SEAL_GROW \| F_SEAL_SEAL;\n    if \(flags\.testFlag\(RamFile::Flag::SealWrite\)\) {\n        seals \|= F_SEAL_WRITE;\n    }\n    \/\/ This can fail for QTemporaryFile based on the underlying file system\.\n    if \(fcntl\(fd\(\), F_ADD_SEALS, seals\) != 0\) {\n        qCDebug\(KWIN_CORE\)\.nospace\(\) << name << ": Failed to seal RamFile: " << strerror\(errno\);\n    }/#if !defined(__APPLE__)\n    int seals = F_SEAL_SHRINK | F_SEAL_GROW | F_SEAL_SEAL;\n    if (flags.testFlag(RamFile::Flag::SealWrite)) {\n        seals |= F_SEAL_WRITE;\n    }\n    \/\/ This can fail for QTemporaryFile based on the underlying file system.\n    if (fcntl(fd(), F_ADD_SEALS, seals) != 0) {\n        qCDebug(KWIN_CORE).nospace() << name << ": Failed to seal RamFile: " << strerror(errno);\n    }\n#else\n    qCDebug(KWIN_CORE).nospace() << name << ": RamFile sealing is not available on Darwin";\n#endif \/\/ ios-bringup-no-sealed-ramfile/g' "$src/src/utils/ramfile.cpp"
    perl -0pi -e 's/    const int seals = fcntl\(fd\(\), F_GET_SEALS\);\n    if \(seals > 0\) {\n        if \(seals & F_SEAL_WRITE\) {\n            flags\.setFlag\(Flag::SealWrite\);\n        }\n    }/#if !defined(__APPLE__)\n    const int seals = fcntl(fd(), F_GET_SEALS);\n    if (seals > 0) {\n        if (seals & F_SEAL_WRITE) {\n            flags.setFlag(Flag::SealWrite);\n        }\n    }\n#endif/g' "$src/src/utils/ramfile.cpp"
fi
if ! grep -q 'ios-bringup-no-sealed-shm' "$src/src/wayland/shmclientbuffer.cpp"; then
    perl -0pi -e 's/#if HAVE_MEMFD\n    const int seals = fcntl\(this->fd\.get\(\), F_GET_SEALS\);/#if HAVE_MEMFD \&\& !defined(__APPLE__) \/\/ ios-bringup-no-sealed-shm\n    const int seals = fcntl(this->fd.get(), F_GET_SEALS);/g' "$src/src/wayland/shmclientbuffer.cpp"
fi
if ! grep -q 'ios-bringup-no-memfd-shm-allocator' "$src/src/core/shmgraphicsbufferallocator.cpp"; then
    perl -0pi -e 's/#if HAVE_MEMFD\n    FileDescriptor fd = FileDescriptor\(memfd_create\("shm", MFD_CLOEXEC \| MFD_ALLOW_SEALING\)\);/#if HAVE_MEMFD \&\& !defined(__APPLE__) \/\/ ios-bringup-no-memfd-shm-allocator\n    FileDescriptor fd = FileDescriptor(memfd_create("shm", MFD_CLOEXEC | MFD_ALLOW_SEALING));/g' "$src/src/core/shmgraphicsbufferallocator.cpp"
fi

# No udev on iOS. The DRM/libinput backends that consume real udev are disabled above, so
# the shared utility object can safely expose inert implementations.
cat > "$src/src/utils/udev.cpp" <<'EOF'
/*
    iOS bring-up shim: KWin's Linux DRM/libinput backends are disabled, but utility
    classes are still part of libkwin. Keep the ABI and return no devices.
*/
#include "udev.h"

#include <QByteArray>
#include <QMap>
#include <QString>

namespace KWin
{

Udev::Udev()
    : m_udev(nullptr)
{
}

Udev::~Udev() = default;

std::vector<std::unique_ptr<UdevDevice>> Udev::listGPUs()
{
    return {};
}

std::unique_ptr<UdevDevice> Udev::deviceFromSyspath(const char *syspath)
{
    Q_UNUSED(syspath)
    return {};
}

std::unique_ptr<UdevMonitor> Udev::monitor()
{
    return nullptr;
}

UdevDevice::UdevDevice(udev_device *device)
    : m_device(device)
{
}

UdevDevice::~UdevDevice() = default;

QString UdevDevice::devNode() const
{
    return {};
}

dev_t UdevDevice::devNum() const
{
    return 0;
}

const char *UdevDevice::property(const char *key)
{
    Q_UNUSED(key)
    return nullptr;
}

bool UdevDevice::hasProperty(const char *key, const char *value)
{
    Q_UNUSED(key)
    Q_UNUSED(value)
    return false;
}

QString UdevDevice::action() const
{
    return {};
}

QMap<QByteArray, QByteArray> UdevDevice::properties() const
{
    return {};
}

bool UdevDevice::isBootVga() const
{
    return false;
}

QString UdevDevice::seat() const
{
    return QStringLiteral("seat0");
}

bool UdevDevice::isHotpluggable() const
{
    return false;
}

UdevMonitor::UdevMonitor(Udev *udev)
    : m_monitor(nullptr)
{
    Q_UNUSED(udev)
}

UdevMonitor::~UdevMonitor() = default;

int UdevMonitor::fd() const
{
    return -1;
}

void UdevMonitor::filterSubsystemDevType(const char *subSystem, const char *devType)
{
    Q_UNUSED(subSystem)
    Q_UNUSED(devType)
}

void UdevMonitor::enable()
{
}

std::unique_ptr<UdevDevice> UdevMonitor::getDevice()
{
    return nullptr;
}

}
EOF

# Darwin has pipe()+fcntl(), not Linux pipe2().
cat > "$src/src/kwin-ios-compat.h" <<'EOF'
#pragma once
#if __has_include(<QtGui/qtgui-config.h>)
#include <QtGui/qtgui-config.h>
#endif
#if defined(QT_FEATURE_opengl) && QT_FEATURE_opengl < 0
#define KWIN_IOS_QT_NO_OPENGL 1
#endif
// ios-bringup-gl-coexist: when KWin builds with Qt OpenGL ENABLED, epoxy must be the
// SOLE GL provider in every TU. Qt's <QtGui/qopengl.h> (this build is -opengl es2) takes
// the iOS OpenGLES.framework branch (<OpenGLES/ES{2,3}/gl.h>), whose real gl* prototypes
// collide with epoxy's dispatch macros (#define glClear epoxy_glClear) ->
// "redefinition of 'epoxy_glClear' as different kind of symbol". Mirror the Linux
// mechanism (epoxy's __gl_h_ makes Qt's later <GL/gl.h> a no-op): include epoxy FIRST,
// then pre-define the framework include guards so qopengl.h skips those headers and
// takes epoxy's ABI-identical Khronos typedefs (GLsync == struct __GLsync* in both).
// This header is force-included (-include, after the iosexec fixup) so it runs before
// any Qt include in the TU. Validated: 0 errors vs 20 baseline against the full KWin
// Qt-GL surface (QOpenGLContext/FramebufferObject, QQuick{RenderControl,RenderTarget,
// GraphicsDevice,OpenGLUtils}, QSG{ImageNode,TextureProvider}). No Qt rebuild needed.
// Scope gate KWIN_IOS_GL_COEXIST: this compat header is force-included in EVERY C++ TU
// via CMAKE_CXX_FLAGS, which INCLUDES CMake's check_cxx_source_compiles probes. KWin's
// HAVE_GLESv2 probe (and Qt6GuiConfig's find_dependency(GLESv2)) links -framework
// OpenGLES and has /var/jb/usr/include on its -isystem path, so epoxy is reachable
// there too; if the shim activated in that probe, epoxy's gl* dispatch macros would
// turn the probe's GL calls into unlinked epoxy_* symbols -> probe link fails -> Qt6Gui
// cascades to NOT-FOUND and configure dies. So gate on a macro set ONLY on KWin's real
// library target (target_compile_definitions(kwin PRIVATE KWIN_IOS_GL_COEXIST=1), the
// exact scope the old QT_NO_OPENGL=1 used). Probes lack it -> shim inert -> GLESv2
// probe passes against the real OpenGLES framework. __has_include stays as a guard.
#if defined(__APPLE__) && defined(KWIN_IOS_GL_COEXIST) && !defined(KWIN_IOS_QT_NO_OPENGL) && __has_include(<epoxy/gl.h>)
#include <epoxy/gl.h>
#ifndef __gltypes_h_
#define __gltypes_h_ 1
#endif
#ifndef __gl_es20_h_
#define __gl_es20_h_ 1
#endif
#ifndef __gl_es20ext_h_
#define __gl_es20ext_h_ 1
#endif
#ifndef __gl_es30_h_
#define __gl_es30_h_ 1
#endif
#ifndef __gl_es30ext_h_
#define __gl_es30ext_h_ 1
#endif
#endif // ios-bringup-gl-coexist
#if defined(__APPLE__)
#define KWIN_IOS_NO_LIBINPUT 1
#endif
#if defined(KWIN_IOS_QT_NO_OPENGL) && (defined(QT_NO_OPENGL) || (defined(QT_FEATURE_opengl) && QT_FEATURE_opengl < 0))
class QOpenGLContext
{
public:
    enum OpenGLModuleType {
        LibGL,
        LibGLES,
    };
    static OpenGLModuleType openGLModuleType()
    {
        return LibGLES;
    }
    static QOpenGLContext *currentContext()
    {
        return nullptr;
    }
    static QOpenGLContext *globalShareContext()
    {
        return nullptr;
    }
    static bool supportsThreadedOpenGL()
    {
        return false;
    }
    void doneCurrent()
    {
    }
};
#endif
#if defined(__APPLE__)
#include <errno.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <unistd.h>
#ifndef O_CLOEXEC
#define O_CLOEXEC 0
#endif
#ifndef SOCK_CLOEXEC
#define SOCK_CLOEXEC 0x10000000
#endif
static inline int kwin_ios_set_cloexec(int fd)
{
    int descriptorFlags = fcntl(fd, F_GETFD);
    if (descriptorFlags == -1) {
        return -1;
    }
    return fcntl(fd, F_SETFD, descriptorFlags | FD_CLOEXEC);
}
static inline int kwin_ios_pipe2(int pipefd[2], int flags)
{
    if (pipe(pipefd) != 0) {
        return -1;
    }
    if (flags & O_CLOEXEC) {
        if (kwin_ios_set_cloexec(pipefd[0]) != 0 || kwin_ios_set_cloexec(pipefd[1]) != 0) {
            const int savedErrno = errno;
            close(pipefd[0]);
            close(pipefd[1]);
            errno = savedErrno;
            return -1;
        }
    }
    return 0;
}
static inline int kwin_ios_socketpair(int domain, int type, int protocol, int socketVector[2])
{
    const bool closeOnExec = (type & SOCK_CLOEXEC) != 0;
    type &= ~SOCK_CLOEXEC;
    if (socketpair(domain, type, protocol, socketVector) != 0) {
        return -1;
    }
    if (closeOnExec) {
        if (kwin_ios_set_cloexec(socketVector[0]) != 0 || kwin_ios_set_cloexec(socketVector[1]) != 0) {
            const int savedErrno = errno;
            close(socketVector[0]);
            close(socketVector[1]);
            errno = savedErrno;
            return -1;
        }
    }
    return 0;
}
static inline int kwin_ios_accept4(int socketDescriptor, struct sockaddr *address, socklen_t *addressLength, int flags)
{
    const int fd = accept(socketDescriptor, address, addressLength);
    if (fd < 0) {
        return -1;
    }
    if ((flags & SOCK_CLOEXEC) && kwin_ios_set_cloexec(fd) != 0) {
        const int savedErrno = errno;
        close(fd);
        errno = savedErrno;
        return -1;
    }
    return fd;
}
#define pipe2 kwin_ios_pipe2
#define socketpair kwin_ios_socketpair
#define accept4 kwin_ios_accept4
#endif
EOF

# --- Fractional output-scale inbound-coordinate correction (nested Wayland backend) ---
# kwin_wayland runs nested as a Wayland client of iosc. With a fractional output scale s
# (e.g. 1.5 from Plasma's Displays KCM) the EGL backend tags the host surface with
# wl_surface.set_buffer_scale(std::ceil(s)) (wayland_egl_backend.cpp:135), but the nested
# backend interprets inbound surface-local pointer/touch coordinates 1:1 as its own
# kwin-logical coordinates. Per the Wayland protocol, surface-local coordinates are in
# buffer/buffer_scale space (= pixelSize/ceil(s)), whereas kwin's logical output space is
# pixelSize/s (core/output.cpp: geometry() = QRect(pos, pixelSize()/scale())). The two
# agree only at integer scale; at s=1.5 every event lands at s/ceil(s)=0.75 of the true
# position. Rescale inbound surface-local coordinates by ceil(s)/s. The factor is exactly
# 1.0 at integer scales, so 100%/200% behaviour is unchanged; only 125/150/175% is fixed.
python3 - "$src/src/backends/wayland/wayland_backend.cpp" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()

# Idempotent: a fresh extract is expected each build (cache invalidation removes
# build_work/.../kwin), but stay safe if the fixes script is re-run on the same tree.
if "ios-bringup-fractional-scale" in text:
    print("wayland_backend.cpp: ios-bringup-fractional-scale already applied")
    sys.exit(0)

def sub(old, new):
    global text
    n = text.count(old)
    if n != 1:
        raise SystemExit(
            "wayland_backend.cpp: expected exactly one match, found %d for:\n%s" % (n, old)
        )
    text = text.replace(old, new)

# 1) include <cmath> for std::ceil
sub(
    "#include <drm_fourcc.h>\n#include <fcntl.h>\n",
    "#include <cmath> // ios-bringup-fractional-scale\n#include <drm_fourcc.h>\n#include <fcntl.h>\n",
)

# 2) helper: surface-local -> kwin-logical rescale factor = ceil(scale)/scale
sub(
    "inline static QPointF sizeToPoint(const QSizeF &size)\n"
    "{\n"
    "    return QPointF(size.width(), size.height());\n"
    "}\n",
    "inline static QPointF sizeToPoint(const QSizeF &size)\n"
    "{\n"
    "    return QPointF(size.width(), size.height());\n"
    "}\n"
    "\n"
    "// ios-bringup-fractional-scale: the host tags kwin's nested surface with\n"
    "// wl_surface.set_buffer_scale(ceil(outputScale)), so inbound surface-local\n"
    "// coordinates arrive in pixelSize/ceil(scale) space while kwin's logical output\n"
    "// space is pixelSize/scale. Rescale surface-local coordinates by ceil(scale)/scale.\n"
    "// Exactly 1.0 at integer scales (no behaviour change there).\n"
    "static inline qreal xiosSurfaceToLogicalFactor(const WaylandOutput *output)\n"
    "{\n"
    "    const qreal scale = output ? output->scale() : 1.0;\n"
    "    if (scale <= 0.0) {\n"
    "        return 1.0;\n"
    "    }\n"
    "    return std::ceil(scale) / scale;\n"
    "}\n",
)

# 3) pointer motion: absolute surface-local position
sub(
    "        const QPointF absolutePos = output->geometry().topLeft() + relativeToSurface;\n",
    "        const QPointF absolutePos = output->geometry().topLeft() + relativeToSurface * xiosSurfaceToLogicalFactor(output); // ios-bringup-fractional-scale\n",
)

# 4) pinch gesture: surface-local delta vector (same space, same factor)
sub(
    "        connect(m_pinchGesture.get(), &PointerPinchGesture::updated, this, [this](const QSizeF &delta, qreal scale, qreal rotation, quint32 time) {\n"
    "            Q_EMIT pinchGestureUpdate(scale, rotation, sizeToPoint(delta), std::chrono::milliseconds(time), this);\n"
    "        });\n",
    "        connect(m_pinchGesture.get(), &PointerPinchGesture::updated, this, [this](const QSizeF &delta, qreal scale, qreal rotation, quint32 time) {\n"
    "            const qreal f = xiosSurfaceToLogicalFactor(m_seat->backend()->findOutput(m_pointer->enteredSurface())); // ios-bringup-fractional-scale\n"
    "            Q_EMIT pinchGestureUpdate(scale, rotation, sizeToPoint(delta) * f, std::chrono::milliseconds(time), this);\n"
    "        });\n",
)

# 5) swipe gesture: surface-local delta vector (same space, same factor)
sub(
    "        connect(m_swipeGesture.get(), &PointerSwipeGesture::updated, this, [this](const QSizeF &delta, quint32 time) {\n"
    "            Q_EMIT swipeGestureUpdate(sizeToPoint(delta), std::chrono::milliseconds(time), this);\n"
    "        });\n",
    "        connect(m_swipeGesture.get(), &PointerSwipeGesture::updated, this, [this](const QSizeF &delta, quint32 time) {\n"
    "            const qreal f = xiosSurfaceToLogicalFactor(m_seat->backend()->findOutput(m_pointer->enteredSurface())); // ios-bringup-fractional-scale\n"
    "            Q_EMIT swipeGestureUpdate(sizeToPoint(delta) * f, std::chrono::milliseconds(time), this);\n"
    "        });\n",
)

# 6) touch down (sequenceStarted + pointAdded) and touch motion (pointMoved):
#    tp->position() is emitted with NO transform and NO output-origin offset. Rescale by
#    the same factor AND add the output-origin offset the pointer path already has
#    (findOutput(surface) — latent multi-output fix, a no-op for the single output at 0,0).
sub(
    "    connect(touch, &Touch::sequenceStarted, this, [this](TouchPoint *tp) {\n"
    "        Q_EMIT touchDown(tp->id(), tp->position(), std::chrono::milliseconds(tp->time()), this);\n"
    "    });\n"
    "    connect(touch, &Touch::pointAdded, this, [this](TouchPoint *tp) {\n"
    "        Q_EMIT touchDown(tp->id(), tp->position(), std::chrono::milliseconds(tp->time()), this);\n"
    "    });\n",
    "    connect(touch, &Touch::sequenceStarted, this, [this](TouchPoint *tp) {\n"
    "        WaylandOutput *output = m_seat->backend()->findOutput(tp->surface()); // ios-bringup-fractional-scale\n"
    "        const QPointF pos = (output ? QPointF(output->geometry().topLeft()) : QPointF(0, 0)) + tp->position() * xiosSurfaceToLogicalFactor(output);\n"
    "        Q_EMIT touchDown(tp->id(), pos, std::chrono::milliseconds(tp->time()), this);\n"
    "    });\n"
    "    connect(touch, &Touch::pointAdded, this, [this](TouchPoint *tp) {\n"
    "        WaylandOutput *output = m_seat->backend()->findOutput(tp->surface()); // ios-bringup-fractional-scale\n"
    "        const QPointF pos = (output ? QPointF(output->geometry().topLeft()) : QPointF(0, 0)) + tp->position() * xiosSurfaceToLogicalFactor(output);\n"
    "        Q_EMIT touchDown(tp->id(), pos, std::chrono::milliseconds(tp->time()), this);\n"
    "    });\n",
)
sub(
    "    connect(touch, &Touch::pointMoved, this, [this](TouchPoint *tp) {\n"
    "        Q_EMIT touchMotion(tp->id(), tp->position(), std::chrono::milliseconds(tp->time()), this);\n"
    "    });\n",
    "    connect(touch, &Touch::pointMoved, this, [this](TouchPoint *tp) {\n"
    "        WaylandOutput *output = m_seat->backend()->findOutput(tp->surface()); // ios-bringup-fractional-scale\n"
    "        const QPointF pos = (output ? QPointF(output->geometry().topLeft()) : QPointF(0, 0)) + tp->position() * xiosSurfaceToLogicalFactor(output);\n"
    "        Q_EMIT touchMotion(tp->id(), pos, std::chrono::milliseconds(tp->time()), this);\n"
    "    });\n",
)

path.write_text(text)
print("wayland_backend.cpp: applied ios-bringup-fractional-scale inbound-coordinate correction")
PY

# Keep the accelerated ANGLE/IOSurface phase separate from the first-light
# compatibility edits above. This makes the stable QPainter bring-up easy to
# audit while the GPU path can evolve as one recipe-owned patch stage.
bash "$(dirname "$0")/kwin-ios-gpu-backend.sh" "$src"

# KWIN_BUILD_KCMS=ON builds kwin-applywindowdecoration, a CLI helper with no
# ecm_mark_nongui_executable(). Under ECM/KDECMakeSettings on Apple an un-marked
# executable silently becomes a .app in KDE_INSTALL_BUNDLEDIR and then vanishes
# from the deb -- the same landmine that ate kscreen-doctor and kiod6.
python3 - "$src/src/kcms/decoration/CMakeLists.txt" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
MARKER = "# ios: keep this a plain CLI binary"
if MARKER not in text:
    anchor = "add_executable(kwin-applywindowdecoration"
    if anchor not in text:
        raise SystemExit("kwin-ios-fixes.sh: kwin-applywindowdecoration target not found")
    text += (
        "\n" + MARKER + "; an un-marked executable becomes a\n"
        "# .app bundle on Apple and disappears from the package.\n"
        "set_target_properties(kwin-applywindowdecoration PROPERTIES MACOSX_BUNDLE FALSE)\n"
    )
    path.write_text(text)
PY

# src/kcms/rules compiles kwin core sources (rules.cpp, workspace.h, sm.h,
# virtualdesktopsdbustypes.cpp) into a STATIC lib OUTSIDE the kwin target, under
# -DKCMRULES. Those headers include QDBusContext/QDBusArgument, but the kcm_libs
# list has no Qt::DBus, so the target never gets QtDBus on its include path and
# the build dies with "'QDBusContext' file not found". Upstream gets away with it
# because on Linux Qt::Gui pulls DBus in transitively; this Qt does not.
python3 - "$src/src/kcms/rules/CMakeLists.txt" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
MARKER = "# ios: kwin core sources here need Qt::DBus"
if MARKER not in text:
    anchor = "    Qt::Quick\n"
    if anchor not in text:
        raise SystemExit("kwin-ios-fixes.sh: kcm_libs Qt::Quick entry not found in kcms/rules")
    text = text.replace(anchor, anchor + "    " + MARKER + " on the include path.\n    Qt::DBus\n", 1)
    path.write_text(text)
PY
