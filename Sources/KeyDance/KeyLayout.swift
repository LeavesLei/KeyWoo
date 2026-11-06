import Foundation

/// Physical ANSI key positions. Labels intentionally never depend on the text being entered.
struct KeyDescriptor: Identifiable, Hashable {
    let code: UInt16
    let label: String
    let width: Double
    var id: UInt16 { code }

    init(_ code: UInt16, _ label: String, _ width: Double = 1) {
        self.code = code
        self.label = label
        self.width = width
    }
}

enum KeyLayout {
    static let rows: [[KeyDescriptor]] = [
        [KeyDescriptor(50, "`"), KeyDescriptor(18, "1"), KeyDescriptor(19, "2"),
         KeyDescriptor(20, "3"), KeyDescriptor(21, "4"), KeyDescriptor(23, "5"),
         KeyDescriptor(22, "6"), KeyDescriptor(26, "7"), KeyDescriptor(28, "8"),
         KeyDescriptor(25, "9"), KeyDescriptor(29, "0"), KeyDescriptor(27, "−"),
         KeyDescriptor(24, "="), KeyDescriptor(51, "delete", 1.5)],
        [KeyDescriptor(48, "tab", 1.5), KeyDescriptor(12, "Q"), KeyDescriptor(13, "W"),
         KeyDescriptor(14, "E"), KeyDescriptor(15, "R"), KeyDescriptor(17, "T"),
         KeyDescriptor(16, "Y"), KeyDescriptor(32, "U"), KeyDescriptor(34, "I"),
         KeyDescriptor(31, "O"), KeyDescriptor(35, "P"), KeyDescriptor(33, "["),
         KeyDescriptor(30, "]"), KeyDescriptor(42, "\\")],
        [KeyDescriptor(57, "caps", 1.75), KeyDescriptor(0, "A"), KeyDescriptor(1, "S"),
         KeyDescriptor(2, "D"), KeyDescriptor(3, "F"), KeyDescriptor(5, "G"),
         KeyDescriptor(4, "H"), KeyDescriptor(38, "J"), KeyDescriptor(40, "K"),
         KeyDescriptor(37, "L"), KeyDescriptor(41, ";"), KeyDescriptor(39, "′"),
         KeyDescriptor(36, "return", 1.75)],
        [KeyDescriptor(56, "shift", 2.25), KeyDescriptor(6, "Z"), KeyDescriptor(7, "X"),
         KeyDescriptor(8, "C"), KeyDescriptor(9, "V"), KeyDescriptor(11, "B"),
         KeyDescriptor(45, "N"), KeyDescriptor(46, "M"), KeyDescriptor(43, ","),
         KeyDescriptor(47, "."), KeyDescriptor(44, "/"), KeyDescriptor(60, "shift", 2.25)],
        [KeyDescriptor(63, "fn"), KeyDescriptor(59, "⌃"), KeyDescriptor(58, "⌥"),
         KeyDescriptor(55, "⌘", 1.25), KeyDescriptor(49, "space", 5),
         KeyDescriptor(54, "⌘", 1.25), KeyDescriptor(61, "⌥"),
         KeyDescriptor(123, "←"), KeyDescriptor(126, "↑", 0.67),
         KeyDescriptor(125, "↓", 0.66), KeyDescriptor(124, "→", 0.67)]
    ]

    static let extra: [KeyDescriptor] = [
        KeyDescriptor(53, "esc"), KeyDescriptor(122, "F1"), KeyDescriptor(120, "F2"),
        KeyDescriptor(99, "F3"), KeyDescriptor(118, "F4"), KeyDescriptor(96, "F5"),
        KeyDescriptor(97, "F6"), KeyDescriptor(98, "F7"), KeyDescriptor(100, "F8"),
        KeyDescriptor(101, "F9"), KeyDescriptor(109, "F10"), KeyDescriptor(103, "F11"),
        KeyDescriptor(111, "F12"), KeyDescriptor(62, "right control"),
        KeyDescriptor(114, "help"), KeyDescriptor(115, "home"), KeyDescriptor(119, "end"),
        KeyDescriptor(116, "page up"), KeyDescriptor(121, "page down"),
        KeyDescriptor(117, "forward delete"), KeyDescriptor(71, "clear"),
        KeyDescriptor(65, "keypad ."), KeyDescriptor(67, "keypad ×"),
        KeyDescriptor(69, "keypad +"), KeyDescriptor(75, "keypad ÷"),
        KeyDescriptor(76, "keypad enter"), KeyDescriptor(78, "keypad −"),
        KeyDescriptor(81, "keypad ="), KeyDescriptor(82, "keypad 0"),
        KeyDescriptor(83, "keypad 1"), KeyDescriptor(84, "keypad 2"),
        KeyDescriptor(85, "keypad 3"), KeyDescriptor(86, "keypad 4"),
        KeyDescriptor(87, "keypad 5"), KeyDescriptor(88, "keypad 6"),
        KeyDescriptor(89, "keypad 7"), KeyDescriptor(91, "keypad 8"),
        KeyDescriptor(92, "keypad 9"), KeyDescriptor(10, "ISO §"),
        KeyDescriptor(93, "JIS ¥"), KeyDescriptor(94, "JIS _"),
        KeyDescriptor(95, "keypad ,"), KeyDescriptor(102, "英数"), KeyDescriptor(104, "かな")
    ]

    static let all: [KeyDescriptor] = rows.flatMap { $0 } + extra
    private static let labels = Dictionary(uniqueKeysWithValues: all.map { ($0.code, $0.label) })

    static func label(for code: UInt16) -> String {
        if let label = labels[code] { return label }
        if code >= 0x100, let action = RemapMediaAction.forNativeKeyType(code - 0x100) {
            return L(action.title)
        }
        return "key \(code)"
    }
}
