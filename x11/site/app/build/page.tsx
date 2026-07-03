import type { Metadata } from "next";
import { Callout, Ext, NextLinks, PageHeader, Section } from "@/components/ui";

export const metadata: Metadata = { title: "Build & packaging" };

export default function Build() {
  return (
    <>
      <PageHeader
        tag="Build & packaging"
        title="Cross-compiled on a Mac, installed with apt"
        lede="Everything is built on a Mac in Docker against the Procursus toolchain, patched reproducibly, and shipped as Debian packages to a Sileo repo. Nothing is compiled on the device."
      />

      <Section num="05.1" title="Standing on Procursus">
        <div className="prose">
          <p>
            The rootless bootstrap on these devices is{" "}
            <Ext href="https://github.com/ProcursusTeam/Procursus">Procursus</Ext>
            , which is itself a macOS-hosted cross-compile system that already
            ships a full X11 stack prebuilt for <code>iphoneos-arm64</code>. The
            approach is to stand on that rather than rebuild it: use the
            toolchain, and spend the effort on the parts Procursus does not
            provide, starting with the native display server.
          </p>
          <p>
            Patches are managed with{" "}
            <abbr title="a tool for keeping a stack of source-code patches">quilt</abbr>
            , so every change to upstream source is
            tracked and the build stays reproducible. The pipeline runs in Docker,
            so it behaves the same on any machine.
          </p>
        </div>
      </Section>

      <Section num="05.2" title="The harder cross-compiles">
        <dl className="deflist">
          <div className="row">
            <dt>mozjs 115</dt>
            <dd>
              SpiderMonkey cross-compiled from Linux to iOS, with its JIT running
              on the A10. This is what lets{" "}
              <abbr title="GNOME's JavaScript engine; GNOME Shell is written in it">
                gjs
              </abbr>
              , and therefore GNOME Shell, run.
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
            <dt>Introspection</dt>
            <dd>
              GObject-introspection typelibs are scanned <b>on the device</b> with
              the native Procursus toolchain, which sidesteps a cross-scan that
              does not work under emulation.
            </dd>
          </div>
          <div className="row">
            <dt>ICU</dt>
            <dd>
              Built native-then-cross so its data compiler runs on the host, which
              unblocks Evolution Data Server and tracker full-text search
              downstream.
            </dd>
          </div>
          <div className="row">
            <dt>ANGLE</dt>
            <dd>
              <Ext href="https://github.com/google/angle">Google&apos;s ANGLE</Ext>{" "}
              built from source with the Metal backend, packaged as the{" "}
              <code>angle</code>{" "}deb.
            </dd>
          </div>
          <div className="row">
            <dt>Qt6 and KF6</dt>
            <dd>
              A six-module <Ext href="https://www.qt.io">Qt6</Ext>{" "}ladder plus a
              subset of KDE Frameworks 6, built for the KDE desktop.
            </dd>
          </div>
        </dl>
      </Section>

      <Section num="05.3" title="The repo">
        <div className="prose">
          <p>
            Packages are published to a self-contained apt repo, the same kind
            every jailbreak uses.
          </p>
        </div>
        <Callout k="Pick a flavor, not a bare package">
          There is no single <code>xios</code>{" "}package. You install one of{" "}
          <code>xios-gnome</code>, <code>xios-kde</code>,{" "}
          <code>xios-native</code>, or <code>xios-x11</code>, and each pulls in
          the shared <code>xios-core</code>{" "}base. From there the in-app session
          picker lets you switch between running desktops.
        </Callout>
      </Section>

      <NextLinks path="/build" />
    </>
  );
}
