import type { Metadata } from "next";
import Link from "next/link";
import { Callout, Ext, NextLinks, Panel, PageHeader, Section } from "@/components/ui";
import { pageMetadata } from "@/content/site";

export const metadata: Metadata = pageMetadata("/try");

export default function Try() {
  return (
    <>
      <PageHeader
        tag="Try it yourself"
        index="08"
        title="Run it on your device"
        lede="Everything here ships as ordinary packages. Install one flavor, open one app, and you have a desktop. Bring a compatible jailbreak and expect some rough edges."
      />

      <Section num="08.1" title="What you need">
        <dl className="deflist">
          <div className="row">
            <dt>A jailbroken device</dt>
            <dd>
              Proven on an iPad 7 (A10, iPadOS 17.6.1) on{" "}
              <Ext href="https://ellekit.space/dopamine/">Dopamine</Ext>. Other
              jailbroken iOS 16+ devices may work, but this is the tested target.
              Rootless only: every binary bakes in <code>/var/jb</code>, so a
              rooted jailbreak cannot run this. RootHide resolves its own{" "}
              <code>/var/jb</code> symlink and works as-is.
            </dd>
          </div>
          <div className="row">
            <dt>A package manager</dt>
            <dd>
              <Ext href="https://getsileo.app">Sileo</Ext>, Zebra, or plain{" "}
              <code>apt</code> on the device.
            </dd>
          </div>
          <div className="row">
            <dt>AppSync Unified</dt>
            <dd>
              Required, and easy to forget. The display app is unsigned, and
              without AppSync it will not launch. Add{" "}
              <code>https://cydia.akemi.ai/</code> as a source and install it
              before you install a flavor.
            </dd>
          </div>
          <div className="row">
            <dt>Some free space</dt>
            <dd>
              About 190 MB installed for GNOME and 550 MB for KDE. The native and
              X11 flavors are around 55 MB.
            </dd>
          </div>
        </dl>
      </Section>

      <Section num="08.2" title="Add the repo">
        <div className="prose">
          <p>
            Add <b>repo.maxleiter.com</b> as a source in your package manager. In
            Sileo, open Sources, tap the add button, and paste the URL.
          </p>
        </div>
        <Panel label="Repo" fig="apt source">
          <div className="cmd">https://repo.maxleiter.com</div>
        </Panel>
        <div className="prose" style={{ marginTop: 14 }}>
          <p>
            From a shell instead, as root. It is a flat repo, so the suite is{" "}
            <code>./</code>.
          </p>
        </div>
        <Panel label="Shell" fig="sources.list.d">
          <div className="cmd">
            <span className="p">#</span> echo &apos;deb [trusted=yes]
            https://repo.maxleiter.com ./&apos; &gt;
            /var/jb/etc/apt/sources.list.d/maxleiter.list
          </div>
          <div className="cmd">
            <span className="p">#</span> apt update
          </div>
        </Panel>
      </Section>

      <Section num="08.3" title="Pick a flavor">
        <div className="prose">
          <p>
            There is no single <code>xios</code> package. You install one flavor,
            and each pulls in the shared <code>xios-core</code> base. See{" "}
            <Link href="/flavors">Desktop flavors</Link> for what each one is.
          </p>
        </div>
        <dl className="deflist" style={{ marginTop: 8 }}>
          <div className="row">
            <dt>
              <code>xios-gnome</code>
            </dt>
            <dd>
              GNOME Shell 46 on Mutter with the full session layer. Needs iOS
              16.5.
            </dd>
          </div>
          <div className="row">
            <dt>
              <code>xios-kde</code>
            </dt>
            <dd>
              KWin with Plasma Desktop, Plasma Mobile, and Plasma Nano, plus
              System Settings and Breeze. Newer and rougher than GNOME. Needs iOS
              16.5.
            </dd>
          </div>
          <div className="row">
            <dt>
              <code>xios-native</code>
            </dt>
            <dd>
              No Linux shell: apps get Home Screen icons and their own iPadOS
              windows. Needs iOS 16.0.
            </dd>
          </div>
          <div className="row">
            <dt>
              <code>xios-x11</code>
            </dt>
            <dd>
              The Xios X server for classic X11 clients, plus Xwayland. Needs iOS
              16.5.
            </dd>
          </div>
        </dl>
        <Panel label="Install" fig="apt">
          <div className="cmd">
            <span className="p">#</span> apt install xios-gnome{"  "}
            <span className="comment"># or xios-kde, xios-native, xios-x11</span>
          </div>
        </Panel>
        <div className="prose" style={{ marginTop: 14 }}>
          <p>
            Whichever you pick, the install brings the display app{" "}
            <code>com.max.xios</code>, the iosc compositor and its desktop shell,
            ANGLE for the GPU path, the session launcher, and the font and locale
            defaults. Every flavor therefore also has the iosc desktop, which is
            the most reliable session and a good first thing to try.
          </p>
        </div>
      </Section>

      <Section num="08.4" title="Launch it">
        <div className="prose">
          <p>
            Open the app (it shows on the Home Screen as <b>X11</b>) and pick a
            session. From there, gestures drive it: a three-finger tap opens the
            control panel, where you start a desktop, resize a running one, choose
            which apps get Home Screen icons, and reach Advanced for switching
            between running displays. A pull-down from the top edge reveals the
            status overlay, a pinch zooms to fit, and a swipe up from the lower
            edge raises the keyboard.
          </p>
          <p>The same thing from a shell, on the device or over SSH, as root:</p>
        </div>
        <Panel label="Sessions" fig="xios-session">
          <div className="cmd">
            <span className="p">#</span> xios-session iosc{"  "}
            <span className="comment"># the iosc desktop shell</span>
          </div>
          <div className="cmd">
            <span className="p">#</span> xios-session gnome{"  "}
            <span className="comment"># GNOME session and Shell</span>
          </div>
          <div className="cmd">
            <span className="p">#</span> xios-session kde-mobile{"  "}
            <span className="comment"># or kde, kde-nano</span>
          </div>
          <div className="cmd">
            <span className="p">#</span> xios-session status
          </div>
          <div className="cmd">
            <span className="p">#</span> xios-session stop{"  "}
            <span className="comment"># back to SpringBoard</span>
          </div>
        </Panel>
        <Callout k="Keep the screen awake">
          A locked or sleeping iPad gets the Metal app suspended by FrontBoard, so
          a session that starts behind a locked screen presents a black frame.
          Unlock first.
        </Callout>
        <Callout>
          Native mode uses Home Screen launchers instead of the session picker.
          Installing the flavor does not create icons by itself: choose apps in
          the Xios pane in Settings, or run <code>xios-launcher-sync</code>.
        </Callout>
      </Section>

      <Section num="08.5" title="When it does not come up">
        <dl className="deflist">
          <div className="row">
            <dt>The X11 icon does nothing</dt>
            <dd>
              AppSync Unified is missing, or the app lost its signature. Reinstall
              AppSync, then <code>apt install --reinstall com.max.xios</code>.
            </dd>
          </div>
          <div className="row">
            <dt>Black screen with the app open</dt>
            <dd>
              Either the device was locked while the session started, or no
              display server is running. Unlock, then check{" "}
              <code>xios-session status</code>.
            </dd>
          </div>
          <div className="row">
            <dt>Status says compositor-only</dt>
            <dd>
              The compositor came up but the shell never painted. The log for the
              flavor you picked has the reason.
            </dd>
          </div>
          <div className="row">
            <dt>Logs</dt>
            <dd>
              All under <code>/var/jb/tmp/</code>: <code>xios-session.log</code>,{" "}
              <code>xios-session-status.json</code>,{" "}
              <code>gnome-shell.log</code>, <code>kde-plasma.log</code>.
            </dd>
          </div>
          <div className="row">
            <dt>Something was left behind</dt>
            <dd>
              <code>xios-session stop</code> tears down compositors and sockets
              completely. It is safe to run at any time.
            </dd>
          </div>
        </dl>
      </Section>

      <Section num="08.6" title="Send feedback">
        <div className="prose">
          <p>
            If you try it, file bugs, install notes, screenshots, and device
            details on{" "}
            <Ext href="https://github.com/MaxLeiter/jailbreak/issues">
              GitHub Issues
            </Ext>{" "}
            for <code>maxleiter/jailbreak</code>. Include the device, iOS version,
            jailbreak, package flavor, and what happened.
          </p>
        </div>
      </Section>

      <NextLinks path="/try" />
    </>
  );
}
