import type { Metadata } from "next";
import { T } from "@/components/Term";
import { Callout, Ext, NextLinks, Panel, PageHeader, Section } from "@/components/ui";
import { pageMetadata } from "@/content/site";

export const metadata: Metadata = pageMetadata("/accessibility");

export default function Accessibility() {
  return (
    <>
      <PageHeader
        tag="Accessibility"
        title="Teaching VoiceOver to read a Linux desktop"
        lede="To iOS, the whole desktop is one opaque Metal view with nothing inside it. VoiceOver sees a rectangle. The bridge takes the accessibility tree the Linux apps already publish and re-publishes it as iOS accessibility elements, so the gestures a VoiceOver user already knows work on GTK and Qt windows."
      />

      <Section num="07.1" title="The problem">
        <div className="prose">
          <p>
            Everything else in this project translates one system&apos;s idea of
            something into another&apos;s: a battery, a clipboard, a keyboard.
            Accessibility is the same shape of problem with a much worse failure
            mode, because getting it wrong does not degrade the experience, it
            removes it. A blind user turning on VoiceOver over this desktop today
            hears nothing useful, no matter how well the desktop underneath is
            working.
          </p>
          <p>
            The good news is that neither side is missing information. Linux apps
            publish their widget tree over <T k="atspi" />: GTK4 has a native
            backend for it, Qt 6 has its own bridge inside QtGui, and GNOME
            Shell exposes its whole shell chrome the same way. iOS has a rich
            accessibility API on the other side. Nothing connects them.
          </p>
        </div>
      </Section>

      <Section num="07.2" title="The bridge">
        <div className="prose">
          <p>
            A daemon, <code>xios-a11yd</code>, sits on the accessibility bus and
            walks the AT-SPI tree of whatever is running. It streams what it
            finds over a local socket as newline-delimited JSON records: an
            initial hello, a reset, a window, then upserts as elements appear and
            change. The schema is versioned, because both ends ship separately
            and a mismatched pair is exactly the sort of thing that fails
            silently.
          </p>
          <p>
            On the iOS side, Xios.app consumes that stream and publishes real
            accessibility elements over its Metal view, so VoiceOver has
            something to focus, speak and activate. The same publisher exists in
            the per-window host used by native mode, since a Linux app living in
            its own iPadOS window has the same problem in a smaller frame.
          </p>
        </div>
        <Panel label="The wire" fig="a11y v1.1">
          <div className="prose" style={{ margin: 0 }}>
            <p style={{ margin: 0, color: "var(--ink-2)" }}>
              <code>hello</code> · <code>reset</code> · <code>window</code> ·{" "}
              <code>upsert</code>, as NDJSON over a Unix socket, with per-connection
              filters so a client can subscribe to one app instead of the whole
              desktop.
            </p>
          </div>
        </Panel>
      </Section>

      <Section num="07.3" title="Off by default, on with VoiceOver">
        <div className="prose">
          <p>
            The accessibility stack costs memory and startup time, and on a
            device this size that is not free, so GTK&apos;s accessibility
            backend is disabled by default and the bus is not started. The gate
            is VoiceOver itself: when the app sees{" "}
            <code>UIAccessibility.isVoiceOverRunning</code>{" "}change it tells{" "}
            <T k="ioscd" />, which persists that as a flag the session launchers
            read. Turn VoiceOver on, and the next app launch brings up the
            accessibility bus, the registry, and the daemon with it.
          </p>
          <p>
            There is a force flag for smoke tests, so the path can be exercised
            without toggling VoiceOver on a device you are also trying to read
            logs from.
          </p>
        </div>
      </Section>

      <Section num="07.4" title="Where it actually stands">
        <div className="prose">
          <p>
            The pieces exist and talk to each other. On-device smoke tests have
            brought up the bus against a real GTK app, walked its tree, and seen
            the daemon publish window and element records for it. The Xios app
            mirrors VoiceOver state, and the launchers honour the gate.
          </p>
        </div>
      </Section>

      <Section num="07.5" title="Orca, and why it is not the plan">
        <div className="prose">
          <p>
            Linux already has a screen reader.{" "}
            <Ext href="https://orca.gnome.org">Orca</Ext>{" "}could run here and
            read the desktop in its own voice, with its own key bindings, and for
            the X11 flavor that is a reasonable complement. It is not the primary
            design, because it would mean a VoiceOver user learning a second
            screen reader with a second gesture language to use one app on their
            iPad. The bridge aims at the opposite: the desktop should answer to
            the screen reader the person already uses.
          </p>
        </div>
      </Section>

      <NextLinks path="/accessibility" />
    </>
  );
}
