import type { Metadata } from "next";
import { Clip, Shot } from "@/components/Figures";
import { Callout, Ext, NextLinks, PageHeader, Section } from "@/components/ui";

export const metadata: Metadata = { title: "Desktop flavors" };

type Mode = {
  name: string;
  tag: string;
  state: "live" | "wip" | "planned";
  body: string;
};

const MODES: Mode[] = [
  {
    name: "Native mode",
    tag: "Per-window",
    state: "wip",
    body: "Linux desktop apps can show up on your Home Screen and launch into their own iPadOS windows. The backend exists; the per-window UI path is still being validated.",
  },
  {
    name: "iosc desktop",
    tag: "Our own shell",
    state: "live",
    body: "The compositor's own tablet-first desktop: a panel with launchers, a dock, an overview, and a wallpaper.",
  },
  {
    name: "Bring your own desktop",
    tag: "Upstream",
    state: "wip",
    body: "Run a full upstream desktop environment. GNOME Shell 46 and KDE Plasma both use the same IOSurface and GPU foundation. This is the heavy path, and the closest to a normal Linux desktop.",
  },
];

export default function Flavors() {
  return (
    <>
      <PageHeader
        tag="Desktop flavors"
        title="Three ways to run a desktop"
        lede="The same Linux apps can be presented three different ways."
      />

      <Section num="04.1" title="The three modes">
        <div className="grid-auto">
          {MODES.map((m) => (
            <div className="card" key={m.name}>
              <span className="card-tag">{m.tag}</span>
              <h3>{m.name}</h3>
              <p>{m.body}</p>
            </div>
          ))}
        </div>
        <div style={{ marginTop: 18 }}>
          <Shot
            src="/shots/iosc-launcher.jpg"
            alt="The app launcher showing installed apps: Fonts, D-Spy, mpv Media Player, Foot Server, Foot Client, Zathura, Files, Console, Disk Usage Analyzer, File Roller, Foot, Calculator and Hitori."
            caption="The app launcher"
          />
        </div>
        <div style={{ marginTop: 18 }}>
          <Clip
            label="A screen recording of switching between Linux apps running as native iOS windows on the iPad."
            caption="Native mode: switching between apps"
          />
        </div>
      </Section>

      <Section num="04.2" title="Bring your own desktop environment">
        <div className="prose">
          <p>
            For people who want a normal desktop environment, GNOME Shell and KDE
            Plasma are running on the same IOSurface and GPU stack.
          </p>
        </div>
        <div className="grid-2" style={{ marginTop: 8 }}>
          <div className="card">
            <span className="card-tag">Mutter and gjs</span>
            <h3>GNOME Shell 46</h3>
            <p>
              The full <Ext href="https://www.gnome.org">GNOME</Ext>{" "}Shell 46,
              driven by{" "}
              <Ext href="https://gitlab.gnome.org/GNOME/mutter">Mutter</Ext>{" "}with
              a new iOS backend, MetaBackendIOS, that renders to{" "}
              <Ext href="https://developer.apple.com/documentation/iosurface">IOSurfaces</Ext>{" "}
              and reuses iosc&apos;s GPU glue instead of nesting two compositors.
              It boots through the packaged <code>gnome-session</code> path and
              runs on the device. The remaining work is polish and service
              coverage, not first paint.
            </p>
          </div>
          <div className="card">
            <span className="card-tag">KWin and KF6</span>
            <h3>KDE Plasma</h3>
            <p>
              <Ext href="https://kde.org/plasma-desktop/">Plasma</Ext>{" "}Desktop
              and Mobile on KWin, built on cross-compiled Qt6 and KDE Frameworks
              6. The current desktop package includes System Settings, KScreen,
              Breeze styling, and the first KDE app batch: Ark, Gwenview, and
              KWrite.
            </p>
          </div>
        </div>
        <Callout k="Why the shell port avoids nesting">
          Running GNOME Shell means running Mutter, which is itself a compositor.
          Rather than stack Mutter inside iosc, the port gives Mutter a native iOS
          backend that reuses the same IOSurface and Metal plumbing, so there is
          one compositor on screen instead of two.
        </Callout>
      </Section>

      <Section num="04.3" title="Apps, without a full desktop">
        <div className="prose">
          <p>
            You do not need GNOME Shell or Plasma to run desktop apps. iosc can
            launch GTK, Qt/KF6, X11, and plain Wayland clients as windows.
          </p>
        </div>
        <dl className="deflist" style={{ marginTop: 8 }}>
          <div className="row">
            <dt>Console (kgx)</dt>
            <dd>A real GNOME terminal with a working shell.</dd>
          </div>
          <div className="row">
            <dt>Calculator</dt>
            <dd>The Vala GNOME app.</dd>
          </div>
          <div className="row">
            <dt>foot, imv, mpv</dt>
            <dd>
              A Wayland app wave. foot has a working PTY, imv works through its
              native Wayland path and an Xwayland fallback, and mpv renders
              through ANGLE/Metal.
            </dd>
          </div>
          <div className="row">
            <dt>fuzzel, dunst, zathura, hitori</dt>
            <dd>Launcher, notifications, a PDF viewer, and a GTK puzzle app.</dd>
          </div>
          <div className="row">
            <dt>Ark, Gwenview, KWrite</dt>
            <dd>The first published Qt/KF6 app batch.</dd>
          </div>
        </dl>
      </Section>

      <NextLinks path="/flavors" />
    </>
  );
}
