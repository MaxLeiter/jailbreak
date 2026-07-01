// qt-smoke.cpp — first Qt-on-iOS proof for the KDE Plasma Mobile track: a QGuiApplication on the
// offscreen QPA. Exercises QtCore's event loop, the platform plugin loader (finds libqoffscreen in
// /var/jb/usr/lib/qt6/plugins/platforms), and QtGui's font database (fontconfig/freetype), then
// exits 0. No display needed; success == it prints the banner and returns cleanly.
#include <QGuiApplication>
#include <QRasterWindow>
#include <QFontDatabase>
#include <QPainter>
#include <QTimer>
#include <QDebug>

class Win : public QRasterWindow {
protected:
    void paintEvent(QPaintEvent *) override {
        QPainter p(this);
        p.fillRect(QRect(0, 0, width(), height()), Qt::darkBlue);
        p.setPen(Qt::white);
        p.drawText(20, 40, QStringLiteral("Qt %1 on iOS").arg(QString::fromLatin1(qVersion())));
    }
};

int main(int argc, char **argv) {
    QGuiApplication app(argc, argv);
    qInfo() << "qt-smoke: Qt" << qVersion() << "QPA" << QGuiApplication::platformName();
    qInfo() << "qt-smoke: font families:" << QFontDatabase::families().size();
    Win w;
    w.resize(320, 200);
    w.show();
    QTimer::singleShot(0, &app, &QCoreApplication::quit);
    int rc = app.exec();
    qInfo() << "qt-smoke: event loop exited" << rc;
    return rc;
}
