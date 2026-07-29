export function Diagram() {
  return (
    <div
      className="diagram"
      role="img"
      aria-label="Layered architecture. The device screen at the top presents an output IOSurface through Metal. Below it, Xios.app is the app iOS sees; it also sends input back down. Under that sit interchangeable display servers: Xios for X11, and on the Wayland side iosc, with Mutter or KWin when a full desktop environment is running. Each has its own client apps. ANGLE feeds the A10 GPU under the Wayland column."
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

      <div className="dg-split">
        <div className="dg-col dg-x11">
          <div className="dg-colhead">X11 track, software</div>
          <div className="dg-layer">
            <div className="dg-t">Xios (X11 server)</div>
            <div className="dg-d">Xvfb-derived, draws into an IOSurface, XTEST input.</div>
          </div>
          <div className="dg-layer">
            <div className="dg-t">X11 apps</div>
            <div className="dg-d">xterm and x11-apps, rendered on the CPU.</div>
          </div>
        </div>

        <div className="dg-col dg-wl">
          <div className="dg-colhead">Wayland track, GPU</div>
          <div className="dg-layer">
            <div className="dg-t">iosc (Wayland compositor)</div>
            <div className="dg-d">Composites clients and routes input through wl_seat.</div>
          </div>
          <div className="dg-layer">
            <div className="dg-t">Mutter or KWin, for a full desktop</div>
            <div className="dg-d">
              Mutter replaces iosc with its own iOS backend; KWin nests inside it.
            </div>
          </div>
          <div className="dg-layer">
            <div className="dg-t">GTK, Qt, and GNOME apps</div>
            <div className="dg-d">Console, Konsole, Dolphin, Calculator. CPU paint or GLES on the GPU.</div>
          </div>
          <div className="dg-layer dg-gpu">
            <div className="dg-t">ANGLE, then Metal, then the A10 GPU</div>
            <div className="dg-d">libEGL and libGLESv2 render straight into IOSurfaces.</div>
          </div>
        </div>
      </div>

      <div className="dg-note">
        No CPU copy from a GTK4 app&apos;s frame to the screen on the Wayland path.
      </div>
    </div>
  );
}
