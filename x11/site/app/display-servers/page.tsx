import type { Metadata } from "next";
import { T } from "@/components/Term";
import { Callout, Ext, NextLinks, Panel, PageHeader, Section } from "@/components/ui";
import { pageMetadata } from "@/content/site";

export const metadata: Metadata = pageMetadata("/display-servers");

export default function DisplayServers() {
  return (
    <>
      <PageHeader
        tag="Display servers"
        title="iosc and the compositors"
        lede="One architecture draws the desktop, and it is Wayland. iosc is ours, written from scratch and compositing on the GPU; Mutter and KWin are upstream compositors driving the same output; and Xwayland gives X11 clients a hardware route in. Every one of them hands the app the same output IOSurface."
      />

      <Section num="02.1" title="iosc, the Wayland compositor">
        <div className="prose">
          <p>
            <T k="iosc">iosc</T>{" "}is a compositor written from scratch on{" "}
            <code>libwayland-server</code>, clean-room and MIT-licensed. Rather
            than blitting client buffers on the CPU, it treats each client&apos;s
            rendered surface as a GPU texture and blends them into the output{" "}
            <T k="iosurface">
              <Ext href="https://developer.apple.com/documentation/iosurface">
                IOSurface
              </Ext>
            </T>{" "}
            on the A10. This is the path that makes real toolkits feel native.
          </p>
          <p>
            It advertises what real toolkits ask for, which by now means GTK and
            GNOME, Qt and Plasma, and the wlroots-family protocols the smaller
            Wayland apps expect. Input goes out through a standard{" "}
            <code>wl_seat</code>, with touch, tablet and the keyboard bridge
            alongside it.
          </p>
        </div>

        <Panel label="Protocols iosc speaks" fig="around 34 globals">
          <div className="prose" style={{ margin: 0 }}>
            <p style={{ margin: 0, color: "var(--ink-2)" }}>
              <code>xdg-shell</code>, popups, subsurfaces, <code>wp-viewport</code>,
              fractional-scale, presentation-time, single-pixel-buffer,
              xdg-activation, xdg-decoration, xdg-output; the clipboard as{" "}
              <code>wl_data_device</code>, primary selection and{" "}
              <code>wlr-data-control</code>; layer-shell, foreign-toplevel,
              screencopy, cursor-shape, pointer-constraints and relative-pointer,
              idle-notify and idle-inhibit; <T k="textInput" />{" "}with
              input-method and virtual-keyboard for the iOS keyboard bridge; touch
              and <code>zwp_tablet_v2</code>{" "}for the Pencil; the four KDE
              output-management protocols Plasma needs; and the private{" "}
              <T k="iosurfaceProtocol" />, which is how a client hands over a GPU
              buffer.
            </p>
          </div>
        </Panel>
      </Section>

      <Section num="02.2" title="The two upstream compositors">
        <div className="prose">
          <p>
            A desktop environment brings its own compositor, and the two big ones
            are handled differently.
          </p>
        </div>
        <dl className="deflist" style={{ marginTop: 8 }}>
          <div className="row">
            <dt>Mutter</dt>
            <dd>
              GNOME Shell&apos;s compositor is given a native iOS backend,
              MetaBackendIOS, so it produces the output IOSurface itself and
              reuses iosc&apos;s GPU glue. There is one compositor on screen, not
              two.
            </dd>
          </div>
          <div className="row">
            <dt>KWin</dt>
            <dd>
              Plasma&apos;s compositor nests instead: iosc owns the output, and{" "}
              <code>kwin_wayland</code>{" "}runs inside it as a Qt/ANGLE client with
              its own Wayland socket for Plasma&apos;s clients, compositing them
              into an IOSurface of its own first.
            </dd>
          </div>
        </dl>
      </Section>

      <Section num="02.3" title="Xwayland, the route for X11 apps">
        <div className="prose">
          <p>
            X11 clients get in through Xwayland, which runs against iosc as an
            ordinary Wayland client with <T k="glamor" />{" "}rendering X pixmaps
            through ANGLE into IOSurfaces. An X app therefore reaches the A10 like
            anything else, and this is what the X11 flavor installs: the{" "}
            <code>xios-x11</code>{" "}meta pulls in <code>xwayland</code>{" "}and{" "}
            <code>xauth</code>, not a server of our own.
          </p>
          <p>
            A rootless window manager that would give each X toplevel its own iosc
            surface is written and lives in the tree, but it is a build-time option
            and is not compiled into the published compositor yet.
          </p>
        </div>
        <Callout k="The software X server was retired">
          Until July 2026 this page described a second server of our own: Xios, an
          Xvfb-derived X server whose device layer drew into an IOSurface and whose
          clients rendered on the CPU. It was retired on 2026-07-29 along with its{" "}
          <code>xios-server</code>{" "}package, because Xwayland on glamor reaches the
          GPU and the software path could not. Xvnc and Xvfb are still built, but
          only as headless bring-up and debugging tools — neither is a session you
          would run a desktop on.
        </Callout>
      </Section>

      <Section num="02.4" title="Switching between them">
        <div className="prose">
          <p>
            Because every compositor produces an interchangeable output IOSurface,
            the session launcher can start any of them and the app presents the
            result the same way. A three-finger tap in the app opens the control
            panel, which lists the desktop presets: iosc, Mutter, GNOME Shell,
            Plasma Desktop, Plasma Nano and Plasma Mobile. Switching to a running
            display slot lives one level down, under Advanced. iosc also resizes
            live when the iPad rotates.
          </p>
        </div>
      </Section>

      <NextLinks path="/display-servers" />
    </>
  );
}
