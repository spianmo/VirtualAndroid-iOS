import Foundation

/// USB HID keyboard usages (UIKey.keyCode / UIKeyboardHIDUsage) -> Linux
/// input keycodes, following the kernel's hid_keyboard[] table
/// (drivers/hid/hid-input.c). Android maps these with Generic.kl.
enum LinuxKeymap {
    // Linux keycodes used by the on-screen controls.
    static let back: UInt32 = 158          // KEY_BACK
    static let home: UInt32 = 172          // KEY_HOMEPAGE
    static let appSelect: UInt32 = 580     // KEY_APPSELECT (recents)
    static let power: UInt32 = 116         // KEY_POWER
    static let volumeUp: UInt32 = 115      // KEY_VOLUMEUP
    static let volumeDown: UInt32 = 114    // KEY_VOLUMEDOWN
    static let menu: UInt32 = 139          // KEY_MENU

    private static let table: [UInt8] = [
          0,  0,  0,  0, 30, 48, 46, 32, 18, 33, 34, 35, 23, 36, 37, 38,   // 0x00
         50, 49, 24, 25, 16, 19, 31, 20, 22, 47, 17, 45, 21, 44,  2,  3,   // 0x10
          4,  5,  6,  7,  8,  9, 10, 11, 28,  1, 14, 15, 57, 12, 13, 26,   // 0x20
         27, 43, 43, 39, 40, 41, 51, 52, 53, 58, 59, 60, 61, 62, 63, 64,   // 0x30
         65, 66, 67, 68, 87, 88, 99, 70,119,110,102,104,111,107,109,106,   // 0x40
        105,108,103, 69, 98, 55, 74, 78, 96, 79, 80, 81, 75, 76, 77, 71,   // 0x50
         72, 73, 82, 83, 86,127,116,117,183,184,185,186,187,188,189,190,   // 0x60
        191,192,193,194,134,138,130,132,128,129,131,137,133,135,136,113,   // 0x70
        115,114,  0,  0,  0,121,  0, 89, 93,124, 92, 94, 95,  0,  0,  0,   // 0x80
        122,123, 90, 91, 85,  0,  0,  0,  0,  0,  0,  0,111,  0,  0,  0,   // 0x90
    ]

    static func keycode(forHIDUsage usage: Int) -> UInt32? {
        switch usage {
        case 0x04..<table.count:
            let code = table[usage]
            return code == 0 ? nil : UInt32(code)
        case 0xE0: return 29    // KEY_LEFTCTRL
        case 0xE1: return 42    // KEY_LEFTSHIFT
        case 0xE2: return 56    // KEY_LEFTALT
        case 0xE3: return 125   // KEY_LEFTMETA
        case 0xE4: return 97    // KEY_RIGHTCTRL
        case 0xE5: return 54    // KEY_RIGHTSHIFT
        case 0xE6: return 100   // KEY_RIGHTALT
        case 0xE7: return 126   // KEY_RIGHTMETA
        default: return nil
        }
    }

    static func name(_ code: UInt32) -> String {
        switch code {
        case back: return "BACK"
        case home: return "HOME"
        case appSelect: return "APPSELECT"
        case power: return "POWER"
        case volumeUp: return "VOL+"
        case volumeDown: return "VOL-"
        case menu: return "MENU"
        case 1: return "ESC"
        case 28: return "ENTER"
        case 14: return "BKSP"
        case 57: return "SPACE"
        case 103: return "UP"
        case 108: return "DOWN"
        case 105: return "LEFT"
        case 106: return "RIGHT"
        default:
            let letters: [UInt32: String] = [30: "A", 48: "B", 46: "C", 32: "D", 18: "E", 33: "F", 34: "G", 35: "H",
                                             23: "I", 36: "J", 37: "K", 38: "L", 50: "M", 49: "N", 24: "O", 25: "P",
                                             16: "Q", 19: "R", 31: "S", 20: "T", 22: "U", 47: "V", 17: "W", 45: "X",
                                             21: "Y", 44: "Z"]
            return letters[code] ?? "KEY_\(code)"
        }
    }
}
