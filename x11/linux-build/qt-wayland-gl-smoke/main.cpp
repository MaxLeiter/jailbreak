#include <QGuiApplication>
#include <QOpenGLContext>
#include <QOpenGLFunctions>
#include <QSurfaceFormat>
#include <QTimer>
#include <QWindow>

#include <cstdio>

class SmokeWindow final : public QWindow, protected QOpenGLFunctions {
public:
    SmokeWindow()
    {
        setTitle(QStringLiteral("Qt Wayland GL Smoke"));
        resize(420, 260);
        setSurfaceType(QWindow::OpenGLSurface);

        QSurfaceFormat fmt;
        fmt.setRenderableType(QSurfaceFormat::OpenGLES);
        fmt.setVersion(2, 0);
        fmt.setProfile(QSurfaceFormat::NoProfile);
        fmt.setSwapBehavior(QSurfaceFormat::DoubleBuffer);
        setFormat(fmt);
    }

    bool initialize()
    {
        m_context.setFormat(format());
        if (!m_context.create()) {
            std::fprintf(stderr, "qt-wayland-gl-smoke: failed to create QOpenGLContext\n");
            return false;
        }
        if (!m_context.makeCurrent(this)) {
            std::fprintf(stderr, "qt-wayland-gl-smoke: failed to make context current\n");
            return false;
        }
        initializeOpenGLFunctions();
        m_context.doneCurrent();
        return true;
    }

    void renderFrame()
    {
        if (!isExposed())
            return;
        if (!m_context.makeCurrent(this)) {
            std::fprintf(stderr, "qt-wayland-gl-smoke: makeCurrent failed during frame\n");
            return;
        }

        const float phase = (m_frame % 180) / 179.0f;
        glViewport(0, 0, width(), height());
        glClearColor(0.08f + phase * 0.25f, 0.16f, 0.42f - phase * 0.18f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);
        m_context.swapBuffers(this);
        m_context.doneCurrent();
        ++m_frame;
    }

private:
    QOpenGLContext m_context;
    unsigned m_frame = 0;
};

int main(int argc, char **argv)
{
    qputenv("QT_QPA_PLATFORM", qEnvironmentVariableIsSet("QT_QPA_PLATFORM")
            ? qgetenv("QT_QPA_PLATFORM") : QByteArray("wayland"));
    qputenv("QSG_RHI_BACKEND", qEnvironmentVariableIsSet("QSG_RHI_BACKEND")
            ? qgetenv("QSG_RHI_BACKEND") : QByteArray("opengl"));

    QGuiApplication app(argc, argv);

    SmokeWindow window;
    window.show();
    if (!window.initialize())
        return 2;

    QTimer timer;
    QObject::connect(&timer, &QTimer::timeout, [&window] { window.renderFrame(); });
    timer.start(16);

    return app.exec();
}
