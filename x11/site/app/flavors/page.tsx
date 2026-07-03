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
    body: "X11/Wayland apps show up on your homescreen and launch like normal apps. They rotate, resize, honor dark mode, and talk to VoiceOver. There is no desktop shell at all.",
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
    body: "Run a full upstream desktop environment more or less unchanged. GNOME Shell 46 and KDE Plasma both target the same compositor and GPU foundation. It is the heaviest option and the closest to a real Linux desktop.",
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
            For people who want the real thing, two full upstream environments are
            being brought up on the same compositor and GPU stack.
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
              It boots, paints, and runs.
            </p>
          </div>
          <div className="card">
            <span className="card-tag">KWin and KF6</span>
            <h3>KDE Plasma</h3>
            <p>
              <Ext href="https://kde.org/plasma-desktop/">Plasma</Ext>{" "}Mobile on
              KWin, built on a cross-compiled Qt6 module ladder and a subset of
              KDE Frameworks 6. The Qt6 Wayland platform plugin targets iosc.
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

      <Section num="04.3" title="GNOME apps, without the desktop">
        <div className="prose">
          <p>
            You do not need the GNOME desktop to run GNOME apps. GTK4 and GNOME
            programs run as windows under iosc whichever flavor you pick, and
            GNOME Console runs a live shell you can tap and type into.
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
              A wave of Wayland apps; mpv does audio and VideoToolbox decode.
            </dd>
          </div>
          <div className="row">
            <dt>Files, text editor</dt>
            <dd>The GNOME file manager and text editor.</dd>
          </div>
        </dl>
      </Section>

      <NextLinks path="/flavors" />
    </>
  );
}
