#!/usr/bin/env python3
# kderestart.py [SLOT]: stop every KDE slot under xios-displays.d, then ask ioscd for a fresh KDE session.
# Prints the new slot once its status reads "up" and plasmashell exists.
import glob, json, os, socket, subprocess, sys, time
for f in glob.glob("/var/jb/tmp/xios-displays.d/*.json"):
    slot = os.path.basename(f)[:-5]
    print("stopping", slot, flush=True)
    subprocess.run(["/var/jb/usr/local/bin/xios-session", "--slot", slot, "stop"])
time.sleep(2)
slot = sys.argv[1] if len(sys.argv) > 1 else ""
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect("/var/jb/tmp/ioscd.sock")
s.sendall(("SESSION\tkde\t\t1440\t1080\t176\t%s\n" % slot).encode())
s.settimeout(5)
try:
    print("ioscd:", s.recv(4096).decode(errors="replace").strip(), flush=True)
except Exception as e:
    print("ioscd: (no reply: %s)" % e, flush=True)
t0 = time.time()
while time.time() - t0 < 120:
    for f in glob.glob("/var/jb/tmp/xios-displays.d/*.json"):
        try:
            d = json.load(open(f))
        except Exception:
            continue
        ps = subprocess.run(["ps", "-Ao", "pid,comm"], capture_output=True, text=True).stdout
        if d.get("state") == "up" and "/plasmashell" in ps:
            print("up", d["slot"], "after %.0f s" % (time.time() - t0), flush=True)
            sys.exit(0)
    time.sleep(1)
print("timeout", flush=True)
sys.exit(1)
