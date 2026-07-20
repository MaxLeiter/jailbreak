/// Pure USB-HID to X-keysym mapping, kept UI-framework-free so it can be unit
/// tested on the host as well as shared by both iPad presentation apps.
enum XiosHardwareKeymap {
    static func keysym(forHID hid: Int) -> UInt32? {
        if (0x04...0x1d).contains(hid) { return UInt32(0x61 + hid - 0x04) }
        if (0x1e...0x26).contains(hid) { return UInt32(0x31 + hid - 0x1e) }
        if hid == 0x27 { return 0x30 }
        if (0x3a...0x45).contains(hid) { return UInt32(0xffbe + hid - 0x3a) }
        if (0x68...0x73).contains(hid) { return UInt32(0xffca + hid - 0x68) }
        if (0x59...0x61).contains(hid) { return UInt32(0xffb1 + hid - 0x59) }

        switch hid {
        case 0x28: return 0xff0d                 // Return
        case 0x29: return 0xff1b                 // Escape
        case 0x2a: return 0xff08                 // BackSpace
        case 0x2b: return 0xff09                 // Tab
        case 0x2c: return 0x20
        case 0x2d: return 0x2d
        case 0x2e: return 0x3d
        case 0x2f: return 0x5b
        case 0x30: return 0x5d
        case 0x31, 0x64: return 0x5c
        case 0x32: return 0x23
        case 0x33: return 0x3b
        case 0x34: return 0x27
        case 0x35: return 0x60
        case 0x36: return 0x2c
        case 0x37: return 0x2e
        case 0x38: return 0x2f
        case 0x39: return 0xffe5                 // Caps_Lock
        case 0x46: return 0xff61                 // Print
        case 0x47: return 0xff14                 // Scroll_Lock
        case 0x48: return 0xff13                 // Pause
        case 0x49: return 0xff63                 // Insert
        case 0x4a: return 0xff50                 // Home
        case 0x4b: return 0xff55                 // Page_Up
        case 0x4c: return 0xffff                 // Delete
        case 0x4d: return 0xff57                 // End
        case 0x4e: return 0xff56                 // Page_Down
        case 0x4f: return 0xff53                 // Right
        case 0x50: return 0xff51                 // Left
        case 0x51: return 0xff54                 // Down
        case 0x52: return 0xff52                 // Up
        case 0x53: return 0xff7f                 // Num_Lock
        case 0x54: return 0xffaf                 // KP_Divide
        case 0x55: return 0xffaa                 // KP_Multiply
        case 0x56: return 0xffad                 // KP_Subtract
        case 0x57: return 0xffab                 // KP_Add
        case 0x58: return 0xff8d                 // KP_Enter
        case 0x62: return 0xffb0                 // KP_0
        case 0x63: return 0xffae                 // KP_Decimal
        case 0x65: return 0xff67                 // Menu
        case 0x66: return 0x1008ff2a             // XF86PowerOff
        case 0x67: return 0xffbd                 // KP_Equal
        case 0x7f: return 0x1008ff12             // XF86AudioMute
        case 0x80: return 0x1008ff13             // XF86AudioRaiseVolume
        case 0x81: return 0x1008ff11             // XF86AudioLowerVolume
        case 0x90: return 0xff31                 // Hangul
        case 0x91: return 0xff34                 // Hangul_Hanja
        case 0x92: return 0xff26                 // Katakana
        case 0x93: return 0xff25                 // Hiragana
        case 0x94: return 0xff2a                 // Zenkaku_Hankaku
        case 0xe0: return 0xffe3                 // Control_L
        case 0xe1: return 0xffe1                 // Shift_L
        case 0xe2: return 0xffe9                 // Alt_L
        case 0xe3: return 0xffeb                 // Super_L / Command
        case 0xe4: return 0xffe4                 // Control_R
        case 0xe5: return 0xffe2                 // Shift_R
        case 0xe6: return 0xffea                 // Alt_R
        case 0xe7: return 0xffec                 // Super_R / Command
        default: return nil
        }
    }
}
