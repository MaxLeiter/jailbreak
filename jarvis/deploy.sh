#!/usr/bin/env bash
# One-command deploy: bundle → sync to iPad → restart the daemon cleanly.
# Reads device coordinates from ../device.env (same as the rest of the repo).
#   ./deploy.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

REPO_ROOT="$(cd .. && pwd)"
[ -f "$REPO_ROOT/device.env" ] && { set -a; . "$REPO_ROOT/device.env"; set +a; }
IP="${THEOS_DEVICE_IP:-MaxsiPad.local}"
PORT="${THEOS_DEVICE_PORT:-22}"
KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSHO=(-o ConnectTimeout=10 -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -i "$KEY")
DEST=/var/jb/var/root/jarvis

echo "==> bundle"
bun build src/server.ts --target bun --outfile dist/server.js

echo "==> sync to $IP:$DEST"
ssh -p "$PORT" "${SSHO[@]}" "root@$IP" "mkdir -p $DEST/public"
scp -P "$PORT" "${SSHO[@]}" dist/server.js .env jarvisctl.sh jarvis-supervisor.sh "root@$IP:$DEST/"
scp -P "$PORT" "${SSHO[@]}" com.max.jarvis.plist "root@$IP:$DEST/"
scp -P "$PORT" "${SSHO[@]}" public/console.html "root@$IP:$DEST/public/"
ssh -p "$PORT" "${SSHO[@]}" "root@$IP" "mkdir -p $DEST/JarvisSpeechHelper.app"
scp -P "$PORT" "${SSHO[@]}" native/JarvisSpeechHelper/JarvisSpeechHelper.m native/JarvisSpeechHelper/Info.plist "root@$IP:$DEST/JarvisSpeechHelper.app/"

echo "==> build speech helper"
ssh -p "$PORT" "${SSHO[@]}" "root@$IP" "cd $DEST/JarvisSpeechHelper.app && clang -fobjc-arc -framework Foundation -framework Speech JarvisSpeechHelper.m -o JarvisSpeechHelper"

echo "==> grant speech helper TCC"
ssh -p "$PORT" "${SSHO[@]}" "root@$IP" "python3 - <<'PY'
import sqlite3, time
path = '/private/var/mobile/Library/TCC/TCC.db'
client = 'com.max.jarvis.speechhelper'
now = int(time.time())
con = sqlite3.connect(path)
cols = [r[1] for r in con.execute('pragma table_info(access)')]
def grant(service):
    vals = {
        'service': service,
        'client': client,
        'client_type': 0,
        'auth_value': 2,
        'auth_reason': 4,
        'auth_version': 1,
        'csreq': None,
        'policy_id': None,
        'indirect_object_identifier_type': 0,
        'indirect_object_identifier': 'UNUSED',
        'indirect_object_code_identity': None,
        'flags': 0,
        'last_modified': now,
        'pid': None,
        'pid_version': None,
        'boot_uuid': 'UNUSED',
        'last_reminded': 0,
    }
    insert_cols = [c for c in cols if c in vals]
    sql = 'insert or replace into access (%s) values (%s)' % (','.join(insert_cols), ','.join(['?'] * len(insert_cols)))
    con.execute(sql, [vals[c] for c in insert_cols])
for svc in ('kTCCServiceSpeechRecognition', 'kTCCServiceMicrophone'):
    grant(svc)
con.commit()
print('granted', client)
PY"

echo "==> mirror dictation prefs for root helper"
ssh -p "$PORT" "${SSHO[@]}" "root@$IP" "python3 - <<'PY'
import os, plistlib, shutil

root_assistant = '/private/var/root/Library/Preferences/com.apple.assistant.support.plist'
mobile_assistant = '/private/var/mobile/Library/Preferences/com.apple.assistant.support.plist'
root_uikit = '/private/var/root/Library/Preferences/com.apple.UIKit.plist'

def load(path):
    if os.path.exists(path):
        with open(path, 'rb') as f:
            return plistlib.load(f)
    return {}

def save(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + '.jarvis-tmp'
    with open(tmp, 'wb') as f:
        plistlib.dump(data, f, fmt=plistlib.FMT_BINARY)
    os.replace(tmp, path)

for path in (root_assistant, root_uikit):
    backup = path + '.jarvis-bak'
    if os.path.exists(path) and not os.path.exists(backup):
        shutil.copy2(path, backup)

mobile = load(mobile_assistant)
assistant = load(root_assistant)
for key in (
    'Assistant Enabled',
    'Dictation Enabled',
    'Dictation Allowed',
    'Suppress Dictation Opt In',
    'Siri Data Sharing Opt-In Status',
    'Siri Data Sharing Opt-In Status 2.0',
    'Offline Dictation Status',
):
    if key in mobile:
        assistant[key] = mobile[key]
assistant['Assistant Enabled'] = True
assistant['Dictation Enabled'] = True
assistant['Dictation Allowed'] = True
assistant.setdefault('Suppress Dictation Opt In', False)
save(root_assistant, assistant)

uikit = load(root_uikit)
uikit['Dictation Enabled'] = True
uikit['Dictation Allowed'] = True
save(root_uikit, uikit)
print('mirrored dictation prefs for root')
PY
launchctl kickstart -k system/com.apple.cfprefsd 2>/dev/null || killall cfprefsd 2>/dev/null || true"

echo "==> install launch daemon"
ssh -p "$PORT" "${SSHO[@]}" "root@$IP" "mkdir -p /var/jb/Library/LaunchDaemons
cp $DEST/com.max.jarvis.plist /var/jb/Library/LaunchDaemons/com.max.jarvis.plist
chmod 644 /var/jb/Library/LaunchDaemons/com.max.jarvis.plist
chmod 755 $DEST/jarvisctl.sh $DEST/jarvis-supervisor.sh
launchctl bootout system /var/jb/Library/LaunchDaemons/com.max.jarvis.plist 2>/dev/null || true
launchctl bootout user/501 /var/jb/Library/LaunchDaemons/com.max.jarvis.plist 2>/dev/null || true
sh $DEST/jarvisctl.sh stop
launchctl bootstrap system /var/jb/Library/LaunchDaemons/com.max.jarvis.plist 2>/dev/null || true"

echo "==> restart"
ssh -p "$PORT" "${SSHO[@]}" "root@$IP" "sh $DEST/jarvisctl.sh restart"

echo "==> live at http://$IP:8787"
