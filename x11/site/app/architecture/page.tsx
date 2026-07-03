import type { Metadata } from "next";
import Link from "next/link";
import { Diagram } from "@/components/Diagram";
import { Zoom } from "@/components/Figures";
import { Callout, Ext, NextLinks, Panel, PageHeader, Section } from "@/components/ui";

export const metadata: Metadata = { title: "Architecture" };

export default function Architecture() {
  return (
    <>
      <PageHeader
        tag="Architecture"
        title="One app, two servers, one screen"
        lede="A jailbroken iOS device gives you no display server, no OpenGL, and no way to run a background process that owns the screen. The design works around all three by funneling everything through a single ordinary app."
      />

      <Section num="01.1" title="The full path">
        <Panel label="Figure 01. Display and input" fig="app to A10">
          <Zoom label="Display and input">
            <Diagram />
          </Zoom>
        </Panel>
      </Section>

      <Section num="01.2" title="The bridge app">
        <div className="prose">
          <p>
            For the X11 and Wayland desktops, one app carries the whole thing:
            Xios.app, which shows on the Home Screen as X11. It owns a{" "}
            <code>CAMetalLayer</code>{" "}and the UIKit input surface, and it renders
            none of its own content. At startup a display server creates an
            output{" "}
            <Ext href="https://developer.apple.com/documentation/iosurface">IOSurface</Ext>{" "}
            and passes its{" "}
            <abbr title="an iOS kernel channel for handing a resource from one process to another">
              mach port
            </abbr>{" "}
            to the app. The app adopts that
            surface, wraps it as a{" "}
            <Ext href="https://developer.apple.com/metal/">Metal</Ext>{" "}texture,
            and draws it every frame. When a server redraws the desktop, the app
            shows the new contents without copying a single pixel.
          </p>
          <p>
            Because the app holds the screen and the input, the servers never
            touch UIKit. That keeps them close to their upstream form, which is
            what makes cross-compiling them tractable. Native mode is the one
            exception: it presents through a separate per-window host app rather
            than this single desktop surface.
          </p>
        </div>
      </Section>

      <Section num="01.3" title="Two servers, one output contract">
        <div className="prose">
          <p>
            Both servers produce the same thing: an output IOSurface the app can
            present. From the app&apos;s side they are interchangeable, so you can
            switch between an X11 session and a Wayland session and the app never
            knows which is running.
          </p>
        </div>
        <dl className="deflist" style={{ marginTop: 8 }}>
          <div className="row">
            <dt>Xios</dt>
            <dd>
              An Xvfb-derived X server whose device layer draws into an
              IOSurface. X11 clients connect over the ordinary protocol and render
              in software.
            </dd>
          </div>
          <div className="row">
            <dt>iosc</dt>
            <dd>
              A clean-room <code>libwayland-server</code>{" "}compositor. It
              composites clients on the GPU, advertises the protocols real
              toolkits expect (xdg-shell, popups, subsurfaces, viewport,
              fractional-scale, clipboard), and routes input through{" "}
              <code>wl_seat</code>.
            </dd>
          </div>
        </dl>
      </Section>

      <Section num="01.4" title="A frame's journey on the Wayland path">
        <div className="prose">
          <ol style={{ color: "var(--ink-2)", paddingLeft: 20, lineHeight: 1.7 }}>
            <li>
              A GTK4 app renders with GLES through{" "}
              <Ext href="https://github.com/google/angle">ANGLE</Ext>{" "}into its
              own IOSurface.
            </li>
            <li>
              It hands that surface to iosc over a mach port, as an IOSurface{" "}
              <code>wl_buffer</code>.
            </li>
            <li>
              iosc adopts it as a Metal texture and composites it with every
              other window into the output IOSurface, on the GPU.
            </li>
            <li>
              Xios.app presents that output IOSurface as a Metal texture on the
              screen.
            </li>
          </ol>
        </div>
        <Callout>
          No CPU copy happens between step one and step four. A window&apos;s
          pixels are drawn once by the GPU and scanned out by the same GPU.
        </Callout>
      </Section>

      <Section num="01.5" title="Input, in reverse">
        <div className="prose">
          <p>
            A tap or keystroke enters UIKit inside the app. For an X11 session it
            becomes{" "}
            <abbr title="an X11 extension for injecting synthetic keyboard and pointer events">
              XTEST
            </abbr>{" "}
            fed to the X server. For a Wayland session it crosses a
            small socket to iosc and turns into <code>wl_pointer</code>{" "}and{" "}
            <code>wl_keyboard</code>{" "}events for the focused window.
          </p>
        </div>
      </Section>

      <Section num="01.6" title="Hardware and POSIX bridges">
        <div className="prose">
          <p>
            Drawing pixels and routing input is only half the job. A desktop also
            expects a battery, a brightness slider, sound, Bluetooth, orientation,
            and a logged-in user. None of that exists in the Linux sense on iOS, so
            a set of small daemons translate each one, reading the real iOS API and
            republishing it as the D-Bus service, Wayland protocol, or sysfs file
            the desktop is looking for.
          </p>
          <p>
            <Link href="/system">System integration</Link> walks through how each
            one works, from audio to Bluetooth.
          </p>
        </div>
      </Section>

      <NextLinks path="/architecture" />
    </>
  );
}
