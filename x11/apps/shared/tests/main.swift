import Foundation

private func expect(_ hid: Int, _ keysym: UInt32) {
    precondition(XiosHardwareKeymap.keysym(forHID: hid) == keysym,
                 "HID 0x\(String(hid, radix: 16)) mapping mismatch")
}

expect(0x04, 0x61)       // A -> a (Shift/Caps remain independent)
expect(0x1d, 0x7a)       // Z -> z
expect(0x1e, 0x31)       // 1
expect(0x27, 0x30)       // 0
expect(0x28, 0xff0d)     // Return
expect(0x29, 0xff1b)     // Escape
expect(0x3a, 0xffbe)     // F1
expect(0x45, 0xffc9)     // F12
expect(0x4f, 0xff53)     // Right
expect(0x52, 0xff52)     // Up
expect(0x58, 0xff8d)     // Keypad Enter
expect(0x59, 0xffb1)     // Keypad 1
expect(0x7f, 0x1008ff12) // Audio mute
expect(0xe0, 0xffe3)     // Left Control
expect(0xe3, 0xffeb)     // Left Command -> Super
precondition(XiosHardwareKeymap.keysym(forHID: 0x00) == nil)

print("XiosHardwareKeyboard HID mapping: PASS")
