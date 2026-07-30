/*  Part of the xios port of powerdevil (see recipes/powerdevil-ios-fixes.sh).

    SPDX-License-Identifier: LGPL-2.0-only
*/

#include "xiosbacklight.h"

#include <powerdevil_debug.h>

#include <QDir>
#include <QFile>

/* Same root xios-hwbridged publishes: it takes <sys> from XIOS_SYS and otherwise
 * defaults to DEFAULT_SYS_ROOT, so keep both halves in step with that daemon.
 *
 * The guard mirrors xios-hwbridged.c and xios-sensord.m, whose builder passes
 * -DDEFAULT_SYS_ROOT="$TARGET_SYS_ROOT" from the target descriptor (/var/jb/sys
 * rootless, /sys rootful). This file had the value hardcoded, so it could not
 * follow them off rootless. The default is unchanged; powerdevil's recipe still
 * needs to pass the define before a rootful KDE build would be correct. */
#ifndef DEFAULT_SYS_ROOT
#define DEFAULT_SYS_ROOT "/var/jb/sys"
#endif

static QString backlightRoot()
{
    const QByteArray sysDir = qgetenv("XIOS_SYS");
    const QString root = sysDir.isEmpty() ? QStringLiteral(DEFAULT_SYS_ROOT) : QString::fromLocal8Bit(sysDir);
    return root + QStringLiteral("/class/backlight");
}

static bool readSysInt(const QString &path, int *value)
{
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly | QIODevice::Text)) {
        return false;
    }
    bool ok = false;
    const int parsed = file.readAll().trimmed().toInt(&ok);
    if (!ok) {
        return false;
    }
    *value = parsed;
    return true;
}

XiosBacklightBrightness::XiosBacklightBrightness(const QString &sysPath, int cachedBrightness, int maxBrightness, QObject *parent)
    : DisplayBrightness(parent)
    , m_sysPath(sysPath)
    , m_brightness(cachedBrightness)
    , m_maxBrightness(maxBrightness)
{
    /* The panel is not ours alone: iOS auto-brightness and Control Center move it
     * too, and xios-hwbridged writes the new value back into the node. Poll so the
     * slider follows instead of showing a value the screen no longer has. sysfs is
     * not inotify-backed here, so QFileSystemWatcher would not fire. */
    m_refreshTimer.setInterval(10000);
    m_refreshTimer.callOnTimeout(this, &XiosBacklightBrightness::refresh);
    m_refreshTimer.start();
}

int XiosBacklightBrightness::knownSafeMinBrightness() const
{
    /* 0 is a fully dark panel on this hardware, which reads as a broken screen
     * rather than a dim one. Brightness is not the way to turn the display off. */
    return 1;
}

int XiosBacklightBrightness::maxBrightness() const
{
    return m_maxBrightness;
}

int XiosBacklightBrightness::brightness() const
{
    return m_brightness;
}

void XiosBacklightBrightness::setBrightness(int brightness)
{
    const int clamped = qBound(0, brightness, m_maxBrightness);

    QFile file(m_sysPath + QStringLiteral("/brightness"));
    if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text)) {
        qCWarning(POWERDEVIL) << "[XiosBacklight]: cannot write brightness to" << m_sysPath << file.errorString();
        return;
    }
    file.write(QByteArray::number(clamped));
    file.close();

    if (m_brightness != clamped) {
        m_brightness = clamped;
        Q_EMIT brightnessChanged(m_brightness, m_maxBrightness);
    }
}

void XiosBacklightBrightness::refresh()
{
    /* actual_brightness is what the bridge reports the hardware settled on, which
     * is the honest value to show; brightness alone is the last requested one. */
    int value = 0;
    if (!readSysInt(m_sysPath + QStringLiteral("/actual_brightness"), &value) //
        && !readSysInt(m_sysPath + QStringLiteral("/brightness"), &value)) {
        return;
    }
    if (value != m_brightness) {
        m_brightness = value;
        Q_EMIT brightnessChanged(m_brightness, m_maxBrightness);
    }
}

XiosBacklightDetector::XiosBacklightDetector(QObject *parent)
    : DisplayBrightnessDetector(parent)
{
}

void XiosBacklightDetector::detect()
{
    m_display.reset();
    m_displayList.clear();

    /* Enumerate rather than hardcoding xios_backlight, the way a Linux backlight
     * consumer would: the first node exposing both files wins. */
    const QDir root(backlightRoot());
    const QStringList candidates = root.entryList(QDir::Dirs | QDir::NoDotAndDotDot);

    for (const QString &candidate : candidates) {
        const QString sysPath = root.filePath(candidate);
        int maxBrightness = 0;
        int cachedBrightness = 0;

        if (!readSysInt(sysPath + QStringLiteral("/max_brightness"), &maxBrightness) || maxBrightness <= 0) {
            continue;
        }
        if (!readSysInt(sysPath + QStringLiteral("/brightness"), &cachedBrightness)) {
            continue;
        }

        qCDebug(POWERDEVIL) << "[XiosBacklight]: using" << sysPath << "brightness" << cachedBrightness << "of" << maxBrightness;
        m_display = std::make_unique<XiosBacklightBrightness>(sysPath, cachedBrightness, maxBrightness, this);
        m_displayList = {m_display.get()};
        Q_EMIT detectionFinished(true);
        return;
    }

    /* No node means xios-hwbridged is not running. That is a legitimate state
     * (a bare compositor session), so report unsupported rather than warn. */
    qCDebug(POWERDEVIL) << "[XiosBacklight]: no backlight node under" << root.path();
    Q_EMIT detectionFinished(false);
}

QList<DisplayBrightness *> XiosBacklightDetector::displays() const
{
    return m_displayList;
}
