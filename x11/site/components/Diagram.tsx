export function Diagram() {
  return (
    <div
      className="diagram"
      role="img"
      aria-label="Layered architecture. The device screen at the top presents an output IOSurface through Metal. Below it, Xios.app is the app iOS sees; it also sends input back down. Under that sits one interchangeable Wayland compositor: iosc, or Mutter or KWin when a full desktop environment is running. Its clients split two ways: Wayland apps directly, and X11 apps through Xwayland. ANGLE feeds the A10 GPU beneath both."
    >
      <div className="dg-layer dg-screen">
        <div className="dg-t">Device screen, drawn by Metal</div>
        <div className="dg-d">The A10 scans out one Metal texture.</div>
      </div>

      <div className="dg-conn">
        <span className="arrow">↑</span> presents the output IOSurface
      </div>

      <div className="dg-layer dg-app">
        <div className="dg-t">Xios.app</div>
        <div className="dg-d">
          The app iOS sees. It adopts an IOSurface over a mach port and draws it
          as a Metal texture, then forwards touch, Pencil, and physical keyboard
          and pointer input back to the running server.
        </div>
      </div>

      <div className="dg-conn">
        <span className="arrow">↕</span> output surface up, input down, keyboard
        and rotation hints back up
      </div>

      <div className="dg-layer dg-wl">
        <div className="dg-t">One Wayland compositor</div>
        <div className="dg-d">
          iosc composites clients and routes input through wl_seat. For a full
          desktop, Mutter replaces it with its own iOS backend, or KWin nests
          inside it.
        </div>
      </div>

      <div className="dg-conn">
        <span className="arrow">↑</span> clients hand over IOSurface buffers
      </div>

      <div className="dg-split">
        <div className="dg-col dg-wl">
          <div className="dg-colhead">Wayland clients</div>
          <div className="dg-layer">
            <div className="dg-t">GTK, Qt, and GNOME apps</div>
            <div className="dg-d">Console, Konsole, Dolphin, Calculator. CPU paint or GLES on the GPU.</div>
          </div>
        </div>

        <div className="dg-col dg-x11">
          <div className="dg-colhead">X11 clients</div>
          <div className="dg-layer">
            <div className="dg-t">Xwayland, on glamor</div>
            <div className="dg-d">
              A Wayland client itself. Renders X pixmaps through ANGLE, so xterm
              and x11-apps reach the GPU too.
            </div>
          </div>
        </div>
      </div>

      <div className="dg-layer dg-gpu" style={{ marginTop: 14 }}>
        <div className="dg-t">ANGLE, then Metal, then the A10 GPU</div>
        <div className="dg-d">libEGL and libGLESv2 render straight into IOSurfaces.</div>
      </div>

      <div className="dg-note">
        No CPU copy from a GTK4 app&apos;s frame to the screen, and no software
        synchronization fallback: the compositor waits on the producer&apos;s GPU
        fence.
      </div>
    </div>
  );
}
