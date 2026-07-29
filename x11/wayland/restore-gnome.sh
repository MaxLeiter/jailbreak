#!/usr/bin/env bash
# Run from the Mac: bash x11/wayland/restore-gnome.sh
#
# Uses `xios-session -d gnome` (launchd-owned) so gnome-shell survives this ssh session
# closing — a direct manual launch would die as an sshd child when the connection drops.
# Missing typelibs? regen scripts + flag table are in docs/handoff/gnome-session.md.
set -u
DEV="${DEVICE:-root@MaxsiPad.local}"
KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=20 -o IdentitiesOnly=yes -i "$KEY" "$DEV")

echo "==> (0) device reachable?"
"${SSH[@]}" 'echo ok' >/dev/null 2>&1 || { echo "!! $DEV unreachable — power on + re-jailbreak first"; exit 1; }

echo "==> (1) verify persistent GNOME artifacts"
"${SSH[@]}" 'bash -s' <<'EOSH'
GIR=/var/jb/usr/lib/girepository-1.0
ok=1
for t in Atk-1.0 Atspi-2.0 Gck-2 Gcr-4 GnomeDesktop-4.0 GWeather-4.0 St-14 Shell-14 Gdm-1.0; do
  f="$GIR/$t.typelib"
  if [ -f "$f" ] && [ "$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f")" -gt 1000 ]; then
    printf '   OK   %-16s %s bytes\n' "$t" "$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f")"
  else printf '   MISS %-16s (regen needed — see handoff flag table)\n' "$t"; ok=0; fi
done
gs=/var/jb/usr/bin/gnome-shell
[ -x "$gs" ] && printf '   gnome-shell: installed, atk_bridge refs=%s (want 0)\n' "$(grep -ac atk_bridge_adaptor_init "$gs")" || { echo '   MISS gnome-shell binary'; ok=0; }
[ -f /var/jb/usr/lib/libgweather-4/Locations.bin ] && echo '   OK   Locations.bin' || { echo '   MISS Locations.bin'; ok=0; }
[ -f /var/jb/usr/share/glib-2.0/schemas/org.gnome.login-screen.gschema.xml ] && echo '   OK   login-screen schema' || { echo '   MISS login-screen schema'; ok=0; }
[ "$ok" = 1 ] && echo '   >>> persistent state INTACT' || echo '   >>> some artifacts MISSING — regenerate before launch (see handoff)'
EOSH

echo "==> (2) re-assert the libatk-bridge weak-import (persists, but harmless to re-apply)"
"${SSH[@]}" 'bash -s' <<'EOSH'
BR=/var/jb/usr/lib/libatk-bridge-2.0.0.dylib
if [ -f /var/jb/tmp/macho-chained-weaken.py ] && [ -f "$BR" ]; then
  python3 /var/jb/tmp/macho-chained-weaken.py "$BR" \
    _atk_document_get_text_selections _atk_document_set_text_selections _atk_object_get_help_text >/dev/null 2>&1 \
    && ldid -S "$BR" && echo '   libatk-bridge weak-import re-applied'
else
  echo '   (macho-chained-weaken.py not on device — skip; if gnome-shell dies on _atk_document_get_text_selections, re-copy tools/macho-chained-weaken.py and re-run)'
fi
EOSH

echo "==> (3) request the gnome preset via ioscd SESSION (PERSISTENT)"
"${SSH[@]}" 'bash -s' <<'EOSH'
export PATH=/var/jb/usr/local/bin:/var/jb/usr/bin:/var/jb/usr/sbin:/var/jb/bin:/var/jb/sbin:$PATH
if command -v xios-session >/dev/null 2>&1; then
  echo '   launching via ioscd: xios-session -d gnome'
  xios-session -d gnome
else
  echo '   xios-session CLI missing; install xios-session first' >&2
  exit 1
fi
EOSH

echo "==> (4) wait for GNOME to paint, then confirm it PERSISTS after this ssh session closes"
"${SSH[@]}" 'bash -lc "export PATH=/var/jb/usr/local/bin:/var/jb/usr/bin:/var/jb/usr/sbin:/var/jb/bin:/var/jb/sbin:\$PATH; for i in \$(seq 1 40); do grep -q \"GNOME Shell started\" /var/jb/tmp/gnome-shell.log 2>/dev/null && { echo painted; break; }; sleep 0.5; done; echo status:; xios-session status 2>/dev/null"'
echo "   (reconnect in ~20s and run: ssh $DEV 'ps ax|grep -c [g]nome-shell' — expect 1, proving it survived ssh close)"
echo "==> done. Unlock the iPad screen so the Xios Metal app can present."
