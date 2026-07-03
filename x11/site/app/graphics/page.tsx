import type { Metadata } from "next";
import { CopyFlow } from "@/components/Figures";
import { Ext, NextLinks, Panel, PageHeader, Section } from "@/components/ui";

export const metadata: Metadata = { title: "The GPU path" };

export default function Graphics() {
  return (
    <>
      <PageHeader
        tag="Graphics"
        title="Reaching the A10 without OpenGL"
        lede="iOS ships no OpenGL and no DRM. The GPU is still there, behind Metal. The trick is to translate OpenGL ES into Metal, which lets GLES clients and the compositor itself run on the A10 and render straight into shared surfaces."
      />

      <Section num="03.1" title="Looking from the right ANGLE">
        <div className="prose">
          <p>
            <Ext href="https://github.com/google/angle">ANGLE</Ext> is
            Google&apos;s OpenGL ES implementation that runs on top of a native
            graphics API. Here its Metal backend is built from source and packaged
            as a deb, exposing <code>libEGL</code> and <code>libGLESv2</code>. A
            GLES program links against those as usual, and underneath, its draw
            calls become Metal.
          </p>
          <p>
            The part that matters for this project is where ANGLE puts its
            results. It can render directly into{" "}
            <Ext href="https://developer.apple.com/documentation/iosurface">IOSurfaces</Ext>
            , so a client&apos;s
            frame lands in a surface the compositor already knows how to adopt as
            a texture. That shared surface is what removes the copy.
          </p>
        </div>
      </Section>

      <Section num="03.2" title="Zero-copy compositing">
        <Panel label="Figure 03. The zero-copy path" fig="no CPU copy">
          <CopyFlow />
        </Panel>
        <div className="prose" style={{ marginTop: 22 }}>
          <p>
            A GTK4 window renders once, on the GPU, into its own IOSurface. iosc
            imports that surface as a Metal texture and blends it with the other
            windows into the output surface. The app then scans out that output.
            The same GPU that drew the window draws it to the screen, and nothing
            travels through the CPU on the way.
          </p>
        </div>
      </Section>

      <Section num="03.3" title="GTK4 on the A10, validated">
        <div className="prose">
          <p>
            GTK4&apos;s modern GL renderer works through this chain on the device.
            The renderer realizes on an ES3 ANGLE-to-Metal context, reached
            through a small wayland-egl shim, and draws into IOSurfaces.
          </p>
        </div>
      </Section>

      <Section num="03.4" title="Where X11 still uses the CPU">
        <div className="prose">
          <p>
            The classic Xios server has no hardware GLX or DRI route on iOS, so
            clients that connect directly to it render in software and draw into
            IOSurface-backed memory the app presents with Metal. X11
            compatibility can still join the GPU path through Xwayland: glamor
            renders X pixmaps with ANGLE into IOSurfaces, then iosc composites
            them like any other Wayland surface. Legacy GLX desktop-GL apps stay
            on llvmpipe.
          </p>
        </div>
      </Section>

      <NextLinks path="/graphics" />
    </>
  );
}
