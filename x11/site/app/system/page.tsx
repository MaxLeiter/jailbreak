import type { Metadata } from "next";
import { Bridges } from "@/components/Figures";
import { T } from "@/components/Term";
import { Ext, NextLinks, PageHeader, Section } from "@/components/ui";
import { pageMetadata } from "@/content/site";

export const metadata: Metadata = pageMetadata("/system");

export default function System() {
  return (
    <>
      <PageHeader
        tag="System integration"
        title="Battery, sound, brightness, and the rest"
        lede="A desktop expects the hardware a Linux box would have: a battery, speakers, a brightness slider, Bluetooth, a keyboard, orientation. iOS exposes all of it, just not the way Linux looks for it. A set of small daemons translate each one."
      />

      <Section num="06.1" title="The pattern">
        <div className="prose">
          <p>
            Every integration is a small daemon that owns the interface the
            desktop already expects, a D-Bus service, a Wayland protocol, or a
            file under{" "}
            <T k="sysfs">
              <code>/sys</code>
            </T>
            , and answers it with the matching iOS
            API. The iOS side is reached with <code>dlopen</code>{" "}and the
            Objective-C runtime, so nothing links a private framework at build
            time and every probe degrades cleanly when the API is missing. It is
            the same shim trick behind the <T k="logind" />, polkit, and Accounts
            stubs that let GNOME start.
          </p>
        </div>
      </Section>

      <Section num="06.2" title="Audio">
        <div className="prose">
          <p>
            <code>xios-audiod</code>{" "}opens a{" "}
            <Ext href="https://developer.apple.com/documentation/coreaudio">CoreAudio</Ext>{" "}
            RemoteIO output under an{" "}
            <Ext href="https://developer.apple.com/documentation/avfaudio/avaudiosession">
              <code>AVAudioSession</code>
            </Ext>{" "}
            set to the Playback category, so sound
            keeps going through the mute switch and the lock screen. Apps never
            talk to it directly. PulseAudio modules present an ordinary sink and
            microphone source, <code>xios</code>{" "}and <code>xios_mic</code>, so GTK,
            gvc, and PulseAudio clients route through the native daemons.
          </p>
        </div>
      </Section>

      <Section num="06.3" title="Brightness and battery">
        <div className="prose">
          <p>
            <code>xios-hwbridged</code>{" "}reads the battery with{" "}
            <Ext href="https://developer.apple.com/documentation/iokit">IOKit</Ext>
            &apos;s{" "}
            <code>IOPSCopyPowerSourcesInfo</code>{" "}and the screen brightness with
            BackBoardServices&apos; <code>BKSDisplayBrightnessGetCurrent</code>{" "}and{" "}
            <code>Set</code>, both dlopen&apos;d. It republishes the battery as{" "}
            UPower, so the shell shows a real charge level, and backs the
            brightness slider with a <code>org.gnome.SettingsDaemon.Power.Screen</code>{" "}
            shim plus a synthetic <code>/var/jb/sys/class/backlight</code>, so
            moving the slider dims the actual display.
          </p>
        </div>
      </Section>

      <Section num="06.4" title="Bluetooth">
        <div className="prose">
          <p>
            GNOME&apos;s Bluetooth panel and quick toggle expect BlueZ on D-Bus,
            which iOS does not have. <code>xios-bluez-stub</code>{" "}owns{" "}
            <code>org.bluez</code>{" "}and answers the slice gnome-bluetooth actually
            uses, adapters and devices, power and scan state. Connect and
            disconnect support is still being brought up against iOS&apos;s private{" "}
            <code>BluetoothManager</code> framework.
          </p>
        </div>
      </Section>

      <Section num="06.5" title="Keyboard, orientation, and feel">
        <div className="prose">
          <p>
            The keyboard is the neat one. When a Wayland app focuses a text field
            it enables the{" "}
            <T k="textInput">
              <code>text-input-v3</code>
            </T>{" "}
            protocol; iosc sees that
            enable and treats it as the cue to raise the iOS on-screen keyboard,
            then dismisses it when the field loses focus. The same protocol carries
            the field&apos;s traits, so an email field gets the email keyboard and a
            search box gets a Search return key, and what you type comes back as
            text-input commits rather than a faked hardware keyboard. That whole
            path is <code>xios-osk</code>.
          </p>
          <p>
            The rest ride smaller bridges.{" "}
            <Ext href="https://developer.apple.com/documentation/coremotion">CoreMotion</Ext>{" "}
            feeds a SensorProxy-compatible shim, and{" "}
            <code>xios-sysintd</code>{" "}wires the hardware volume buttons to{" "}
            <code>pactl</code>, the system light and dark setting to the GNOME
            color scheme, and device rotation to a live iosc resize. It also
            carries haptic requests toward{" "}
            <Ext href="https://developer.apple.com/documentation/uikit/uifeedbackgenerator">
              <code>UIFeedbackGenerator</code>
            </Ext>{" "}
            while the physical feel is still being tuned.
          </p>
          <p>
            The iosc shell&apos;s own top bar skips D-Bus entirely and reads the
            device directly: battery from IOKit, Wi-Fi and cellular from{" "}
            <Ext href="https://developer.apple.com/documentation/systemconfiguration">
              SystemConfiguration
            </Ext>{" "}
            reachability, and the device name from
            MobileGestalt.
          </p>
        </div>
      </Section>

      <Section num="06.6" title="Every bridge">
        <Bridges />
      </Section>

      <NextLinks path="/system" />
    </>
  );
}
