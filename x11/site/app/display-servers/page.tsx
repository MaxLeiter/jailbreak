import type { Metadata } from "next";
import { Ext, NextLinks, Panel, PageHeader, Section } from "@/components/ui";

export const metadata: Metadata = { title: "Display servers" };

export default function DisplayServers() {
  return (
    <>
      <PageHeader
        tag="Display servers"
        title="Xios and iosc"
        lede="Two servers draw the desktop. One speaks X11 and renders in software; the other speaks Wayland and composites on the GPU. They are separate programs that happen to share an output format."
      />

      <Section num="02.1" title="Xios, the X11 server">
        <div className="prose">
          <p>
            Xios is derived from Xvfb, the virtual framebuffer X server, with a
            device layer that draws into an{" "}
            <Ext href="https://developer.apple.com/documentation/iosurface">IOSurface</Ext>{" "}
            instead of a memory buffer.
            X11 clients such as <code>xterm</code>{" "}and the classic{" "}
            <code>x11-apps</code>{" "}connect over the ordinary X protocol and are
            none the wiser about where their pixels end up.
          </p>
          <p>
            X11 clients render on the CPU. iOS ships no DRM and no OpenGL, and X11
            has no route to the Metal-backed GPU path on this platform, so the X
            track stays software. It is the compatible, reliable option, and it is
            where the project started.
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
            <dd>UIKit events arrive as XTEST.</dd>
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
            iosc is a compositor written from scratch on{" "}
            <code>libwayland-server</code>, clean-room and MIT-licensed. Rather
            than blitting client buffers on the CPU, it treats each client&apos;s
            rendered surface as a GPU texture and blends them into the output
            IOSurface on the A10. This is the path that makes real toolkits feel
            native.
          </p>
          <p>
            To satisfy GTK and GNOME it advertises the protocols those toolkits
            require, and it routes keyboard and pointer input through a standard{" "}
            <code>wl_seat</code>.
          </p>
        </div>

        <Panel label="Protocols iosc speaks" fig="wl, xdg, wlr">
          <div className="prose" style={{ margin: 0 }}>
            <p style={{ margin: 0, color: "var(--ink-2)" }}>
              <code>xdg-shell</code>, <code>xdg-popup</code>, subsurfaces,{" "}
              <code>wp-viewport</code>, fractional-scale,{" "}
              <code>wl_data_device</code>{" "}clipboard, layer-shell,
              foreign-toplevel, cursor-shape, screencopy, session-lock,
              drag-and-drop, plus wired-up touch and Pencil tablet input.
            </p>
          </div>
        </Panel>

      </Section>

      <Section num="02.3" title="Switching between them">
        <div className="prose">
          <p>
            Because both servers produce an interchangeable output IOSurface, the
            session launcher can start either one and the app presents it the same
            way. A three-finger tap in the app switches between running X and
            Wayland displays. A four-finger tap opens the session picker, where you
            choose a desktop and, for portrait, the display dimensions.
          </p>
        </div>
      </Section>

      <NextLinks path="/display-servers" />
    </>
  );
}
