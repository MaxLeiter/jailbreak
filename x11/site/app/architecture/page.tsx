import type { Metadata } from "next";
import Link from "next/link";
import { Diagram } from "@/components/Diagram";
import { Zoom } from "@/components/Figures";
import { T } from "@/components/Term";
import { Callout, Ext, NextLinks, Panel, PageHeader, Section } from "@/components/ui";

export const metadata: Metadata = { title: "Architecture" };

export default function Architecture() {
  return (
    <>
      <PageHeader
        tag="Architecture"
        title="One app, one screen, several servers"
        lede="A jailbroken iOS device gives this stack no display server, no DRM/KMS path, and no background service that can own the screen. The design works around that by funneling desktop sessions through one ordinary app."
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
            <T k="camelayer">
              <code>CAMetalLayer</code>
            </T>{" "}
            and the UIKit input surface, and it draws none of the desktop&apos;s
            own content. At startup a display server creates an output{" "}
            <T k="iosurface">
              <Ext href="https://developer.apple.com/documentation/iosurface">
                IOSurface
              </Ext>
            </T>{" "}
            and passes its <T k="machPort" />{" "}to the app. The app adopts that
            surface, wraps it as a <T k="metal" />{" "}texture, and draws it every
            frame. When a server redraws the desktop, the app shows the new
            contents without copying a single pixel.
          </p>
          <p>
            Because the app holds the screen and the input, the servers never
            touch UIKit. That keeps them close to their upstream form, which is
            what makes cross-compiling them tractable.
          </p>
          <p>
            What the app does draw is its own chrome: a thin status overlay you
            pull down from the top edge, and a control panel on a three-finger
            tap that starts and stops desktops, resizes a running one, picks
            which apps get Home Screen icons, and lists the display slots you
            have open. It is also the process that owns hardware iOS will not
            hand to a daemon, so camera frames and VoiceOver state reach the
            desktop through it. Native mode is the one path that bypasses this
            app: each Linux app there gets its own per-window host bundle.
          </p>
        </div>
      </Section>

      <Section num="01.3" title="Four ways to drive the same output">
        <div className="prose">
          <p>
            Every server produces the same thing: an output IOSurface the app can
            present. From the app&apos;s side they are interchangeable, which is
            what lets you switch desktops without the app knowing much beyond
            which one it pinned.
          </p>
        </div>
        <dl className="deflist" style={{ marginTop: 8 }}>
          <div className="row">
            <dt>Xios</dt>
            <dd>
              An Xvfb-derived X server whose device layer draws into an
              IOSurface. X11 clients connect over the ordinary protocol and
              render in software.
            </dd>
          </div>
          <div className="row">
            <dt>iosc</dt>
            <dd>
              A clean-room <code>libwayland-server</code>{" "}
              <T k="compositor" />. It composites clients on the GPU and serves
              around thirty protocols, from xdg-shell and subsurfaces up through
              touch, tablet, layer-shell, screencopy, the{" "}
              <T k="textInput" />{" "}keyboard bridge, and the private{" "}
              <T k="iosurfaceProtocol" />{" "}buffer protocol.
            </dd>
          </div>
          <div className="row">
            <dt>Mutter</dt>
            <dd>
              GNOME Shell&apos;s compositor, given a native iOS backend
              (MetaBackendIOS) so it renders into the output IOSurface itself
              rather than nesting inside iosc.
            </dd>
          </div>
          <div className="row">
            <dt>KWin</dt>
            <dd>
              Plasma&apos;s compositor, which does nest: iosc owns the output
              surface, and <code>kwin_wayland</code>{" "}runs inside it as a
              Qt/ANGLE client that composites Plasma&apos;s windows into its own
              IOSurface first.
            </dd>
          </div>
        </dl>
        <div className="prose" style={{ marginTop: 14 }}>
          <p>
            X11 apps have a fifth route that skips the classic server entirely:
            Xwayland runs against iosc as an ordinary client, with{" "}
            <T k="glamor" />{" "}rendering X pixmaps through ANGLE into IOSurfaces.
          </p>
        </div>
      </Section>

      <Section num="01.4" title="A Wayland frame">
        <div className="prose">
          <ol style={{ color: "var(--ink-2)", paddingLeft: 20, lineHeight: 1.7 }}>
            <li>
              A GTK4 app renders with GLES through{" "}
              <T k="angle">
                <Ext href="https://github.com/google/angle">ANGLE</Ext>
              </T>{" "}
              into its own IOSurface.
            </li>
            <li>
              It hands that surface to iosc over a mach port, as an IOSurface{" "}
              <code>wl_buffer</code>.
            </li>
            <li>
              iosc binds it as a GL texture and composites it with every other
              window into the output IOSurface, on the GPU.
            </li>
            <li>
              Xios.app presents that output IOSurface as a Metal texture on the
              screen.
            </li>
          </ol>
        </div>
        <Callout>
          No CPU copy happens between step one and step four. A window&apos;s
          pixels are drawn once by the GPU and scanned out by the same GPU. Apps
          that still paint into <T k="wlShm" />{" "}buffers, and the whole classic
          X11 path, do pay a CPU upload; under Plasma there is one extra GPU pass,
          because KWin composites before iosc does.
        </Callout>
      </Section>

      <Section num="01.5" title="Input, in reverse">
        <div className="prose">
          <p>
            A tap or keystroke enters UIKit inside the app and crosses a small
            socket as a fixed-size record. For an X11 session it becomes{" "}
            <T k="xtest" />{" "}fed to the X server. For a Wayland session it
            reaches iosc or Mutter and turns into <code>wl_pointer</code>,{" "}
            <code>wl_keyboard</code>, <code>wl_touch</code>{" "}or tablet events for
            the focused window.
          </p>
          <p>
            The wire carries more than taps: multitouch slots, Apple Pencil
            pressure and tilt, scroll with a finger-versus-wheel source, and raw
            HID from a physical keyboard, mouse or trackpad, including chords,
            key repeat, five mouse buttons and Command mapped to Super. It is not
            one-directional either. The same socket carries records back up to
            the app: text-input traits that tell iOS which keyboard to raise,
            haptic requests, and rotation and output geometry.
          </p>
        </div>
      </Section>

      <Section num="01.6" title="Sessions, slots and the supervisor">
        <div className="prose">
          <p>
            Nothing starts a desktop directly. <T k="ioscd" />{" "}is a root daemon
            that owns session lifecycle: it launches clients that would otherwise
            inherit a sandboxed identity from a Home Screen tap, foregrounds
            Xios.app, restarts a compositor that died, and decides who is allowed
            to switch sessions at all. That last part is a real trust boundary,
            added after stray requests were tearing down healthy desktops in a
            loop: root and the picker app may switch, everyone else can only ask
            for a session to exist.
          </p>
          <p>
            <T k="xiosSession" />{" "}is the command underneath, with presets for
            iosc, Mutter, GNOME Shell, Plasma Desktop, Plasma Nano and Plasma
            Mobile. Pass it a <T k="displaySlot">slot</T>{" "}name and you get a
            second desktop with its own Wayland socket, config and status file,
            which the app lists so you can pin one and switch between them.
          </p>
        </div>
      </Section>

      <Section num="01.7" title="Hardware and POSIX bridges">
        <div className="prose">
          <p>
            Drawing pixels and routing input is only half the job. A desktop also
            expects a battery, a brightness slider, sound, Bluetooth,
            orientation, and a logged-in user. None of that exists in the Linux
            sense on iOS, so a set of small daemons translate each one, reading
            the real iOS API and republishing it as the <T k="dbus" />{" "}service,
            Wayland protocol, or <T k="sysfs" />{" "}file the desktop is looking
            for.
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
