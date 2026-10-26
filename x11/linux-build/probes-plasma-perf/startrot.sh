#!/bin/bash
# startrot.sh RUNS [DELAY_S...] (on the Mac, from the repo root): the real start+rotate flow, RUNS times. Stop the
# slot, ask ioscd for a landscape KDE session (1440x1080), wait until its display json says "up" plus DELAY, then tap
# the slot's card in Xios through ipadctld (the iPad is held portrait, so Xios attaches and rotates the output to
# portrait while plasmashell is still starting). 30 s later rotcheck.py judges the session. Stops at the first wedge
# after sampling KWin, plasmashell and iosc with fpsample into /var/jb/tmp/pp/wedge-*.txt, and leaves it wedged.
# Needs: ipadctld running (ipadctl/daemon/deploy.sh start), the Xios launcher on screen with the slot's card in the
# first position (CARD_X/CARD_Y, point space), and fpsample + rotcheck.py in /var/jb/tmp/pp on the device.
set -u
SLOT=${SLOT:-kde-0b85}
HOST=${HOST:-root@MaxsiPad.local}
CARD_X=${CARD_X:-208}
CARD_Y=${CARD_Y:-228}
TOKEN=${IPADCTL_TOKEN:-$(ssh "$HOST" cat /var/jb/var/root/ipadctl/token)}
runs=$1; shift
delays=("$@"); [ ${#delays[@]} -gt 0 ] || delays=(0 0.5 1 1.5 2)
ok=0; invalid=0; i=0
for ((i = 0; i < runs; i++)); do
  d=${delays[$((i % ${#delays[@]}))]}
  ssh "$HOST" "/var/jb/usr/local/bin/xios-session --slot $SLOT stop >/dev/null 2>&1; sleep 2; python3 - $SLOT" <<'EOF'
import json, socket, sys, time
slot = sys.argv[1]
c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); c.connect("/var/jb/tmp/ioscd.sock")
c.sendall(("SESSION\tkde\t\t1440\t1080\t176\t%s\n" % slot).encode()); c.settimeout(10)
print(c.recv(200).decode().strip(), end=", ")
t0 = time.time()
while time.time() - t0 < 60:
    try:
        if json.load(open("/var/jb/tmp/xios-displays.d/%s.json" % slot)).get("state") == "up": break
    except Exception: pass
    time.sleep(0.1)
print("slot up after %.1f s" % (time.time() - t0))
EOF
  sleep "$d"
  curl -s -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -X POST "http://${HOST#*@}:8790/v1/actions" \
    -d "{\"actions\":[{\"type\":\"tap\",\"x\":$CARD_X,\"y\":$CARD_Y,\"app\":\"com.max.xios\",\"target\":\"$SLOT card\",\"why\":\"present the slot during plasmashell startup\"}]}" >/dev/null
  echo "run $i: card tapped ${d}s after up"
  sleep 30
  ssh "$HOST" "python3 /var/jb/tmp/pp/rotcheck.py $SLOT"; rc=$?
  if [ $rc = 0 ]; then
    ok=$((ok + 1))
  elif [ $rc = 2 ]; then
    invalid=$((invalid + 1))
  else
    echo "WEDGED on run $i; sampling"
    ssh "$HOST" "for n in kwin_wayland plasmashell iosc; do p=\$(ps -Ao pid,comm | grep \"/\$n\\\$\" | awk '{print \$1}' | head -1); [ -n \"\$p\" ] && /var/jb/tmp/pp/fpsample \$p 2 20000 /var/jb/tmp/pp/wedge-\$n.txt every; done; cp /var/jb/tmp/kde-plasma-$SLOT.log /var/jb/tmp/pp/wedge-kde.log"
    i=$((i + 1))
    break
  fi
done
echo "$ok/$i OK, $invalid invalid (Xios never rotated the output)"
