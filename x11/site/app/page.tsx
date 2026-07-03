import { Diagram } from "@/components/Diagram";
import { Clip, Shot, Zoom } from "@/components/Figures";
import { Ext, NextLinks, Panel, PlainTerms, Section } from "@/components/ui";

export default function Overview() {
  return (
    <>
      <header className="page-header">
        <div className="kicker">
          <span className="tag">Overview</span>
        </div>
        <h1 className="page-title">X11 and Wayland on iOS</h1>
        <p className="lede">Porting an unreasonable amount of software.</p>
      </header>

      <Section num="00.1" title="Where this came from">
        <div className="prose">
          <p>
            I <Ext href="https://knightos.org">enjoy</Ext>{" "}
            <Ext href="https://maxleiter.com/blog/MSHW0184">running</Ext>{" "}
            <Ext href="https://maxleiter.com/blog/sandcastle">software</Ext>{" "}
            on machines that shouldn&apos;t run it. I own the machine, after all.
            And I&apos;ve always thought it weird you can&apos;t run a{" "}
            &quot;real desktop&quot; on an iPad. A few years ago, I painstakingly{" "}
            <Ext href="https://maxleiter.com/x11">ported X11 to iOS</Ext>. The
            server ran on-device, but you had to connect with a VNC client, and
            everything was rendered in software with no GPU support. This time
            the display path is direct.
          </p>
          <p>
            An X11 server and a GPU-accelerated{" "}
            <Ext href="https://wayland.freedesktop.org">Wayland</Ext>{" "}compositor
            now run as native arm64 code and draw straight to the display through{" "}
            <Ext href="https://developer.apple.com/metal/">Metal</Ext>. And to be
            clear, there is no Linux here: no VM or emulator. The apps are GNOME,
            GTK, and X11 programs from the Linux desktop world, but every one of
            them is a native iOS binary. Their windows reach the screen as{" "}
            <Ext href="https://developer.apple.com/documentation/iosurface">
              IOSurfaces
            </Ext>
            , and your touches reach them as X11 and Wayland input.
          </p>
          <p>
            When I first did the X11 work, I compiled everything by hand, on the
            device. When I inevitably revisited it, the right move was a proper
            build system. Thankfully the{" "}
            <Ext href="https://github.com/ProcursusTeam/Procursus">
              Procursus folks
            </Ext>{" "}
            have since made one.
          </p>
          <p>
            It should run on most jailbreakable devices. If this sentence read
            like gibberish to you, see the next section.
          </p>
        </div>
        <div className="shot-grid" style={{ marginTop: 30 }}>
          <Shot
            src="/shots/native-home.jpg"
            alt="The iPad Home Screen with Linux desktop apps (Calculator, Console, Files, Fonts, Disk Usage Analyzer, Hitori and more) shown as native iOS icons."
            caption="Native mode: Linux apps as Home Screen icons"
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
          This runs real Linux desktop apps on an iPhone or iPad. Not in a
          window, not streamed from somewhere else, not a Linux virtual machine.
          The apps themselves were rebuilt to run straight on iOS, and they show
          up like any other app.
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
            An iPad is a powerful machine with a Unix-like OS. Under the touch
            layer, iOS shares its lineage with macOS, the same family of system
            that runs all of that software in the first place, and the chip is a
            fast arm64 processor with a real GPU. There is no real reason it
            can&apos;t run a full desktop. Apple just doesn&apos;t let you. I
            don&apos;t love that, so here we are.
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
            iOS only ever talks to Xios.app. Whether an X server or the Wayland
            compositor is producing frames underneath is invisible to it, because
            both hand the app the same kind of output surface.
          </p>
        </div>
      </Section>

      <NextLinks path="/" />
    </>
  );
}
