import type { Metadata } from "next";
import Link from "next/link";
import { T } from "@/components/Term";
import { Callout, Ext, NextLinks, PageHeader, Section } from "@/components/ui";
import { pageMetadata } from "@/content/site";

export const metadata: Metadata = pageMetadata("/build");

export default function Build() {
  return (
    <>
      <PageHeader
        tag="Build & packaging"
        title="Cross-compiled on a Mac, installed with apt"
        lede="Most packages are built on a Mac in Docker against the Procursus toolchain, patched, signed for the capabilities they need, and shipped as Debian packages to a Sileo repo."
      />

      <Section num="05.1" title="Standing on Procursus">
        <div className="prose">
          <p>
            The rootless bootstrap on these devices is{" "}
            <T k="procursus">
              <Ext href="https://github.com/ProcursusTeam/Procursus">Procursus</Ext>
            </T>
            , which is itself a macOS-hosted cross-compile system that already
            ships a full X11 stack prebuilt for <code>iphoneos-arm64</code>. The
            approach is to stand on that rather than rebuild it: use the
            toolchain, and spend the effort on the parts Procursus does not
            provide, starting with the native display server.
          </p>
          <p>
            Most upstream changes are kept as <T k="quilt" />-style patch series
            next to the port that needs them, applied by the recipe, so a rebuild
            reproduces them. It is not universal: the KDE and Qt tracks are still
            moving fast enough that some of their changes live in build scripts
            instead of in a series, and converting those is on hold until that
            work settles.
          </p>
          <p>
            The pipeline runs in Docker, but &quot;runs in Docker&quot; is not the
            same as one button. There is no top-level orchestrator: each build
            driver is invoked by hand with the <code>docker run</code>{" "}spelled
            out in its header, several assume a warm named volume left by an
            earlier driver, and a few stages are not in Docker at all. ANGLE is
            built on the Mac side, and the GNOME introspection typelibs are
            generated on the iPad, which makes the device a build stage rather
            than just a test target.
          </p>
        </div>
      </Section>

      <Section num="05.2" title="The harder cross-compiles">
        <dl className="deflist">
          <div className="row">
            <dt>mozjs 115</dt>
            <dd>
              SpiderMonkey cross-compiled from Linux to iOS, with its{" "}
              <T k="jit" />{" "}running on the A10. This is what lets{" "}
              <T k="gjs" />, and therefore GNOME Shell, run.
            </dd>
          </div>
          <div className="row">
            <dt>bun</dt>
            <dd>
              <Ext href="https://bun.sh">Bun</Ext>, the JavaScript runtime,
              cross-compiled to iOS. Its JIT and <code>bun:ffi</code>{" "}run even
              though iOS refuses an executable heap, by relocating generated code
              through <code>mmap</code>. opencode runs a full agent turn on the
              device.
            </dd>
          </div>
          <div className="row">
            <dt>Ladybird</dt>
            <dd>
              An independent browser engine: C++23 against the iOS SDK&apos;s
              libc++, Rust crates cross-built, Skia through GN, and a private
              vendored copy of OpenSSL so the browser&apos;s newer TLS cannot
              shadow the one apt and sshd depend on.
            </dd>
          </div>
          <div className="row">
            <dt>Introspection</dt>
            <dd>
              The GNOME Shell boot <T k="typelib">typelibs</T>{" "}were generated on
              the device with the native Procursus toolchain, then packaged as{" "}
              <code>xios-gnome-typelibs</code>.
            </dd>
          </div>
          <div className="row">
            <dt>ICU</dt>
            <dd>
              Built native-then-cross so its data compiler runs on the host. Two
              versions ship: 74 for the desktop stack, and 78 for Ladybird, which
              pins an exact match.
            </dd>
          </div>
          <div className="row">
            <dt>ANGLE</dt>
            <dd>
              <Ext href="https://github.com/google/angle">Google&apos;s ANGLE</Ext>{" "}
              built from source with the Metal backend, patched to admit the A10
              to ES3, and packaged as the <code>angle</code>{" "}deb. See{" "}
              <Link href="/graphics">the GPU path</Link>.
            </dd>
          </div>
          <div className="row">
            <dt>Qt6 and KF6</dt>
            <dd>
              Qt 6.6 with eight modules on top of qtbase, a{" "}
              <T k="kf6" />{" "}subset of about fifty runtime packages, KWin, Plasma
              Desktop, Nano and Mobile, and a growing set of KDE apps: Konsole,
              Kate, Dolphin, KCalc, Ark, Gwenview, KWrite and Okular.
            </dd>
          </div>
        </dl>
      </Section>

      <Section num="05.3" title="Signing is a build step">
        <div className="prose">
          <p>
            A cross-compiled binary is not runnable on iOS until it is{" "}
            <T k="fakesign">fakesigned</T>{" "}with <T k="ldid" />, and what it is
            allowed to do depends on the <T k="entitlement">entitlements</T>{" "}
            attached at that moment. Talking to the GPU, importing an IOSurface
            from another process and inspecting other processes are all separate
            capabilities, so packages are re-signed at publish time by
            classifying each Mach-O into a profile instead of giving every binary
            the same set.
          </p>
          <p>
            There is a sharp edge here: the Homebrew build of{" "}
            <code>ldid</code>{" "}emits DER entitlements and the one inside the
            container does not, and modern iOS wants DER for exactly the
            IOKit and IOSurface capabilities this stack needs. The publish step
            refuses a binary whose entitlement slot is missing, so nothing ships
            that would have failed at launch.
          </p>
          <p>
            Separately, every deb gets a <T k="minos" />{" "}stamped from its real
            dependency closure, which is why the flavors advertise different iOS
            floors. That pass has to run last, after the package set stops
            changing.
          </p>
        </div>
      </Section>

      <Section num="05.4" title="The repo">
        <div className="prose">
          <p>
            Packages are published to a self-contained apt repo, the same kind
            every jailbreak uses: a signed index, generated depictions, and the
            payloads themselves offloaded to blob storage. There are two of them.
            A staging repo takes everything first; production is promoted by hand,
            so the published set can sit behind the tree.
          </p>
          <p>
            The gate between them exists because of a specific accident. A
            package that <T k="shadowing">shadowed</T>{" "}the bootstrap&apos;s
            OpenSSL with a newer one took out sshd and apt on the device at once,
            which is a bad day when the device is also a build stage. Publishing
            now refuses any deb that replaces a Procursus package unless it is a
            genuine drop-in superset, with per-package waivers that have to be
            written down. The browser&apos;s newer TLS ended up vendored into a
            private directory for exactly this reason.
          </p>
        </div>
        <Callout k="Pick a flavor, not a bare package">
          There is no single <code>xios</code>{" "}package. You install one of{" "}
          <code>xios-gnome</code>, <code>xios-kde</code>,{" "}
          <code>xios-native</code>{" "}or <code>xios-x11</code>, and each pulls in
          the shared <code>xios-runtime</code>{" "}base — plus{" "}
          <code>xios-core</code>{" "}for the three fullscreen flavors.{" "}
          <T k="sileo" />{" "}is the flavor chooser; nothing custom ships to do that
          job.
        </Callout>
      </Section>

      <Section num="05.5" title="One prefix, for now">
        <div className="prose">
          <p>
            Everything is built for the <T k="rootless" />{" "}layout and bakes{" "}
            <code>/var/jb</code>{" "}into paths, launchers and entitlements. A{" "}
            <T k="rootful" />{" "}target is designed and the first pieces are in
            the tree: build targets come from a descriptor file instead of a
            hardcoded prefix, and a handful of packages render their payload from
            templates. Nothing rootful is built or published yet, and the two
            binary packages that were converted refuse to produce a rootful deb
            until a rootful server has been built and smoke-tested on hardware.
          </p>
        </div>
      </Section>

      <NextLinks path="/build" />
    </>
  );
}
