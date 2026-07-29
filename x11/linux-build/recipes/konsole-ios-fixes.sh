#!/usr/bin/env bash
# konsole source surgery for iOS. See konsole.mk.
set -euo pipefail
src=${1:?usage: konsole-ios-fixes.sh /path/to/konsole-source}

# Vt102Emulation implements konsole's INLINE MEDIA escape sequence (audio/video
# pushed through the terminal) with QMediaPlayer + QAudioOutput. This stack has
# no qt6-multimedia, so the header is absent and the build dies on
# "'QMediaPlayer' file not found". Compile the feature out rather than build a
# whole Qt module for it: inline media is a niche extension, and it is NOT the
# terminal bell (that is KNotification + QApplication::beep, which still works).
# Inline IMAGES are untouched -- they use QPixmap and keep working.
python3 - "$src/src/Vt102Emulation.h" "$src/src/Vt102Emulation.cpp" <<'PY'
import sys
from pathlib import Path

hdr, cpp = Path(sys.argv[1]), Path(sys.argv[2])
MARKER = "KONSOLE_HAVE_MULTIMEDIA"

text = hdr.read_text()
if MARKER not in text:
    subs = [
        ("#include <QMediaPlayer>\n",
         "// ios: no qt6-multimedia in this stack; inline media is compiled out.\n"
         "#define KONSOLE_HAVE_MULTIMEDIA 0\n"
         "#if KONSOLE_HAVE_MULTIMEDIA\n#include <QMediaPlayer>\n#endif\n"),
        ("    void deletePlayer(QMediaPlayer::MediaStatus);\n",
         "#if KONSOLE_HAVE_MULTIMEDIA\n    void deletePlayer(QMediaPlayer::MediaStatus);\n#endif\n"),
        ("    QMediaPlayer *player;\n",
         "#if KONSOLE_HAVE_MULTIMEDIA\n    QMediaPlayer *player;\n#endif\n"),
    ]
    for old, new in subs:
        if old not in text:
            raise SystemExit(f"konsole-ios-fixes.sh: header anchor missing: {old.strip()}")
        text = text.replace(old, new, 1)
    hdr.write_text(text)

text = cpp.read_text()
if MARKER not in text:
    old_inc = "#include <QAudioOutput>\n"
    if old_inc not in text:
        raise SystemExit("konsole-ios-fixes.sh: QAudioOutput include not found")
    text = text.replace(old_inc, "#if KONSOLE_HAVE_MULTIMEDIA\n#include <QAudioOutput>\n#endif\n", 1)

    old_block = """        if (inlineMedia) {
            if (player == nullptr) {
                player = new QMediaPlayer(this);
                player->setAudioOutput(new QAudioOutput(player));
                connect(player, &QMediaPlayer::mediaStatusChanged, this, &Vt102Emulation::deletePlayer);
            }
            QBuffer *buffer = new QBuffer(player);
            buffer->setData(tokenData);
            buffer->open(QIODevice::ReadOnly);
            delete (QIODevice *)(player->sourceDevice());
            player->setSourceDevice(buffer);
            player->play();
            return;
        }
"""
    new_block = """#if KONSOLE_HAVE_MULTIMEDIA
        if (inlineMedia) {
            if (player == nullptr) {
                player = new QMediaPlayer(this);
                player->setAudioOutput(new QAudioOutput(player));
                connect(player, &QMediaPlayer::mediaStatusChanged, this, &Vt102Emulation::deletePlayer);
            }
            QBuffer *buffer = new QBuffer(player);
            buffer->setData(tokenData);
            buffer->open(QIODevice::ReadOnly);
            delete (QIODevice *)(player->sourceDevice());
            player->setSourceDevice(buffer);
            player->play();
            return;
        }
#else
        if (inlineMedia) {
            return; // ios: inline media playback needs qt6-multimedia
        }
#endif
"""
    if old_block not in text:
        raise SystemExit("konsole-ios-fixes.sh: inlineMedia block not found")
    text = text.replace(old_block, new_block, 1)

    # the ctor still initialises the member we just compiled out
    old_init = "    , _reportFocusEvents(false)\n    , player(nullptr)\n"
    new_init = ("    , _reportFocusEvents(false)\n"
                "#if KONSOLE_HAVE_MULTIMEDIA\n    , player(nullptr)\n#endif\n")
    if old_init not in text:
        raise SystemExit("konsole-ios-fixes.sh: player initialiser not found")
    text = text.replace(old_init, new_init, 1)

    old_fn = """void Vt102Emulation::deletePlayer(QMediaPlayer::MediaStatus mediaStatus)
{
    if (mediaStatus == QMediaPlayer::EndOfMedia || mediaStatus == QMediaPlayer::InvalidMedia) {
        QIODevice *buffer = (QIODevice *)(player->sourceDevice());
        buffer->deleteLater();
        player->deleteLater();
        player = nullptr;
    }
}
"""
    if old_fn not in text:
        raise SystemExit("konsole-ios-fixes.sh: deletePlayer definition not found")
    text = text.replace(old_fn, "#if KONSOLE_HAVE_MULTIMEDIA\n" + old_fn + "#endif\n", 1)
    cpp.write_text(text)
PY
