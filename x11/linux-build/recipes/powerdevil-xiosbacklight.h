/*  Part of the xios port of powerdevil (see recipes/powerdevil-ios-fixes.sh).

    SPDX-License-Identifier: LGPL-2.0-only
*/

#pragma once

#include "displaybrightness.h"

#include <QString>
#include <QTimer>

#include <memory>

/**
 * Brightness of the internal panel, via the synthetic sysfs backlight that
 * xios-hwbridged (xios-fhs) publishes under <sys>/class/backlight. The bridge
 * watches that directory and forwards writes to BackBoardServices, so this is a
 * real control surface, not a file that only records intent.
 *
 * Upstream reaches the same node through BacklightDetector, which needs libudev
 * for change notification and a KAuth/polkit helper for the privileged write.
 * Neither exists here, and neither is needed: the node is owned by the user the
 * session runs as. This detector therefore talks to sysfs directly.
 */
class XiosBacklightBrightness : public DisplayBrightness
{
    Q_OBJECT

public:
    explicit XiosBacklightBrightness(const QString &sysPath, int cachedBrightness, int maxBrightness, QObject *parent = nullptr);

    int knownSafeMinBrightness() const override;
    int maxBrightness() const override;
    int brightness() const override;
    void setBrightness(int brightness) override;

private:
    void refresh();

    const QString m_sysPath;
    int m_brightness;
    const int m_maxBrightness;
    QTimer m_refreshTimer;
};

class XiosBacklightDetector : public DisplayBrightnessDetector
{
    Q_OBJECT

public:
    explicit XiosBacklightDetector(QObject *parent = nullptr);

    void detect() override;
    QList<DisplayBrightness *> displays() const override;

private:
    std::unique_ptr<XiosBacklightBrightness> m_display;
    QList<DisplayBrightness *> m_displayList;
};
