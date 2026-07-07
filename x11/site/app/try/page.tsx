import type { Metadata } from "next";
import Link from "next/link";
import { Callout, Ext, NextLinks, Panel, PageHeader, Section } from "@/components/ui";

export const metadata: Metadata = { title: "Try it yourself" };

export default function Try() {
  return (
    <>
      <PageHeader
        tag="Try it yourself"
        index="07"
        title="Run it on your device"
        lede="Everything here ships as ordinary packages. Bring a compatible jailbreak and expect some rough edges."
      />

      <Section num="07.1" title="What you need">
        <dl className="deflist">
          <div className="row">
            <dt>A jailbroken device</dt>
            <dd>
              Proven on a rootless iPad 7 (A10, iPadOS 17.6.1). Other
              jailbreakable iOS 16+ devices may work, but this is the tested
              target.
            </dd>
          </div>
          <div className="row">
            <dt>A package manager</dt>
            <dd>
              <Ext href="https://getsileo.app">Sileo</Ext>, Zebra, or plain{" "}
              <code>apt</code> on the device.
            </dd>
          </div>
        </dl>
      </Section>

      <Section num="07.2" title="Add the repo">
        <div className="prose">
          <p>
            Add <b>repo.maxleiter.com</b> as a source in your package manager. In
            Sileo, open Sources, tap the add button, and paste the URL.
          </p>
        </div>
        <Panel label="Repo" fig="apt source">
          <div className="cmd">https://repo.maxleiter.com</div>
        </Panel>
      </Section>

      <Section num="07.3" title="Pick a flavor">
        <div className="prose">
          <p>
            There is no single <code>xios</code> package. You install one flavor,
            and each pulls in the shared <code>xios-core</code> base. See{" "}
            <Link href="/flavors">Desktop flavors</Link> for what each one is.
          </p>
        </div>
        <Panel label="Install" fig="apt">
          <div className="cmd">
            <span className="p">$</span> apt install xios-kde{"  "}
            <span className="comment"># or xios-gnome, xios-native, xios-x11</span>
          </div>
        </Panel>
      </Section>

      <Section num="07.4" title="Launch it">
        <div className="prose">
          <p>
            Open the app (it shows on the Home Screen as X11) and pick a session.
            From there, gestures drive it: a three-finger tap switches between
            running displays, a four-finger tap opens the session and dimension
            picker, a pinch zooms to fit, and a swipe up from the lower edge raises
            the keyboard.
          </p>
        </div>
        <Callout>
          Native mode is the exception to the desktop flow: its apps land on the
          Home Screen and launch like any other app, no session to pick.
        </Callout>
      </Section>

      <NextLinks path="/try" />
    </>
  );
}
