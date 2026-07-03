"use client";

import { useEffect, useState } from "react";
import { createPortal } from "react-dom";
import type { ReactNode } from "react";

/* ---- Lightbox overlay ---- */
function Lightbox({
  open,
  onClose,
  label,
  children,
}: {
  open: boolean;
  onClose: () => void;
  label?: string;
  children: ReactNode;
}) {
  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    document.addEventListener("keydown", onKey);
    const prev = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    return () => {
      document.removeEventListener("keydown", onKey);
      document.body.style.overflow = prev;
    };
  }, [open, onClose]);

  if (!open) return null;
  return createPortal(
    <div
      className="lightbox"
      role="dialog"
      aria-modal="true"
      aria-label={label}
      onClick={onClose}
    >
      <button
        type="button"
        className="lightbox-close"
        onClick={onClose}
        aria-label="Close"
      >
        Close
      </button>
      <div className="lightbox-inner" onClick={(e) => e.stopPropagation()}>
        {children}
      </div>
    </div>,
    document.body,
  );
}

/* ---- Wrap non-interactive content (a diagram) to expand on click ---- */
export function Zoom({ label, children }: { label: string; children: ReactNode }) {
  const [open, setOpen] = useState(false);
  return (
    <>
      <button
        type="button"
        className="media-btn"
        onClick={() => setOpen(true)}
        aria-label={`Expand: ${label}`}
      >
        {children}
      </button>
      <Lightbox open={open} onClose={() => setOpen(false)} label={label}>
        <div className="lightbox-diagram">{children}</div>
      </Lightbox>
    </>
  );
}

/* ---- On-device screenshot ---- */
export function Shot({
  src,
  alt,
  caption,
}: {
  src: string;
  alt: string;
  caption?: string;
}) {
  const [open, setOpen] = useState(false);
  return (
    <figure className="shot">
      <button
        type="button"
        className="media-btn"
        onClick={() => setOpen(true)}
        aria-label={`Expand image: ${caption ?? alt}`}
      >
        {/* eslint-disable-next-line @next/next/no-img-element */}
        <img src={src} alt={alt} loading="lazy" />
      </button>
      {caption && <figcaption>{caption}</figcaption>}
      <Lightbox open={open} onClose={() => setOpen(false)} label={caption ?? alt}>
        {/* eslint-disable-next-line @next/next/no-img-element */}
        <img src={src} alt={alt} className="lightbox-media" />
      </Lightbox>
    </figure>
  );
}

/* ---- On-device screen recording ---- */
export function Clip({
  label,
  caption,
}: {
  label: string;
  caption?: string;
}) {
  const [open, setOpen] = useState(false);
  return (
    <figure className="shot shot--clip">
      <div className="clip-wrap">
        <video
          autoPlay
          muted
          loop
          playsInline
          controls
          preload="metadata"
          poster="/shots/native-switch-poster.jpg"
          aria-label={label}
        >
          <source src="/shots/native-switch.webm" type="video/webm" />
          <source src="/shots/native-switch.mp4" type="video/mp4" />
        </video>
        <button
          type="button"
          className="clip-expand"
          onClick={() => setOpen(true)}
          aria-label="Expand video"
        >
          Expand
        </button>
      </div>
      {caption && <figcaption>{caption}</figcaption>}
      <Lightbox open={open} onClose={() => setOpen(false)} label={label}>
        <video
          autoPlay
          muted
          loop
          playsInline
          controls
          className="lightbox-media"
          aria-label={label}
        >
          <source src="/shots/native-switch.webm" type="video/webm" />
          <source src="/shots/native-switch.mp4" type="video/mp4" />
        </video>
      </Lightbox>
    </figure>
  );
}

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
        shell&apos;s power slider.
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
        CoreMotion orientation feeds an <b>iio-sensor-proxy</b> shim, so the
        desktop can auto-rotate.
      </>
    ),
  },
  {
    name: "xios-bluez-stub",
    state: "wip",
    body: (
      <>
        iOS Bluetooth, via the private <b>BluetoothManager</b> framework,
        republished as <b>org.bluez</b> for GNOME&apos;s Bluetooth panel.
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
        <b>wl_data_device</b> selections sync to and from the iOS{" "}
        <b>UIPasteboard</b>.
      </>
    ),
  },
  {
    name: "AT-SPI to VoiceOver",
    state: "planned",
    body: (
      <>
        The desktop <b>accessibility tree</b> is bridged to VoiceOver.
      </>
    ),
  },
];

function BridgeCard({ b }: { b: Bridge }) {
  return (
    <div className="bridge">
      <div className="b-head">
        <span className="b-name">{b.name}</span>
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
