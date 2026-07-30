import type { Metadata } from "next";
import { Diagram } from "@/components/Diagram";
import { Clip, Shot, Zoom } from "@/components/Figures";
import { T } from "@/components/Term";
import { Ext, NextLinks, Panel, PlainTerms, Section } from "@/components/ui";
import { pageMetadata } from "@/content/site";

export const metadata: Metadata = pageMetadata("/");

export default function Overview() {
  return (
    <>
      <header className="page-header">
        <div className="kicker">
          <span className="tag">Overview</span>
        </div>
        <h1 className="page-title">X11 and Wayland on iOS</h1>
        <p className="lede">Desktop Linux apps on a jailbroken iPad</p>
      </header>

      <Section num="00.1" title="Where this came from">
        <div className="prose">
          <p>
            I <Ext href="https://knightos.org">enjoy</Ext>{" "}
            <Ext href="https://maxleiter.com/blog/MSHW0184">running</Ext>{" "}
            <Ext href="https://maxleiter.com/blog/sandcastle">software</Ext>{" "}
            on machines that shouldn&apos;t run it. I own the machine and should be able to run what I want.
            And I&apos;ve always thought it weird you can&apos;t run a{" "}
            &quot;real desktop&quot; on an iPad. (well, I know the reasons, but I'm not a fan.) A few years ago, I painstakingly{" "}
            <Ext href="https://maxleiter.com/x11">ported X11 to iOS</Ext>. The
            server ran on-device, but you had to connect with a VNC client, and
            everything was rendered in software with no GPU support. This time its different. 
          </p>
          <p>
            From here on, everything on this site has been written by LLMs with only brief
            oversight from me.
          </p>
        </div>
        <div className="shot-grid" style={{ marginTop: 30 }}>
          <Shot
            src="/shots/native-home.jpg"
            alt="The iPad Home Screen with Linux desktop apps (Calculator, Console, Files, Fonts, Disk Usage Analyzer, Hitori and more) shown as native iOS icons."
            caption="Native mode: Linux apps as Home Screen icons"
            priority
          />
          <Shot
            src="/shots/iosc-desktop.jpg"
            alt="The iosc desktop on the iPad: a top status bar, storage, memory, load and uptime widgets, and a dock of app icons."
            caption="The iosc desktop"
          />
          <Shot
            src="/shots/gnome-launcher.jpg"
            alt="GNOME Shell 46 on the iPad showing the activities overview with two workspaces and an app grid: Calculator, Utilities, Foot, Hitori, mpv, Zathura."
            caption="GNOME Shell 46, on the A10"
          />
        </div>
        <div style={{ marginTop: 22 }}>
          <Clip
            label="A screen recording of switching between Linux apps running as native iOS windows on the iPad."
            caption="Native mode: switching between apps"
          />
        </div>
      </Section>

      <Section num="00.2" title="What this is">
        <PlainTerms>
          This runs Linux desktop apps on a jailbroken iPad. Not streamed from
          somewhere else, not a Linux virtual machine. The apps are rebuilt as
          iOS binaries and can show up like ordinary apps.
        </PlainTerms>
        <div className="prose">
          <p>
            If you are on macOS or Windows, you use the desktop environment Apple
            or Microsoft gives you, and you never think about it as a separate
            thing. Linux users do not have that constraint: the desktop is its
            own piece, and you pick which one you want. A{" "}
            <Ext href="https://en.wikipedia.org/wiki/Desktop_environment">
              desktop environment
            </Ext>{" "}
            is the whole graphical shell of the computer, the windows and the
            panel and the file manager and the settings.{" "}
            <Ext href="https://www.gnome.org">GNOME</Ext>{" "}and{" "}
            <Ext href="https://kde.org/plasma-desktop/">KDE</Ext>{" "}are the big
            two, and behind them sits decades of software: terminals, editors,
            file managers, media players.
          </p>
          <p>
            An iPad has a Unix-like OS, an arm64 CPU, and a real GPU. Under the
            touch layer, iOS is close enough to macOS that a lot of desktop
            software can be rebuilt for it. Apple does not expose that path, so
            this project builds the missing pieces.
          </p>
          <p>
            Both of the big two run here now. GNOME Shell 46 boots on the A10,
            and KDE Plasma composites on the GPU with its effects turned on,
            which brings Konsole, Kate, Dolphin and System Settings with it.{" "}
            <Ext href="https://ladybird.org">Ladybird</Ext>, an independent
            browser engine, is ported too, so there is a way to open a web page
            that is not WebKit wearing a different hat.
          </p>
        </div>
      </Section>

      <Section num="00.3" title="The stack">
        <Panel label="Figure 00. The display and input path" fig="app to A10">
          <Zoom label="The display and input path">
            <Diagram />
          </Zoom>
        </Panel>
        <div className="prose" style={{ marginTop: 22 }}>
          <p>
            For a full desktop, iOS only ever talks to one app: Xios.app. Whether{" "}
            <T k="iosc" />, Mutter or KWin is producing frames underneath is
            invisible to it, because they all hand the app the same kind of output
            surface. Native mode is the exception, and the point of
            it: there each Linux app gets its own Home Screen icon and its own
            host bundle, so iOS sees several ordinary apps instead of one.
          </p>
        </div>
      </Section>

      <NextLinks path="/" />
    </>
  );
}
