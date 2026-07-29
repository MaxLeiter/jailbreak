#!/usr/bin/env bash
# Wayland popup fixes for QtWayland on iOS.
set -euo pipefail

src=${1:?usage: layer-shell-qt-ios-fixes.sh <layer-shell-qt-source-dir>}

python3 - "$src/src/qwaylandlayershellintegration_p.h" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace(
    "#include <qwayland-wlr-layer-shell-unstable-v1.h>\n",
    "#include <qwayland-wlr-layer-shell-unstable-v1.h>\n#include <qwayland-xdg-shell.h>\n",
)
text = text.replace(
    "class QWaylandXdgActivationV1;\nclass QWaylandLayerXdgWmBase;\n",
    "class QWaylandXdgActivationV1;\n",
)
text = text.replace(
    "namespace LayerShellQt\n{\n\nclass QWaylandLayerXdgWmBase;\n",
    "namespace LayerShellQt\n{\n\nclass QWaylandLayerXdgWmBase;\n",
)
text = text.replace(
    "namespace LayerShellQt\n{\n\nclass Window;",
    "namespace LayerShellQt\n{\n\nclass QWaylandLayerXdgWmBase;\nclass Window;",
)
text = text.replace(
    "namespace LayerShellQt\n{\n\nclass LAYERSHELLQT_EXPORT QWaylandLayerShellIntegration",
    "namespace LayerShellQt\n{\n\nclass QWaylandLayerXdgWmBase;\n\nclass LAYERSHELLQT_EXPORT QWaylandLayerShellIntegration",
)
old = """    QtWaylandClient::QWaylandShellSurface *createShellSurface(QtWaylandClient::QWaylandWindow *window) override;

private:
    QScopedPointer<QWaylandXdgActivationV1> m_xdgActivation;
"""
new = """    QWaylandLayerXdgWmBase *xdgWmBase() const
    {
        return m_xdgWmBase.data();
    }
    QtWaylandClient::QWaylandShellSurface *createShellSurface(QtWaylandClient::QWaylandWindow *window) override;

private:
    QScopedPointer<QWaylandXdgActivationV1> m_xdgActivation;
    QScopedPointer<QWaylandLayerXdgWmBase> m_xdgWmBase;
"""
if "QWaylandLayerXdgWmBase *xdgWmBase() const" in text:
    pass
elif old in text:
    text = text.replace(old, new)
else:
    raise SystemExit("layer-shell integration header block not found")
while "#include <qwayland-xdg-shell.h>\n#include <qwayland-xdg-shell.h>\n" in text:
    text = text.replace(
        "#include <qwayland-xdg-shell.h>\n#include <qwayland-xdg-shell.h>\n",
        "#include <qwayland-xdg-shell.h>\n",
    )
xdg_wm_base_getter = """    QWaylandLayerXdgWmBase *xdgWmBase() const
    {
        return m_xdgWmBase.data();
    }
"""
while text.count(xdg_wm_base_getter) > 1:
    text = text.replace(xdg_wm_base_getter + xdg_wm_base_getter, xdg_wm_base_getter)
xdg_wm_base_member = "    QScopedPointer<QWaylandLayerXdgWmBase> m_xdgWmBase;\n"
while text.count(xdg_wm_base_member) > 1:
    text = text.replace(xdg_wm_base_member + xdg_wm_base_member, xdg_wm_base_member)
path.write_text(text)
PY

python3 - "$src/src/qwaylandlayershellintegration.cpp" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace(
    "#include \"qwaylandlayershellintegration_p.h\"\n",
    "#include \"qwaylandlayershellintegration_p.h\"\n#include \"layershellqt_logging.h\"\n",
)
text = text.replace(
    "#include <QtWaylandClient/private/qwaylandwindow_p.h>\n",
    "#include <QtWaylandClient/private/qwaylandwindow_p.h>\n\n#include <QGuiApplication>\n#include <QVariant>\n#include <QWindow>\n",
)
old_ctor = """QWaylandLayerShellIntegration::QWaylandLayerShellIntegration()
    : QWaylandShellIntegrationTemplate<QWaylandLayerShellIntegration>(5)
    , m_xdgActivation(new QWaylandXdgActivationV1)
{
}
"""
new_ctor = """QWaylandLayerShellIntegration::QWaylandLayerShellIntegration()
    : QWaylandShellIntegrationTemplate<QWaylandLayerShellIntegration>(5)
    , m_xdgActivation(new QWaylandXdgActivationV1)
    , m_xdgWmBase(new QWaylandLayerXdgWmBase)
{
}
"""
if old_ctor in text:
    text = text.replace(old_ctor, new_ctor)
elif "m_xdgWmBase(new QWaylandLayerXdgWmBase)" not in text:
    raise SystemExit("layer-shell integration ctor not found")

old_create = """QtWaylandClient::QWaylandShellSurface *QWaylandLayerShellIntegration::createShellSurface(QtWaylandClient::QWaylandWindow *window)
{
    return new QWaylandLayerSurface(this, window);
}
"""
new_create = """QtWaylandClient::QWaylandShellSurface *QWaylandLayerShellIntegration::createShellSurface(QtWaylandClient::QWaylandWindow *window)
{
    const Qt::WindowType type = window->window()->type();
    qCWarning(LAYERSHELLQT) << "layershellqt-ios createShellSurface" << window->window() << "type" << type << "transient" << bool(window->transientParent()) << "anchorRect" << window->window()->property("_q_waylandPopupAnchorRect").isValid();
    if (type == Qt::Popup || type == Qt::ToolTip || window->transientParent()) {
        if (m_xdgWmBase && !m_xdgWmBase->isActive()) {
            m_xdgWmBase->ensureInitialized();
        }
        if (m_xdgWmBase && m_xdgWmBase->isActive()) {
            qCWarning(LAYERSHELLQT) << "layershellqt-ios create xdg popup shell surface" << window->window();
            return new QWaylandLayerXdgPopupSurface(this, window);
        }
        qCWarning(LAYERSHELLQT) << "Cannot create layer-shell popup without xdg_wm_base" << type << "transient" << bool(window->transientParent());
        return nullptr;
    }
    qCWarning(LAYERSHELLQT) << "layershellqt-ios create layer shell surface" << window->window();
    return new QWaylandLayerSurface(this, window);
}
"""
if old_create in text:
    text = text.replace(old_create, new_create)
elif "QWaylandLayerXdgPopupSurface(this, window)" not in text:
    raise SystemExit("layer-shell createShellSurface block not found")

insert_after = """namespace LayerShellQt
{
"""
helper = r"""
class QWaylandLayerXdgWmBase : public QWaylandClientExtensionTemplate<QWaylandLayerXdgWmBase>, public QtWayland::xdg_wm_base
{
public:
    QWaylandLayerXdgWmBase()
        : QWaylandClientExtensionTemplate<QWaylandLayerXdgWmBase>(4)
    {
        initialize();
    }

    ~QWaylandLayerXdgWmBase() override
    {
        if (isActive()) {
            destroy();
        }
    }

    void ensureInitialized()
    {
        if (!isActive()) {
            initialize();
        }
    }

protected:
    void xdg_wm_base_ping(uint32_t serial) override
    {
        pong(serial);
    }
};

static QtWaylandClient::QWaylandWindow *layerPopupParent(QtWaylandClient::QWaylandWindow *window)
{
    if (!window) {
        return nullptr;
    }
    if (auto parent = window->transientParent()) {
        return parent;
    }
    if (auto transientWindow = window->window()->transientParent()) {
        if (auto transientWayland = dynamic_cast<QtWaylandClient::QWaylandWindow *>(transientWindow->handle())) {
            if (transientWayland->shellSurface()) {
                return transientWayland;
            }
        }
    }

    const auto windows = QGuiApplication::topLevelWindows();
    for (QWindow *candidate : windows) {
        if (!candidate || candidate == window->window() || !candidate->handle()) {
            continue;
        }
        auto waylandWindow = dynamic_cast<QtWaylandClient::QWaylandWindow *>(candidate->handle());
        if (!waylandWindow || !waylandWindow->shellSurface()) {
            continue;
        }
        if (dynamic_cast<QWaylandLayerSurface *>(waylandWindow->shellSurface())) {
            return waylandWindow;
        }
    }
    return nullptr;
}

class QWaylandLayerXdgPopupSurface : public QtWaylandClient::QWaylandShellSurface, public QtWayland::xdg_surface
{
public:
    QWaylandLayerXdgPopupSurface(QWaylandLayerShellIntegration *shell, QtWaylandClient::QWaylandWindow *window)
        : QtWaylandClient::QWaylandShellSurface(window)
        , m_window(window)
        , m_parent(layerPopupParent(window))
    {
        init(shell->xdgWmBase()->get_xdg_surface(window->wlSurface()));

        auto positioner = new QtWayland::xdg_positioner(shell->xdgWmBase()->create_positioner());
        const QRect windowGeometry = m_window->windowContentGeometry();
        QRect placementAnchor = m_window->window()->property("_q_waylandPopupAnchorRect").toRect();
        if (!placementAnchor.isValid()) {
            placementAnchor = QRect(QPoint(0, 0), QSize(1, 1));
            if (m_parent) {
                placementAnchor.moveTopLeft(m_window->geometry().topLeft() - m_parent->geometry().topLeft());
            }
        }

        uint32_t anchor = QtWayland::xdg_positioner::anchor_top_left;
        const QVariant anchorVariant = m_window->window()->property("_q_waylandPopupAnchor");
        if (anchorVariant.isValid()) {
            switch (anchorVariant.value<Qt::Edges>()) {
            case Qt::Edges():
                anchor = QtWayland::xdg_positioner::anchor_none;
                break;
            case Qt::TopEdge:
                anchor = QtWayland::xdg_positioner::anchor_top;
                break;
            case Qt::TopEdge | Qt::RightEdge:
                anchor = QtWayland::xdg_positioner::anchor_top_right;
                break;
            case Qt::RightEdge:
                anchor = QtWayland::xdg_positioner::anchor_right;
                break;
            case Qt::BottomEdge | Qt::RightEdge:
                anchor = QtWayland::xdg_positioner::anchor_bottom_right;
                break;
            case Qt::BottomEdge:
                anchor = QtWayland::xdg_positioner::anchor_bottom;
                break;
            case Qt::BottomEdge | Qt::LeftEdge:
                anchor = QtWayland::xdg_positioner::anchor_bottom_left;
                break;
            case Qt::LeftEdge:
                anchor = QtWayland::xdg_positioner::anchor_left;
                break;
            case Qt::TopEdge | Qt::LeftEdge:
                anchor = QtWayland::xdg_positioner::anchor_top_left;
                break;
            }
        }

        uint32_t gravity = QtWayland::xdg_positioner::gravity_bottom_left;
        const QVariant gravityVariant = m_window->window()->property("_q_waylandPopupGravity");
        if (gravityVariant.isValid()) {
            switch (gravityVariant.value<Qt::Edges>()) {
            case Qt::Edges():
                gravity = QtWayland::xdg_positioner::gravity_none;
                break;
            case Qt::TopEdge:
                gravity = QtWayland::xdg_positioner::gravity_top;
                break;
            case Qt::TopEdge | Qt::RightEdge:
                gravity = QtWayland::xdg_positioner::gravity_top_right;
                break;
            case Qt::RightEdge:
                gravity = QtWayland::xdg_positioner::gravity_right;
                break;
            case Qt::BottomEdge | Qt::RightEdge:
                gravity = QtWayland::xdg_positioner::gravity_bottom_right;
                break;
            case Qt::BottomEdge:
                gravity = QtWayland::xdg_positioner::gravity_bottom;
                break;
            case Qt::BottomEdge | Qt::LeftEdge:
                gravity = QtWayland::xdg_positioner::gravity_bottom_left;
                break;
            case Qt::LeftEdge:
                gravity = QtWayland::xdg_positioner::gravity_left;
                break;
            case Qt::TopEdge | Qt::LeftEdge:
                gravity = QtWayland::xdg_positioner::gravity_top_left;
                break;
            }
        }

        uint32_t constraintAdjustment = QtWayland::xdg_positioner::constraint_adjustment_slide_x | QtWayland::xdg_positioner::constraint_adjustment_slide_y;
        const QVariant constraintVariant = m_window->window()->property("_q_waylandPopupConstraintAdjustment");
        if (constraintVariant.isValid()) {
            constraintAdjustment = constraintVariant.toUInt();
        }

        positioner->set_anchor_rect(placementAnchor.x(), placementAnchor.y(), placementAnchor.width(), placementAnchor.height());
        positioner->set_anchor(anchor);
        positioner->set_gravity(gravity);
        positioner->set_size(qMax(1, windowGeometry.width()), qMax(1, windowGeometry.height()));
        positioner->set_constraint_adjustment(constraintAdjustment);

        auto parentShell = m_parent ? m_parent->shellSurface() : nullptr;
        auto layerParent = dynamic_cast<QWaylandLayerSurface *>(parentShell);
        ::xdg_surface *xdgParent = nullptr;
        if (!layerParent) {
            if (auto popupParent = dynamic_cast<QWaylandLayerXdgPopupSurface *>(parentShell)) {
                xdgParent = popupParent->xdgSurfaceObject();
            }
        }
        qCWarning(LAYERSHELLQT) << "layershellqt-ios popup ctor" << m_window->window() << "parent" << (m_parent ? m_parent->window() : nullptr) << "layerParent" << bool(layerParent) << "xdgParent" << bool(xdgParent) << "parentShell" << (parentShell ? parentShell->surfaceRole().type().name() : "none");

        // wlr-layer-shell requires layer-surface children to be created as
        // xdg_popup with a null xdg parent; QWaylandLayerSurface::attachPopup()
        // then assigns the layer surface as the popup's effective parent before
        // the first commit. Nested/ordinary popups must instead use their xdg
        // parent at xdg_surface.get_popup() time or KWin rejects them.
        m_popup = new Popup(this, get_popup(xdgParent, positioner->object()));
        m_popupObject = m_popup->object();
        if (layerParent) {
            qCWarning(LAYERSHELLQT) << "layershellqt-ios attach popup to layer parent";
            layerParent->attachPopup(this);
            m_window->display()->flushRequests();
        } else if (!xdgParent) {
            qCWarning(LAYERSHELLQT) << "Cannot attach layer-shell popup: no layer or xdg parent window";
        } else if (parentShell) {
            qCWarning(LAYERSHELLQT) << "layershellqt-ios notify xdg popup parent";
            parentShell->attachPopup(this);
            m_window->display()->flushRequests();
        } else {
            qCWarning(LAYERSHELLQT) << "Cannot attach layer-shell popup: no layer parent window";
        }
        positioner->destroy();
        delete positioner;
    }

    ~QWaylandLayerXdgPopupSurface() override
    {
        delete m_popup;
        m_popup = nullptr;
        if (isInitialized()) {
            destroy();
        }
    }

    std::any surfaceRole() const override
    {
        return m_popupObject ? std::any(m_popupObject) : std::any();
    }

    ::xdg_surface *xdgSurfaceObject()
    {
        return object();
    }

    bool isExposed() const override
    {
        return m_configured || m_pendingConfigureSerial;
    }

    bool handleExpose(const QRegion &region) override
    {
        if (!isExposed() && !region.isEmpty()) {
            m_exposeRegion = region;
            return true;
        }
        return false;
    }

    void applyConfigure() override
    {
        if (m_pendingConfigureSerial == m_appliedConfigureSerial) {
            return;
        }

        if (m_pendingGeometry.isValid()) {
            if (m_parent) {
                const QMargins parentMargins = m_parent->windowContentMargins() - m_parent->clientSideMargins();
                const QRect globalGeometry = m_pendingGeometry.translated(m_parent->geometry().topLeft() + QPoint(parentMargins.left(), parentMargins.top()));
                setGeometryFromApplyConfigure(globalGeometry.topLeft(), globalGeometry.size());
            } else {
                setGeometryFromApplyConfigure(m_pendingGeometry.topLeft(), m_pendingGeometry.size());
            }
        }

        m_appliedConfigureSerial = m_pendingConfigureSerial;
        m_configured = true;
        ack_configure(m_appliedConfigureSerial);

        if (!m_exposeRegion.isEmpty()) {
            m_window->handleExpose(m_exposeRegion);
            m_exposeRegion = QRegion();
        }
    }

    void setWindowGeometry(const QRect &rect) override
    {
        set_window_geometry(rect.x(), rect.y(), rect.width(), rect.height());
    }

protected:
    void xdg_surface_configure(uint32_t serial) override
    {
        m_pendingConfigureSerial = serial;
        if (!m_configured) {
            applyConfigure();
            m_exposeRegion = QRegion(QRect(QPoint(), m_window->geometry().size()));
        } else {
            m_window->applyConfigureWhenPossible();
        }
    }

private:
    class Popup : public QtWayland::xdg_popup
    {
    public:
        Popup(QWaylandLayerXdgPopupSurface *surface, ::xdg_popup *popup)
            : QtWayland::xdg_popup(popup)
            , m_surface(surface)
        {
        }

        ~Popup() override
        {
            if (isInitialized()) {
                destroy();
            }
        }

    protected:
        void xdg_popup_configure(int32_t x, int32_t y, int32_t width, int32_t height) override
        {
            m_surface->m_pendingGeometry = QRect(x, y, width, height);
        }

        void xdg_popup_popup_done() override
        {
            m_surface->m_window->window()->close();
        }

    private:
        QWaylandLayerXdgPopupSurface *m_surface = nullptr;
    };

    QtWaylandClient::QWaylandWindow *m_window = nullptr;
    QtWaylandClient::QWaylandWindow *m_parent = nullptr;
    Popup *m_popup = nullptr;
    ::xdg_popup *m_popupObject = nullptr;
    QRect m_pendingGeometry;
    QRegion m_exposeRegion;
    uint m_pendingConfigureSerial = 0;
    uint m_appliedConfigureSerial = 0;
    bool m_configured = false;
};

"""
if helper.strip() not in text:
    text = text.replace(insert_after, insert_after + helper, 1)
path.write_text(text)
PY

python3 - "$src/src/qwaylandlayersurface.cpp" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace("#include <QGuiApplication>\n", "#include <QGuiApplication>\n#include <QPointer>\n#include <QTimer>\n")
old = """void QWaylandLayerSurface::attachPopup(QtWaylandClient::QWaylandShellSurface *popup)
{
    std::any anyRole = popup->surfaceRole();

    if (auto role = std::any_cast<::xdg_popup *>(&anyRole)) {
        get_popup(*role);
    } else {
        qCWarning(LAYERSHELLQT) << "Cannot attach popup of unknown type";
    }
}
"""
new = """void QWaylandLayerSurface::attachPopup(QtWaylandClient::QWaylandShellSurface *popup)
{
    if (!popup) {
        return;
    }

    auto xdgPopupFromRole = [](const std::any &role) -> ::xdg_popup * {
        if (auto raw = std::any_cast<::xdg_popup *>(&role)) {
            return *raw;
        }
        if (auto rawVoid = std::any_cast<void *>(&role)) {
            return reinterpret_cast<::xdg_popup *>(*rawVoid);
        }
        if (auto generated = std::any_cast<QtWayland::xdg_popup *>(&role)) {
            return *generated ? (*generated)->object() : nullptr;
        }
        return nullptr;
    };

    std::any anyRole = popup->surfaceRole();

    if (auto role = xdgPopupFromRole(anyRole)) {
        qCWarning(LAYERSHELLQT) << "layershellqt-ios layer get_popup immediate" << role;
        get_popup(role);
        window()->display()->flushRequests();
    } else {
        // QtWayland can notify the layer-shell parent before the child popup's
        // xdg role object is visible through surfaceRole(). Retry on the next
        // event-loop turn so zwlr_layer_surface.get_popup() is still sent
        // before the popup commits without a parent.
        QPointer<QtWaylandClient::QWaylandShellSurface> guardedPopup(popup);
        QTimer::singleShot(0, this, [this, guardedPopup, xdgPopupFromRole]() {
            if (!guardedPopup) {
                return;
            }
            std::any retryRole = guardedPopup->surfaceRole();
            if (auto retry = xdgPopupFromRole(retryRole)) {
                qCWarning(LAYERSHELLQT) << "layershellqt-ios layer get_popup retry" << retry;
                get_popup(retry);
                window()->display()->flushRequests();
            } else {
                qCWarning(LAYERSHELLQT) << "Cannot attach popup of unknown type" << retryRole.type().name();
            }
        });
    }
}
"""
if old not in text:
    if "QtWayland can notify the layer-shell parent before the child popup" not in text:
        raise SystemExit("attachPopup block not found")
else:
    text = text.replace(old, new)
text = text.replace(
    "QTimer::singleShot(0, this, [this, guardedPopup]() {",
    "QTimer::singleShot(0, this, [this, guardedPopup, xdgPopupFromRole]() {",
)
path.write_text(text)
PY
