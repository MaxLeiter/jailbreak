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
        title="Xios and iosc"
        lede="Two servers of our own draw the desktop. One speaks X11 and renders in software; the other speaks Wayland and composites on the GPU. Two upstream compositors, Mutter and KWin, also drive the same output, and Xwayland gives X11 clients a GPU route."
      />

      <Section num="02.1" title="Xios, the X11 server">
        <div className="prose">
          <p>
            Xios is derived from Xvfb, the virtual framebuffer X server, with a
            device layer that draws into an{" "}
            <T k="iosurface">
              <Ext href="https://developer.apple.com/documentation/iosurface">
                IOSurface
              </Ext>
            </T>{" "}
            instead of a memory buffer. X11 clients such as <code>xterm</code>{" "}
            and the classic <code>x11-apps</code>{" "}connect over the ordinary X
            protocol and are none the wiser about where their pixels end up.
          </p>
          <p>
            Clients that connect to it render on the CPU. iOS gives this path no{" "}
            <T k="drmKms" />{" "}or desktop OpenGL route, so the classic X track
            stays software. It is the compatible, reliable option, and it is where
            the project started. X11 apps that want the GPU take the Xwayland
            route instead, described in 02.4.
          </p>
        </div>
        <dl className="deflist" style={{ marginTop: 8 }}>
          <div className="row">
            <dt>Basis</dt>
            <dd>Xvfb with an IOSurface device layer, cross-compiled for iphoneos-arm64.</dd>
          </div>
          <div className="row">
            <dt>Output</dt>
            <dd>Draws the X screen straight into an IOSurface.</dd>
          </div>
          <div className="row">
            <dt>Input</dt>
            <dd>
              UIKit events arrive as <T k="xtest" />.
            </dd>
          </div>
          <div className="row">
            <dt>Rendering</dt>
            <dd>Software only. Good for legacy X clients, but not the GPU track.</dd>
          </div>
        </dl>
      </Section>

      <Section num="02.2" title="iosc, the Wayland compositor">
        <div className="prose">
          <p>
            <T k="iosc">iosc</T>{" "}is a compositor written from scratch on{" "}
            <code>libwayland-server</code>, clean-room and MIT-licensed. Rather
            than blitting client buffers on the CPU, it treats each client&apos;s
            rendered surface as a GPU texture and blends them into the output
            IOSurface on the A10. This is the path that makes real toolkits feel
            native.
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

      <Section num="02.3" title="The two upstream compositors">
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

      <Section num="02.4" title="Xwayland">
        <div className="prose">
          <p>
            X11 clients do not have to use the classic server. Xwayland runs
            against iosc as an ordinary Wayland client, with{" "}
            <T k="glamor" />{" "}rendering X pixmaps through ANGLE into IOSurfaces,
            so an X app can reach the A10 after all. That is the shipped default
            for the X11 flavor. A rootless window manager that would give each X
            toplevel its own iosc surface is written and lives in the tree, but it
            is a build-time option and is not compiled into the published
            compositor yet.
          </p>
        </div>
      </Section>

      <Section num="02.5" title="Switching between them">
        <div className="prose">
          <p>
            Because every server produces an interchangeable output IOSurface, the
            session launcher can start any of them and the app presents the result
            the same way. A three-finger tap in the app opens the control panel,
            which lists the desktop presets: iosc, Mutter, GNOME Shell, Plasma
            Desktop, Plasma Nano and Plasma Mobile. Switching to a running display
            slot lives one level down, under Advanced. iosc also resizes live when
            the iPad rotates.
          </p>
        </div>
        <Callout k="The X11 server is not a session preset">
          The presets are all Wayland. The classic X server has its own{" "}
          <code>xios-server</code>{" "}command and never shows up in the picker, so
          do not go looking for it there after installing the X11 flavor.
        </Callout>
      </Section>

      <NextLinks path="/display-servers" />
    </>
  );
}
