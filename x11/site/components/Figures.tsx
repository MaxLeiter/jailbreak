import type { ReactNode } from "react";
import { Badge } from "@/components/ui";

/* ---- The zero-copy GPU path, as a horizontal flow ---- */
const FLOW = [
  { n: "GTK4 app", s: "GskNgl render" },
  { n: "ANGLE", s: "GLES to Metal, on the A10" },
  { n: "iosc", s: "composite, on the A10" },
  { n: "Xios.app", s: "Metal present" },
  { n: "screen", s: "scanned out", end: true },
];

export function CopyFlow() {
  return (
    <div>
      <div
        className="flow"
        role="img"
        aria-label="A GTK4 app renders with GskNgl, ANGLE turns GLES into Metal on the A10, iosc composites on the A10, Xios.app presents with Metal, and the screen scans it out. No CPU copy anywhere along the path."
      >
        {FLOW.map((node, i) => (
          <div key={node.n} style={{ display: "contents" }}>
            <div className={`flow-node${node.end ? " is-end" : ""}`}>
              <div className="fn-n">{node.n}</div>
              <div className="fn-s">{node.s}</div>
            </div>
            {i < FLOW.length - 1 && (
              <div className="flow-arrow" aria-hidden="true">
                ▶
              </div>
            )}
          </div>
        ))}
      </div>
      <div className="flow-cap">
        one IOSurface, drawn once by the GPU and scanned out by the GPU
      </div>
    </div>
  );
}

/* ---- Hardware and POSIX bridges ---- */
type Bridge = {
  name: string;
  state: "live" | "wip" | "planned";
  body: ReactNode;
};

const HOST_BRIDGES: Bridge[] = [
  {
    name: "xios-input",
    state: "live",
    body: (
      <>
        UIKit touch, Pencil, keys, and scroll become{" "}
        <b>wl_seat</b> and Mutter input over a fixed 24-byte socket wire.
      </>
    ),
  },
  {
    name: "xios-osk",
    state: "live",
    body: (
      <>
        The iOS on-screen keyboard drives <b>text-input-v3</b> and{" "}
        virtual-keyboard, shown and dismissed by a traits broadcast.
      </>
    ),
  },
  {
    name: "xios-audiod",
    state: "live",
    body: (
      <>
        RemoteIO audio out, exposed as a <b>PulseAudio sink</b> that GTK and gvc
        can control.
      </>
    ),
  },
  {
    name: "xios-session-identity",
    state: "live",
    body: (
      <>
        The device name from MobileGestalt becomes a <b>real user</b> for the
        session.
      </>
    ),
  },
  {
    name: "xios-hwbridged",
    state: "wip",
    body: (
      <>
        IOKit battery and BackBoard brightness become <b>UPower</b> and the
        shell&apos;s power slider. Built, not yet device-tested.
      </>
    ),
  },
  {
    name: "xios-sysintd",
    state: "wip",
    body: (
      <>
        Volume buttons, dark mode, rotation, and haptics reach{" "}
        <b>pactl, gsettings, and the compositor</b>.
      </>
    ),
  },
  {
    name: "xios-sensord",
    state: "wip",
    body: (
      <>
        CoreMotion orientation feeds an <b>iio-sensor-proxy</b> shim. Prototype,
        accelerometer only.
      </>
    ),
  },
];

const SESSION_SERVICES: Bridge[] = [
  {
    name: "session stubs",
    state: "live",
    body: (
      <>
        <b>logind, polkit, and Accounts</b> stubs, enough for gnome-session to
        come up.
      </>
    ),
  },
  {
    name: "fonts & theme",
    state: "live",
    body: (
      <>
        SF as the UI font, plus <b>cursor, icon, and wallpaper</b> defaults.
      </>
    ),
  },
  {
    name: "xios-fhs",
    state: "live",
    body: (
      <>
        A rootless <b>/var/jb</b> filesystem bridge with synthetic sysfs the
        daemons refresh.
      </>
    ),
  },
  {
    name: "clipboard bridge",
    state: "wip",
    body: (
      <>
        <b>wl_data_device</b> and UIPasteboard. The app half has landed; the
        compositor half is not wired yet.
      </>
    ),
  },
  {
    name: "AT-SPI to VoiceOver",
    state: "planned",
    body: (
      <>
        A planned bridge from the desktop <b>accessibility tree</b> to VoiceOver.
      </>
    ),
  },
];

function BridgeCard({ b }: { b: Bridge }) {
  return (
    <div className="bridge">
      <div className="b-head">
        <span className="b-name">{b.name}</span>
        <Badge state={b.state} />
      </div>
      <div className="b-body">{b.body}</div>
    </div>
  );
}

export function Bridges() {
  return (
    <div>
      <div className="bridge-group-label">Host bridges (talk to iOS APIs)</div>
      <div className="bridge-grid">
        {HOST_BRIDGES.map((b) => (
          <BridgeCard key={b.name} b={b} />
        ))}
      </div>

      <div className="bridge-group-label">Session services (D-Bus and desktop)</div>
      <div className="bridge-grid">
        {SESSION_SERVICES.map((b) => (
          <BridgeCard key={b.name} b={b} />
        ))}
      </div>
    </div>
  );
}
