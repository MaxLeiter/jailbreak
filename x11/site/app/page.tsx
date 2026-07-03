import { Diagram } from "@/components/Diagram";
import { Ext, NextLinks, Panel, Section } from "@/components/ui";

export default function Overview() {
  return (
    <>
      <header className="page-header">
        <div className="kicker">
          <span className="tag">Overview</span>
        </div>
        <h1 className="page-title">X11 and Wayland on iOS</h1>
        <p className="lede">
          I <Ext href="https://knightos.org">enjoy</Ext>{" "}
          <Ext href="https://maxleiter.com/blog/MSHW0184">running</Ext>{" "}
          <Ext href="https://maxleiter.com/blog/sandcastle">software</Ext> on
          machines that shouldn&apos;t run it. A few years ago, I painstakingly{" "}
          <Ext href="https://maxleiter.com/x11">ported X11 to iOS</Ext>. The server
          ran on-device, but you had to connect with a VNC client. With Opus and
          Fable, that need is no more.
        </p>
      </header>

      <Section num="00.1" title="Where this came from">
        <div className="prose">
          <p>
            This is the iOS one, done right. A real X11 server and a
            GPU-accelerated{" "}
            <Ext href="https://wayland.freedesktop.org">Wayland</Ext> compositor
            now run as native arm64 code and draw straight to the display through{" "}
            <Ext href="https://developer.apple.com/metal/">Metal</Ext>. And to be
            clear, there is no Linux here: no kernel, no virtual machine, no
            emulator. The apps are GNOME, GTK, and X11 programs from the Linux
            desktop world, but every one of them is a native iOS binary. Their
            windows reach the screen as{" "}
            <Ext href="https://developer.apple.com/documentation/iosurface">
              IOSurfaces
            </Ext>
            , and your taps reach them as X11 and Wayland input.
          </p>
          <p>
            When I first did the X11 work, I compiled everything by hand, on the
            device. Redoing it, I realized how dumb that was; the right move was a
            build system. Thankfully the{" "}
            <Ext href="https://github.com/ProcursusTeam/Procursus">
              Procursus folks
            </Ext>{" "}
            had already made one: a macOS-hosted build system that cross-compiles
            a whole Debian-style userland for jailbroken iOS. This all stands on
            it.
          </p>
          <p>
            Everything below is proven on that same jailbroken iPad, an A10, but
            the packages target rootless jailbroken iOS more broadly. The device is
            the reference, not the limit.
          </p>
        </div>
      </Section>

      <Section num="00.2" title="The stack">
        <Panel label="Figure 00. The display and input path" fig="app to A10">
          <Diagram />
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
