#!/usr/bin/env bash
# src/kcm and src/kded are intentionally NOT excluded below: their deps
# (KCMUtils, GlobalAccel, PulseAudioQt, etc.) are already found_package()'d
# unconditionally and staged, and PulseAudio 17 + kglobalacceld both exist in
# this stack now.
set -euo pipefail

src=${1:?usage: plasma-pa-ios-fixes.sh <plasma-pa-source-dir>}

python3 - "$src/CMakeLists.txt" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
s = s.replace(
    """    DocTools
    GlobalAccel""",
    """    GlobalAccel""",
)
s = s.replace("find_package(Canberra REQUIRED)", "find_package(Canberra)")
s = s.replace("add_subdirectory(doc)\n", "# ios: skip docs for first-light build\n")
s = s.replace("add_subdirectory(appiumtests)\n", "# ios: skip appium tests\n")
s = s.replace("ki18n_install(po)\n", "# ios: skip translations\n")
s = s.replace("kdoctools_install(po)\n", "# ios: skip doctools translations\n")
p.write_text(s)
PY

python3 - "$src/src/CMakeLists.txt" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
s = s.replace("    canberracontext.cpp\n", "")
s = s.replace("    Canberra::Canberra\n", "")
p.write_text(s)
PY

python3 - "$src/src/volumefeedback.h" "$src/src/volumefeedback.cpp" <<'PY'
import pathlib, sys
h = pathlib.Path(sys.argv[1])
cpp = pathlib.Path(sys.argv[2])
s = h.read_text()
s = s.replace("\n#include <canberra.h>\n", "\n")
h.write_text(s)
cpp.write_text("""/*
    SPDX-FileCopyrightText: 2016 David Rosca <nowrep@gmail.com>

    SPDX-License-Identifier: LGPL-2.1-only OR LGPL-3.0-only OR LicenseRef-KDE-Accepted-LGPL
*/

#include "volumefeedback.h"

VolumeFeedback::VolumeFeedback(QObject *parent)
    : QObject(parent)
{
}

VolumeFeedback::~VolumeFeedback() = default;

bool VolumeFeedback::isValid() const
{
    return false;
}

void VolumeFeedback::play(quint32 sinkIndex)
{
    Q_UNUSED(sinkIndex)
}

void VolumeFeedback::updateCachedSound()
{
}
""")
PY

python3 - "$src/src/speakertest.cpp" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
p.write_text("""/*
    SPDX-FileCopyrightText: 2014-2015 Harald Sitter <sitter@kde.org>
    SPDX-FileCopyrightText: 2021 Nicolas Fella

    SPDX-License-Identifier: LGPL-2.1-only OR LGPL-3.0-only OR LicenseRef-KDE-Accepted-LGPL
*/

#include "speakertest.h"

SpeakerTest::SpeakerTest(QObject *parent)
    : QObject(parent)
    , m_sink(nullptr)
{
}

PulseAudioQt::Sink *SpeakerTest::sink() const
{
    return m_sink;
}

void SpeakerTest::setSink(PulseAudioQt::Sink *sink)
{
    if (m_sink == sink) {
        return;
    }
    m_sink = sink;
    Q_EMIT sinkChanged();
}

QStringList SpeakerTest::playingChannels() const
{
    return {};
}

void SpeakerTest::playingFinished(const QString &name, int errorCode)
{
    Q_UNUSED(name)
    Q_UNUSED(errorCode)
}

void SpeakerTest::testChannel(const QString &name)
{
    Q_UNUSED(name)
}
""")
PY
