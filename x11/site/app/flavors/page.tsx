import type { Metadata } from "next";
import Link from "next/link";
import { Clip, Shot } from "@/components/Figures";
import { T } from "@/components/Term";
import { Callout, Ext, NextLinks, PageHeader, Section } from "@/components/ui";
import { pageMetadata } from "@/content/site";

export const metadata: Metadata = pageMetadata("/flavors");

type Mode = {
  name: string;
  tag: string;
  body: string;
};

const MODES: Mode[] = [
  {
    name: "Native mode",
    tag: "Per-window",
    body: "Linux desktop apps show up on your Home Screen and launch into their own iPadOS windows, each in its own host bundle. A Settings pane picks which apps get icons. What is still being validated is the physical host-window polish, not the launch path.",
  },
  {
    name: "iosc desktop",
    tag: "Our own shell",
    body: "The compositor's own tablet-first desktop: a panel with launchers, a dock, an overview, and a wallpaper. The lightest thing here, and the one that assumes a touchscreen rather than tolerating one.",
  },
  {
    name: "Bring your own desktop",
    tag: "Upstream",
    body: "Run a full upstream desktop environment. GNOME Shell 46 and KDE Plasma both sit on the same IOSurface and GPU foundation. This is the heavy path, and the closest to a normal Linux desktop.",
  },
  {
    name: "X11 compatibility",
    tag: "Legacy",
    body: "Xwayland against iosc for X11 clients, rendering through glamor and ANGLE rather than on the CPU. Useful for old X apps that have no Wayland story.",
  },
];

export default function Flavors() {
  return (
    <>
      <PageHeader
        tag="Desktop flavors"
        title="Four ways to run a desktop"
        lede="The same Linux apps can be presented several different ways, and which one you get is decided by which package you install."
      />

      <Section num="04.1" title="The modes">
        <div className="grid-auto">
          {MODES.map((m) => (
            <div className="card" key={m.name}>
              <span className="card-tag">{m.tag}</span>
              <h3>{m.name}</h3>
              <p>{m.body}</p>
            </div>
          ))}
        </div>
        <Callout k="The package manager is the chooser">
          Nothing custom ships to pick a flavor. You install{" "}
          <code>xios-native</code>, <code>xios-gnome</code>,{" "}
          <code>xios-kde</code>{" "}or <code>xios-x11</code>{" "}from{" "}
          <T k="sileo" />{" "}and apt resolves the whole desktop. All four pull in{" "}
          <code>xios-runtime</code>, the shell-independent base of compositor, GPU
          stack, D-Bus, audio and filesystem bridges; the three fullscreen flavors
          add <code>xios-core</code>{" "}on top for the display app, the iosc shell
          and the session launcher, which is exactly what native mode leaves out.
          The metas also carry the iOS floor, so a device too old for a flavor is
          simply not offered it.
        </Callout>
        <div style={{ marginTop: 18 }}>
          <Shot
            src="/shots/iosc-launcher.jpg"
            alt="The app launcher showing installed apps: Fonts, D-Spy, mpv Media Player, Foot Server, Foot Client, Zathura, Files, Console, Disk Usage Analyzer, File Roller, Foot, Calculator and Hitori."
            caption="The app launcher"
            sizes="(max-width: 900px) 100vw, 900px"
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
              <T k="iosurface">IOSurfaces</T>{" "}and reuses iosc&apos;s GPU glue
              instead of nesting two compositors. It boots through the packaged{" "}
              <code>gnome-session</code>{" "}path and runs on the device. The
              remaining work is polish and service coverage, not first paint.
            </p>
          </div>
          <div className="card">
            <span className="card-tag">KWin and KF6</span>
            <h3>KDE Plasma</h3>
            <p>
              <Ext href="https://kde.org/plasma-desktop/">Plasma</Ext>{" "}on KWin,
              built on cross-compiled Qt6 and <T k="kf6" />, in three shapes:
              Desktop, Nano and Mobile. KWin composites on the GPU with its
              effects, scripts and window decorations shipped, and Plasma&apos;s
              own shell came off its software fallback with it. System Settings
              has around twenty <T k="kcm">KCMs</T>, and PowerDevil reads the
              real battery through the hardware bridge.
            </p>
          </div>
        </div>
        <Callout k="Why the shell port avoids nesting">
          Running GNOME Shell means running Mutter, which is itself a compositor.
          Rather than stack Mutter inside iosc, the port gives Mutter a native iOS
          backend that reuses the same IOSurface and Metal plumbing, so there is
          one compositor on screen instead of two. Plasma made the opposite
          trade: KWin keeps its own backend and nests, which costs one extra GPU
          pass and bought a much shorter road to a working desktop.
        </Callout>
      </Section>

      <Section num="04.3" title="Apps, without a full desktop">
        <div className="prose">
          <p>
            You do not need GNOME Shell or Plasma to run desktop apps. iosc can
            launch GTK, Qt/KF6, X11, and plain Wayland clients as windows.
          </p>
          <p>
            <Link href="/apps">Browse app screenshots and individual app pages</Link>,
            including GIMP, Gnumeric, Thunar, and Ladybird.
          </p>
        </div>
        <dl className="deflist" style={{ marginTop: 8 }}>
          <div className="row">
            <dt>Ladybird</dt>
            <dd>
              An <Ext href="https://ladybird.org">independent browser engine</Ext>
              , in two forms: a standalone iOS app bundle, and a Wayland build
              that runs inside a desktop session.
            </dd>
          </div>
          <div className="row">
            <dt>Konsole, Kate, Dolphin, KCalc</dt>
            <dd>
              The KDE set. Konsole has a real pty with a shell under it; Dolphin
              is built without Baloo, so browsing and file operations work but
              indexed search does not.
            </dd>
          </div>
          <div className="row">
            <dt>Ark, Gwenview, KWrite, Okular</dt>
            <dd>Archives, images, text and PDFs, from the same Qt/KF6 batch.</dd>
          </div>
          <div className="row">
            <dt>Console (kgx), Text Editor, Files, Calculator</dt>
            <dd>
              The GNOME set, including Nautilus and gnome-control-center.
            </dd>
          </div>
          <div className="row">
            <dt>opencode</dt>
            <dd>
              A coding agent running on the cross-compiled Bun, doing full agent
              turns on the iPad.
            </dd>
          </div>
          <div className="row">
            <dt>foot, imv, mpv</dt>
            <dd>
              A Wayland app wave. foot has a working PTY, imv works through its
              native Wayland path and an Xwayland fallback, and mpv renders
              through ANGLE with VideoToolbox decode.
            </dd>
          </div>
          <div className="row">
            <dt>fuzzel, dunst, zathura, waybar, hitori</dt>
            <dd>
              Launcher, notifications, a PDF viewer, a panel, and a GTK puzzle
              app.
            </dd>
          </div>
        </dl>
      </Section>

      <NextLinks path="/flavors" />
    </>
  );
}
