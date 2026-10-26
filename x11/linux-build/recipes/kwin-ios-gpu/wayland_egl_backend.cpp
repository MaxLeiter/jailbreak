/*
    KWin - the KDE window manager
    This file is part of the KDE project.

    SPDX-FileCopyrightText: 2019 Roman Gilg <subdiff@gmail.com>
    SPDX-FileCopyrightText: 2013 Martin Gräßlin <mgraesslin@kde.org>

    SPDX-License-Identifier: GPL-2.0-or-later
*/

#include "wayland_egl_backend.h"
#include "core/drmdevice.h"
#include "core/renderdevice.h"
#include "opengl/eglswapchain.h"
#include "opengl/glrendertimequery.h"
#include "opengl/glutils.h"
#include "scene/surfaceitem_wayland.h"
#include "iosc_gpu_support.h"
#include "wayland/surface.h"
#include "wayland_backend.h"
#include "wayland_display.h"
#include "wayland_logging.h"
#include "wayland_output.h"
#include "wayland_server.h"

#include <KWayland/Client/compositor.h>
#include <KWayland/Client/region.h>
#include <KWayland/Client/subsurface.h>
#include <KWayland/Client/surface.h>

#include <cmath>
#include <drm_fourcc.h>
#include <fcntl.h>
#include <unistd.h>

namespace KWin
{
namespace Wayland
{

static const FormatModifierMap s_ioscFormats = {{DRM_FORMAT_ARGB8888, {DRM_FORMAT_MOD_LINEAR}}};

static const bool bufferAgeEnabled = qEnvironmentVariable("KWIN_USE_BUFFER_AGE") != QStringLiteral("0");

WaylandEglLayer::WaylandEglLayer(WaylandOutput *output, WaylandEglBackend *backend, OutputLayerType type, int zpos)
    : WaylandLayer(output, type, zpos)
    , m_backend(backend)
{
}

WaylandEglLayer::~WaylandEglLayer()
{
}

GLFramebuffer *WaylandEglLayer::fbo() const
{
    return m_buffer->framebuffer();
}

std::optional<OutputLayerBeginFrameInfo> WaylandEglLayer::doBeginFrame()
{
    if (!m_backend->openglContext()->makeCurrent()) {
        qCCritical(KWIN_WAYLAND_BACKEND) << "Make Context Current failed";
        return std::nullopt;
    }

    if (m_color != m_previousColor) {
        // need to force a full repaint
        m_damageJournal.clear();
    }

    const QSize nativeSize = targetRect().size();
    if (!m_swapchain || m_swapchain->size() != nativeSize) {
        // xios: one format, one allocator (IOSurface); no dmabuf format negotiation
        m_swapchain = EglSwapchain::create(ioscGpuAllocator(), m_backend->openglContext(), nativeSize, DRM_FORMAT_ARGB8888, {DRM_FORMAT_MOD_LINEAR});
        if (!m_swapchain) {
            qCWarning(KWIN_WAYLAND_BACKEND) << "Could not create the IOSurface swapchain";
            return std::nullopt;
        }
    }

    m_buffer = m_swapchain->acquire();
    if (!m_buffer) {
        return std::nullopt;
    }

    const Region repair = bufferAgeEnabled ? m_damageJournal.accumulate(m_buffer->age(), Region::infinite()) : Region::infinite();
    m_query = std::make_unique<GLRenderTimeQuery>(m_backend->openglContextRef());
    m_query->begin();
    return OutputLayerBeginFrameInfo{
        .renderTarget = RenderTarget(m_buffer->framebuffer(), m_color),
        .repaint = repair,
    };
}

bool WaylandEglLayer::doEndFrame(const Region &renderedDeviceRegion, const Region &damagedDeviceRegion, OutputFrame *frame)
{
    m_query->end();
    frame->addRenderTimeQuery(std::move(m_query));
    // xios: flush, then export the Metal acquire fence for exactly this rendering; WaylandLayer::commit sends it with the buffer.
    glFlush();
    if (!ioscSignalAcquireFence(m_backend->eglDisplayObject()->handle(), m_buffer->buffer())) {
        return false;
    }

    // xios: an output surface is opaque by definition. These IOSurfaces are BGRA, so absent an opaque region iosc must
    // blend the surface, and KWin clears the output to (0,0,0,0): the screen would composite to nothing.
    if (type() == OutputLayerType::Primary && m_opaqueSize != m_buffer->buffer()->size()) {
        if (auto *compositor = m_backend->backend()->display()->compositor()) {
            const auto opaque = compositor->createRegion(QRegion(QRect(QPoint(0, 0), m_buffer->buffer()->size())));
            surface()->setOpaqueRegion(opaque.get());
            m_opaqueSize = m_buffer->buffer()->size();
        }
    }

    setBuffer(m_buffer->buffer(), damagedDeviceRegion);
    m_swapchain->release(m_buffer, FileDescriptor());

    m_damageJournal.add(damagedDeviceRegion);
    return true;
}

bool WaylandEglLayer::earlyScanoutChecks()
{
    return false; // xios: no client dmabuf scanout, only compositor-rendered IOSurfaces
}

bool WaylandEglLayer::importScanoutBuffer(GraphicsBuffer *buffer, const std::shared_ptr<OutputFrame> &frame)
{
    setBuffer(buffer, Region::infinite());
    return true;
}

DrmDevice *WaylandEglLayer::scanoutDevice() const
{
    return m_backend->drmDevice();
}

FormatModifierMap WaylandEglLayer::supportedDrmFormats() const
{
    return s_ioscFormats;
}

void WaylandEglLayer::releaseBuffers()
{
    m_buffer.reset();
    m_swapchain.reset();
}

WaylandEglCursorLayer::WaylandEglCursorLayer(WaylandOutput *output, WaylandEglBackend *backend)
    : OutputLayer(output, OutputLayerType::CursorOnly, 255, 255, 255)
    , m_backend(backend)
{
}

WaylandEglCursorLayer::~WaylandEglCursorLayer()
{
    (void)m_backend->openglContext()->makeCurrent();
}

std::optional<OutputLayerBeginFrameInfo> WaylandEglCursorLayer::doBeginFrame()
{
    if (!m_backend->openglContext()->makeCurrent()) {
        qCCritical(KWIN_WAYLAND_BACKEND) << "Make Context Current failed";
        return std::nullopt;
    }

    const auto bufferSize = targetRect().size();
    if (!m_swapchain || m_swapchain->size() != bufferSize) {
        m_swapchain = EglSwapchain::create(ioscGpuAllocator(), m_backend->openglContext(), bufferSize, DRM_FORMAT_ARGB8888, {DRM_FORMAT_MOD_LINEAR});
        if (!m_swapchain) {
            return std::nullopt;
        }
    }

    m_buffer = m_swapchain->acquire();
    if (!m_buffer) {
        return std::nullopt;
    }

    m_query = std::make_unique<GLRenderTimeQuery>(m_backend->openglContextRef());
    m_query->begin();
    return OutputLayerBeginFrameInfo{
        .renderTarget = RenderTarget(m_buffer->framebuffer()),
        .repaint = Region::infinite(),
    };
}

bool WaylandEglCursorLayer::doEndFrame(const Region &renderedDeviceRegion, const Region &damagedDeviceRegion, OutputFrame *frame)
{
    m_query->end();
    if (frame) {
        frame->addRenderTimeQuery(std::move(m_query));
    }
    glFlush();
    if (!ioscSignalAcquireFence(m_backend->eglDisplayObject()->handle(), m_buffer->buffer())) {
        return false;
    }

    wl_buffer *buffer = m_backend->backend()->importBuffer(m_buffer->buffer());
    if (!buffer) {
        return false;
    }
    ioscApplyAcquireFence(m_backend->backend()->display(), buffer, m_buffer->buffer());

    // xios: the cursor surface lives in the host window's coordinate space, pixelSize / hostSurfaceScale()
    auto *waylandOutput = static_cast<WaylandOutput *>(m_output.get());
    const qreal hostScale = waylandOutput->hostSurfaceScale();
    waylandOutput->cursor()->update(buffer, m_buffer->buffer()->size() / hostScale, (hotspot() / hostScale).toPoint());

    m_swapchain->release(m_buffer, FileDescriptor());
    return true;
}

DrmDevice *WaylandEglCursorLayer::scanoutDevice() const
{
    return m_backend->drmDevice();
}

FormatModifierMap WaylandEglCursorLayer::supportedDrmFormats() const
{
    return s_ioscFormats;
}

void WaylandEglCursorLayer::releaseBuffers()
{
    m_buffer.reset();
    m_swapchain.reset();
}

WaylandEglBackend::WaylandEglBackend(WaylandBackend *b)
    : m_backend(b)
{
    connect(m_backend, &WaylandBackend::outputAdded, this, &WaylandEglBackend::createOutputLayers);

    b->setEglBackend(this);
}

WaylandEglBackend::~WaylandEglBackend()
{
    const auto outputs = m_backend->outputs();
    for (BackendOutput *output : outputs) {
        static_cast<WaylandOutput *>(output)->setOutputLayers({});
    }
    cleanup();
}

WaylandBackend *WaylandEglBackend::backend() const
{
    return m_backend;
}

DrmDevice *WaylandEglBackend::drmDevice() const
{
    return m_backend->drmDevice();
}

void WaylandEglBackend::createOutputLayers(BackendOutput *output)
{
    const auto waylandOutput = static_cast<WaylandOutput *>(output);
    std::vector<std::unique_ptr<OutputLayer>> layers;
    // xios: a single primary layer. The upstream overlay layers only matter for dmabuf direct scanout.
    auto primary = std::make_unique<WaylandEglLayer>(waylandOutput, this, OutputLayerType::Primary, 0);
    primary->subSurface()->placeAbove(waylandOutput->surface());
    layers.push_back(std::move(primary));
    layers.push_back(std::make_unique<WaylandEglCursorLayer>(waylandOutput, this));
    waylandOutput->setOutputLayers(std::move(layers));
}

bool WaylandEglBackend::initializeEgl()
{
    // xios: the ANGLE Metal display lives in the render device WaylandBackend created from the iosc_iosurface global;
    // there is no EGL_KHR_platform_gbm to require.
    if (!m_backend->renderDevice()) {
        return false;
    }
    setRenderDevice(m_backend->renderDevice());
    return true;
}

bool WaylandEglBackend::init()
{
    if (!initializeEgl()) {
        qCWarning(KWIN_WAYLAND_BACKEND, "Could not initialize ANGLE Metal EGL");
        return false;
    }
    if (!initRenderingContext()) {
        qCWarning(KWIN_WAYLAND_BACKEND, "Could not initialize rendering context");
        return false;
    }
    // xios: EglBackend::initWayland() builds linux-dmabuf tranches from a DRM scanout device; none exists here and
    // clients use iosc_iosurface instead. All that is left of it is registering as the render backend.
    waylandServer()->setRenderBackend(this);
    return true;
}

bool WaylandEglBackend::initRenderingContext()
{
    if (!createContext()) {
        return false;
    }

    auto waylandOutputs = m_backend->waylandOutputs();

    // we only allow to start with at least one output
    if (waylandOutputs.isEmpty()) {
        return false;
    }

    for (auto *out : waylandOutputs) {
        createOutputLayers(out);
    }

    return openglContext()->makeCurrent();
}

FormatModifierMap WaylandEglBackend::supportedFormats() const
{
    return s_ioscFormats;
}

QList<OutputLayer *> WaylandEglBackend::compatibleOutputLayers(BackendOutput *output)
{
    return static_cast<WaylandOutput *>(output)->outputLayers();
}

}
}

#include "moc_wayland_egl_backend.cpp"
