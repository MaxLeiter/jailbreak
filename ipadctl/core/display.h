// display.h - screen geometry, interface orientation, foreground state.
//
// Coordinate spaces (see NOTES.md for the derivation):
//   panel space: the physical panel in its native orientation (portrait for
//                iPad7,12), origin at the top-left with the home button at the
//                bottom. CARenderServer captures in this space and the
//                digitizer reports in it, normalized to 0..1.
//   view space:  what the user sees, i.e. panel space rotated by the current
//                interface orientation, in points. Screenshots are produced in
//                view space and every input coordinate is taken in view space.
#pragma once

#import <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>

typedef struct {
    int panel_px_w, panel_px_h;    // native pixels, panel orientation
    double scale;                  // pixels per point
    double panel_pt_w, panel_pt_h; // points, panel orientation
    long orientation;              // UIInterfaceOrientation (1..4), 0 = unknown
    int rot_q;                     // clockwise quarter turns panel -> view (0..3)
    double view_pt_w, view_pt_h;   // points, view orientation
} ipc_geometry;

// Fills g. Orientation comes from FrontBoardServices; returns false if it could
// not be read (g is still filled, assuming portrait).
bool ipc_geometry_get(ipc_geometry *g);

// Clockwise quarter turns needed to go from panel space to view space.
int ipc_rot_q_for_orientation(long orientation);
const char *ipc_orientation_name(long orientation);

// View-space point (points) -> panel space normalized to 0..1 (digitizer units).
CGPoint ipc_view_to_panel_unit(const ipc_geometry *g, CGPoint view_pt);

typedef struct {
    char frontmost[256];       // bundle id; "com.apple.springboard" when no app is up
    bool frontmost_ok;         // false if the query itself failed
    int lockstate;             // notify state com.apple.springboard.lockstate (1 = locked), -1 unknown
    int blanked;               // notify state com.apple.springboard.hasBlankedScreen (1 = display off), -1 unknown
} ipc_foreground;

void ipc_foreground_get(ipc_foreground *f);
