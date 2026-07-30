import type { Metadata } from "next";
import { CopyFlow, Zoom } from "@/components/Figures";
import { T } from "@/components/Term";
import { Callout, Ext, NextLinks, Panel, PageHeader, Section } from "@/components/ui";
import { pageMetadata } from "@/content/site";

export const metadata: Metadata = pageMetadata("/graphics");

export default function Graphics() {
  return (
    <>
      <PageHeader
        tag="Graphics"
        title="Reaching the A10 without desktop OpenGL"
        lede="iOS gives this stack no DRM/KMS path, and desktop OpenGL is not available. The GPU is still there, behind Metal. ANGLE translates OpenGL ES into Metal, which lets GLES clients and the compositors themselves run on the A10 and render straight into shared surfaces."
      />

      <Section num="03.1" title="Looking from the right ANGLE">
        <div className="prose">
          <p>
            <T k="angle">
              <Ext href="https://github.com/google/angle">ANGLE</Ext>
            </T>{" "}
            is Google&apos;s OpenGL ES implementation that runs on top of a native
            graphics API. Here its <T k="metal" />{" "}backend is built from source
            and packaged as a <T k="deb" />, exposing <code>libEGL</code>{" "}and{" "}
            <code>libGLESv2</code>. A <T k="gles" />{" "}program links against those
            and its draw calls become Metal.
          </p>
          <p>
            The build is not stock. One local patch admits Apple GPU Family 3,
            the A10&apos;s family, to ES3 in the Metal backend. Upstream stops at
            ES2, and GTK4&apos;s GL renderer wants ES3. Without that patch most of
            this page does not happen.
          </p>
          <p>
            The part that matters most is where ANGLE puts its results. It can
            render directly into{" "}
            <T k="iosurface">
              <Ext href="https://developer.apple.com/documentation/iosurface">
                IOSurfaces
              </Ext>
            </T>
            , so a client&apos;s frame lands in a surface the compositor already
            knows how to adopt as a texture. That shared surface is what removes
            the copy.
          </p>
        </div>
      </Section>

      <Section num="03.2" title="The shim in front of ANGLE">
        <div className="prose">
          <p>
            ANGLE has no Wayland platform on iOS, and iOS has no{" "}
            <code>dma-buf</code>, so the normal Linux way for a toolkit to get a
            GPU surface does not exist here. That gap is filled by a small
            library, <code>libiosc_egl</code>, which is installed in ANGLE&apos;s
            place as <code>libEGL.dylib</code>; real ANGLE stays next to it as{" "}
            <code>libEGL.angle.dylib</code>.
          </p>
          <p>
            It is a shim, not a renderer. It <code>dlopen</code>s the real ANGLE
            and forwards nearly every <T k="egl" />{" "}call straight through. It
            intercepts four: creating a display (it returns an ANGLE Metal
            display and remembers the <code>wl_display</code>), creating a window
            surface (it allocates IOSurfaces and wraps them as ANGLE{" "}
            <T k="pbuffer">pbuffers</T>), making one current, and swapping
            buffers (it fences the finished surface, hands it to the compositor
            over <T k="iosurfaceProtocol" />, and rotates to the next free one).
          </p>
        </div>
        <Callout k="So is it really hardware?">
          Yes. Every draw call still executes in ANGLE on Metal on the A10 GPU.
          The shim never touches pixels; it decides which IOSurface the GPU draws
          into and who owns it next. What it buys is that an unmodified
          toolkit doing the standard{" "}
          <T k="waylandEgl">
            <code>wayland-egl</code>
          </T>{" "}
          dance renders <T k="zeroCopy">zero-copy</T>{" "}into a buffer the
          compositor can use as-is.
        </Callout>
      </Section>

      <Section num="03.3" title="Zero-copy compositing">
        <Panel label="Figure 03. The zero-copy path" fig="no CPU copy">
          <Zoom label="The zero-copy path">
            <CopyFlow />
          </Zoom>
        </Panel>
        <div className="prose" style={{ marginTop: 22 }}>
          <p>
            A GTK4 window renders once, on the GPU, into its own IOSurface. iosc
            binds that surface as a GL texture and blends it with the other
            windows into the output surface, itself through ANGLE. The app then
            scans out that output. The same GPU that drew the window draws it to
            the screen.
          </p>
          <p>
            Not everything is on that path. Clients that still paint into{" "}
            <T k="wlShm" />{" "}buffers, which includes anything falling back to
            software Qt, are drawn by the CPU and uploaded as a texture per
            damaged region. The compositor says so loudly in its log if GL
            initialization fails and it has to composite that way for everyone.
          </p>
        </div>
      </Section>

      <Section num="03.4" title="GTK4 on the A10">
        <div className="prose">
          <p>
            GTK4&apos;s modern GL renderer works through this chain on the
            device. The renderer realizes on an ES3 ANGLE-to-Metal context,
            reached through the shim above, and draws into IOSurfaces.
          </p>
        </div>
      </Section>

      <Section num="03.5" title="KWin, the second GPU compositor">
        <div className="prose">
          <p>
            Plasma does not use iosc&apos;s compositing. KWin brings its own EGL
            backend, so under the KDE flavor there are two GPU compositors
            stacked: KWin renders Plasma&apos;s windows into an IOSurface of its
            own, and iosc treats that surface like any other client buffer. The
            work to make that land was most of July, and every bug was in a seam
            and not in the drawing:
          </p>
          <ul style={{ color: "var(--ink-2)", paddingLeft: 20, lineHeight: 1.7 }}>
            <li>
              The bundled copy of the <T k="iosurfaceProtocol" />{" "}protocol was a
              version behind the compositor&apos;s, so the connection died on an
              event the client had never heard of.
            </li>
            <li>
              A one-hex-digit mistake in <code>EGL_TEXTURE_TYPE_ANGLE</code>{" "}
              made every IOSurface pbuffer fail to allocate.
            </li>
            <li>
              KWin rendered into framebuffer zero, which for an ANGLE IOSurface
              pbuffer is not the IOSurface. The screen stayed black until the
              surface was bound as a texture and hung off an explicit
              framebuffer.
            </li>
            <li>
              With no frame callback requested on present, the render loop drew
              exactly one frame and then waited forever.
            </li>
          </ul>
          <p>
            With those closed, Plasma&apos;s QtQuick shell came off its software
            fallback and KWin now ships its effects, scripts and window
            decorations, with blur and background contrast active on device.
          </p>
        </div>
      </Section>

      <Section num="03.6" title="Signing is part of the GPU path">
        <div className="prose">
          <p>
            On iOS a process cannot create a Metal device without the GPU{" "}
            <T k="entitlement" />, and entitlements attach to a process, not to a
            library. Linking ANGLE is not enough: every binary that will touch
            the GPU has to be signed for it, so the publish step re-signs
            graphics packages by classifying each Mach-O into a capability profile
            instead of stamping every binary the same way.
          </p>
        </div>
      </Section>

      <Section num="03.7" title="Where the CPU still gets used">
        <div className="prose">
          <p>
            X11 compatibility is on the GPU path now. Xwayland is the only X route
            that ships: <T k="glamor" />{" "}renders X pixmaps with ANGLE into
            IOSurfaces, then iosc composites them like any other Wayland surface.
            The software X server that used to sit beside it — no hardware{" "}
            <T k="glx" />{" "}or <T k="dri" />{" "}route exists on iOS, so its clients
            drew on the CPU — was retired on 2026-07-29.
          </p>
          <p>
            What is left on the CPU is narrower than it used to be. iOS exposes no{" "}
            <T k="drmKms" />{" "}device at all, so nothing here goes through the
            Linux display stack; apps that insist on desktop OpenGL rather than
            GLES still fall back to <T k="llvmpipe" />; and Xvfb and Xvnc remain
            software servers, kept for headless bring-up and debugging rather than
            for running a desktop.
          </p>
        </div>
      </Section>

      <NextLinks path="/graphics" />
    </>
  );
}
