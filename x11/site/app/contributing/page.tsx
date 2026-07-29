import type { Metadata } from "next";
import Link from "next/link";
import { T, TermList } from "@/components/Term";
import { Callout, Ext, NextLinks, Panel, PageHeader, Section } from "@/components/ui";

export const metadata: Metadata = { title: "Contributing" };

export default function Contributing() {
  return (
    <>
      <PageHeader
        tag="Contributing"
        title="Working on this"
        lede="The source is MIT-licensed and public. This page is the orientation: where things live, how a change gets proven on hardware, and the conventions that keep the package set from breaking a device."
      />

      <Section num="09.1" title="Where things live">
        <dl className="deflist">
          <div className="row">
            <dt>x11/wayland</dt>
            <dd>
              The compositor, <T k="iosc" />, plus the EGL shim, the Mutter iOS
              backend, and the small daemons that bridge hardware.
            </dd>
          </div>
          <div className="row">
            <dt>x11/apps</dt>
            <dd>
              The Swift side: Xios.app, the per-window native host, the iosc
              shell, and the session tooling.
            </dd>
          </div>
          <div className="row">
            <dt>x11/ports and x11/linux-build</dt>
            <dd>
              Everything cross-compiled from upstream source: patch series per
              port, recipes, and the build drivers that run them in Docker.
            </dd>
          </div>
          <div className="row">
            <dt>x11/packages</dt>
            <dd>
              Packages we wrote ourselves, including the flavor metas.
            </dd>
          </div>
          <div className="row">
            <dt>x11/docs</dt>
            <dd>
              Plans, per-subsystem handoff notes, and device snapshots. Most of
              this site is downstream of those documents.
            </dd>
          </div>
          <div className="row">
            <dt>bin</dt>
            <dd>Repo generation, the publish pipeline and its gates.</dd>
          </div>
        </dl>
      </Section>

      <Section num="09.2" title="Proving it on hardware">
        <div className="prose">
          <p>
            Nothing here is really done until it has run on an iPad. A
            cross-compile that links is not evidence, a package that installs is
            not evidence, and a screenshot of a desktop that might be a stale
            frame is worse than no evidence. So there is a harness for it:{" "}
            <T k="xiosDevice" />{" "}wraps the SSH details and the on-device
            helpers, and writes what it collects into a timestamped evidence
            directory.
          </p>
        </div>
        <Panel label="xios-device" fig="host side">
          <div className="cmd">
            <span className="p">$</span> bin/xios-device doctor{"  "}
            <span className="comment"># host tools, SSH, on-device helpers</span>
          </div>
          <div className="cmd">
            <span className="p">$</span> bin/xios-device session kde
          </div>
          <div className="cmd">
            <span className="p">$</span> bin/xios-device app konsole
          </div>
          <div className="cmd">
            <span className="p">$</span> bin/xios-device shot
          </div>
        </Panel>
        <div className="prose" style={{ marginTop: 18 }}>
          <p>
            <code>shot</code>{" "}is the interesting one, because capturing a
            screen on a device like this can lie to you in several ways. It tries
            grim against the Wayland output first, falls back to a screencopy
            client of our own, and can fall back again to a host-side capture
            over the pairing connection. It also runs a pixel probe and counts
            what is actually non-black, so you can measure whether the desktop
            rendered instead of squinting at it, and collects the status files and
            logs next to the image.
          </p>
          <p>
            There is a matching pair of smoke drivers for app waves and for the
            KDE session, which launch a client, wait, capture, and diagnose the
            failure if it never mapped.
          </p>
        </div>
        <Callout k="Say what you actually saw">
          Device reports in this project are expected to distinguish built,
          installed, launched and verified. &quot;Should work&quot; is not one of
          those states, and the difference between them is most of what the
          handoff notes in <code>x11/docs</code>{" "}are for.
        </Callout>
      </Section>

      <Section num="09.3" title="Conventions to pick up early">
        <dl className="deflist">
          <div className="row">
            <dt>+iosN versions</dt>
            <dd>
              Anything rebuilt from upstream carries a marker on the Debian
              version, like <code>6.1.5+ios27</code>. Packages that are ours
              carry no marker. Reading a version tells you which kind you are
              looking at, and how many times we have had to touch it.
            </dd>
          </div>
          <div className="row">
            <dt>Patch series, not sed</dt>
            <dd>
              Upstream changes belong in a <T k="quilt" />-style series next to
              the port. Procedural edits inside build scripts exist, but they are
              debt, and they are tracked as debt.
            </dd>
          </div>
          <div className="row">
            <dt>Sign for the capability</dt>
            <dd>
              A binary that touches the GPU or imports another process&apos;s
              IOSurface needs the matching <T k="entitlement">entitlements</T>{" "}
              at signing time. See <Link href="/graphics">the GPU path</Link>.
            </dd>
          </div>
          <div className="row">
            <dt>Never shadow the bootstrap</dt>
            <dd>
              Publishing a package that replaces one <T k="procursus" />{" "}already
              provides is how this project once bricked apt and sshd on its own
              test device. The publish step now refuses that unless the
              replacement is a genuine drop-in superset with a written waiver.
            </dd>
          </div>
          <div className="row">
            <dt>Rootless only</dt>
            <dd>
              Everything bakes <code>/var/jb</code>. A <T k="rootful" />{" "}target
              is designed and partly scaffolded, but nothing rootful is built or
              published, and the converted packages refuse to produce one until a
              rootful server has been smoke-tested on hardware.
            </dd>
          </div>
        </dl>
      </Section>

      <Section num="09.4" title="Filing something useful">
        <div className="prose">
          <p>
            Issues go to{" "}
            <Ext href="https://github.com/MaxLeiter/jailbreak/issues">
              GitHub
            </Ext>
            . The details that make a report actionable here are the device and
            iOS version, the jailbreak, the flavor and package versions, whether
            the screen was awake, and the compositor and session logs from{" "}
            <code>/var/jb/tmp</code>. If you can run the harness,{" "}
            <code>xios-device collect</code>{" "}gathers most of that for you.
          </p>
        </div>
      </Section>

      <Section num="09.5" title="Glossary">
        <div className="prose">
          <p>
            Names this project invented, which appear in logs, package lists and
            everywhere on this site.
          </p>
        </div>
        <TermList
          keys={[
            "iosc",
            "ioscd",
            "xiosSession",
            "xiosDevice",
            "displaySlot",
            "iosurfaceProtocol",
            "rootless",
            "rootful",
            "procursus",
            "shadowing",
            "minos",
          ]}
        />
      </Section>

      <NextLinks path="/contributing" />
    </>
  );
}
