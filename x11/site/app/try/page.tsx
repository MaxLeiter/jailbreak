import type { Metadata } from "next";
import Link from "next/link";
import { T } from "@/components/Term";
import { Callout, Ext, NextLinks, Panel, PageHeader, Section } from "@/components/ui";
import { SITE } from "@/content/site";

export const metadata: Metadata = { title: "Try it yourself" };

export default function Try() {
  return (
    <>
      <PageHeader
        tag="Try it yourself"
        index="08"
        title="Run it on your device"
        lede="Everything here ships as ordinary packages, the display app included. Bring a compatible jailbreak and expect some rough edges: this is a hand-assembled system that has been proven on exactly one iPad."
      />

      <Section num="08.1" title="What you need">
        <dl className="deflist">
          <div className="row">
            <dt>A jailbroken iPad</dt>
            <dd>
              Proven on an iPad 7 (A10, iPadOS 17.6.1) jailbroken with{" "}
              <Ext href="https://ellekit.space/dopamine/">Dopamine</Ext>. It must
              be a <T k="rootless" />{" "}jailbreak: every binary bakes{" "}
              <code>/var/jb</code>, so a <T k="rootful" />{" "}setup cannot install
              a working set no matter what the metadata says. RootHide resolves
              its own <code>/var/jb</code>{" "}symlink and works as-is.
            </dd>
          </div>
          <div className="row">
            <dt>iOS 16.5 or newer</dt>
            <dd>
              The GNOME, KDE and X11 flavors declare a 16.5 floor; the core and
              native flavors go back to 16.0. Older devices will simply not be
              offered the package.
            </dd>
          </div>
          <div className="row">
            <dt>A package manager</dt>
            <dd>
              <T k="sileo">
                <Ext href="https://getsileo.app">Sileo</Ext>
              </T>
              , Zebra, or plain <code>apt</code>{" "}on the device.
            </dd>
          </div>
          <div className="row">
            <dt>Nothing else</dt>
            <dd>
              The display app installs from the repo like everything else, as{" "}
              <code>com.max.xios</code>. No Mac, no sideloading, no developer
              account.
            </dd>
          </div>
        </dl>
      </Section>

      <Section num="08.2" title="Add the repo">
        <div className="prose">
          <p>
            Add <b>repo.maxleiter.com</b>{" "}as a source in your package manager.
            In Sileo, open Sources, tap the add button, and paste the URL.
          </p>
        </div>
        <Panel label="Repo" fig="apt source">
          <div className="cmd">{SITE.repo}</div>
        </Panel>
        <Callout>
          Production is promoted by hand, not on every build, so a
          package described elsewhere on this site may not have been pushed there
          yet. If apt cannot find something, that is the usual reason.
        </Callout>
      </Section>

      <Section num="08.3" title="Pick a flavor">
        <div className="prose">
          <p>
            There is no single <code>xios</code>{" "}package. You install one
            flavor, and each pulls in the shared <code>xios-core</code>{" "}base.
            See <Link href="/flavors">Desktop flavors</Link>{" "}for what each one
            is.
          </p>
        </div>
        <Panel label="Install" fig="apt">
          <div className="cmd">
            <span className="p">$</span> apt install com.max.xios xios-kde
            xios-launcher-tools{"  "}
            <span className="comment"># or xios-gnome, xios-native, xios-x11</span>
          </div>
        </Panel>
        <Callout k="Install the launcher tools too">
          The in-app picker starts desktops by asking <T k="ioscd" />, and only
          the native flavor pulls that daemon in today. Adding{" "}
          <code>xios-launcher-tools</code>{" "}and <code>xios-session</code>{" "}
          explicitly saves you a picker that cannot start anything. For the iosc
          desktop itself, add <code>iosc-shell</code>.
        </Callout>
      </Section>

      <Section num="08.4" title="Launch it">
        <div className="prose">
          <p>
            Unlock the iPad and open the app; it shows on the Home Screen as X11.
            A three-finger tap opens the control panel, which is where you start a
            desktop, resize a running one, choose which apps get Home Screen
            icons, and reach Advanced for switching between{" "}
            <T k="displaySlot">display slots</T>. Pull down from the top edge for
            the status overlay, pinch to zoom to fit, and swipe up from the lower
            edge to raise the keyboard.
          </p>
          <p>
            There is a command-line equivalent if you would rather drive it over
            SSH: <code>xios-session</code>{" "}takes <code>iosc</code>,{" "}
            <code>mutter</code>, <code>gnome</code>, <code>kde</code>,{" "}
            <code>kde-nano</code>{" "}or <code>kde-mobile</code>, plus{" "}
            <code>status</code>{" "}and <code>stop</code>.
          </p>
        </div>
        <Panel label="Launch" fig="over ssh">
          <div className="cmd">
            <span className="p">$</span> xios-session kde
          </div>
        </Panel>
        <Callout k="The screen has to be awake">
          Metal hands back no device while the app is backgrounded, so a session
          started against a locked or sleeping iPad will not come up. Unlock
          first, then launch.
        </Callout>
      </Section>

      <Section num="08.5" title="What to expect">
        <div className="prose">
          <p>
            All three KDE presets are marked experimental in the launcher itself,
            and GNOME&apos;s first light works while daemon and app concurrency
            cleanup continues. The X11 flavor has no entry in the session picker:
            the classic server is started by its own <code>xios-server</code>{" "}
            command, and its VNC route is still the practical way to use it.
            Native mode uses Home Screen launchers instead of the picker.
          </p>
        </div>
      </Section>

      <Section num="08.6" title="Send feedback">
        <div className="prose">
          <p>
            If you try it, file bugs, install notes, screenshots, and device
            details on{" "}
            <Ext href="https://github.com/MaxLeiter/jailbreak/issues">
              GitHub Issues
            </Ext>{" "}
            for <code>maxleiter/jailbreak</code>. Include the device, iOS
            version, jailbreak, package flavor, and what happened.{" "}
            <Link href="/contributing">Contributing</Link>{" "}covers how to
            collect the evidence that makes a report actionable.
          </p>
        </div>
      </Section>

      <NextLinks path="/try" />
    </>
  );
}
