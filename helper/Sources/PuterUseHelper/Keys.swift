import Carbon.HIToolbox
import CoreGraphics

/// Key names (xdotool/X11 keysym style, plus common aliases) → macOS virtual keycodes and modifier flags.
enum Keys {
    static let modifiers: [String: CGEventFlags] = [
        "cmd": .maskCommand, "command": .maskCommand, "meta": .maskCommand, "super": .maskCommand,
        "win": .maskCommand, "windows": .maskCommand,
        "shift": .maskShift,
        "ctrl": .maskControl, "control": .maskControl,
        "alt": .maskAlternate, "option": .maskAlternate, "opt": .maskAlternate,
        "fn": .maskSecondaryFn,
    ]

    /// The modifier keys themselves (left-hand ones), and the order fingers press them in for a shortcut.
    static let modifierCodes: [String: CGKeyCode] = ["cmd": 0x37, "shift": 0x38, "option": 0x3A, "ctrl": 0x3B, "fn": 0x3F]
    static let modifierOrder: [(flag: CGEventFlags, code: CGKeyCode)] = [
        (.maskCommand, 0x37), (.maskControl, 0x3B), (.maskAlternate, 0x3A), (.maskShift, 0x38), (.maskSecondaryFn, 0x3F),
    ]

    static let named: [String: CGKeyCode] = [
        "return": 0x24, "enter": 0x24, "tab": 0x30, "space": 0x31, "backspace": 0x33,
        "delete": 0x75, "del": 0x75, "forwarddelete": 0x75, "escape": 0x35, "esc": 0x35,
        "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
        "home": 0x73, "end": 0x77, "pageup": 0x74, "pagedown": 0x79, "prior": 0x74, "next": 0x79,
        "help": 0x72, "insert": 0x72, "capslock": 0x39, "kpenter": 0x4C,
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61, "f7": 0x62, "f8": 0x64,
        "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F, "f13": 0x69, "f14": 0x6B, "f15": 0x71,
        "f16": 0x6A, "f17": 0x40, "f18": 0x4F, "f19": 0x50, "f20": 0x5A,
    ]

    /// X11 keysym names for punctuation → the character they produce.
    static let symbols: [String: String] = [
        "period": ".", "comma": ",", "slash": "/", "backslash": "\\", "semicolon": ";", "apostrophe": "'",
        "quote": "'", "grave": "`", "backquote": "`", "bracketleft": "[", "bracketright": "]", "minus": "-",
        "equal": "=", "equals": "=", "plus": "+", "greater": ">", "less": "<", "question": "?", "exclam": "!",
        "at": "@", "numbersign": "#", "dollar": "$", "percent": "%", "asciicircum": "^", "ampersand": "&",
        "asterisk": "*", "parenleft": "(", "parenright": ")", "underscore": "_", "colon": ":",
        "quotedbl": "\"", "bar": "|", "braceleft": "{", "braceright": "}", "asciitilde": "~",
    ]

    /// Character → (keycode, needs shift) for the current keyboard layout. Built on the main thread.
    nonisolated(unsafe) static var layout: [String: (CGKeyCode, Bool)] = [:]

    static func prepare() {
        var map: [String: (CGKeyCode, Bool)] = [:]
        if let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
           let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData)
        {
            let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
            data.withUnsafeBytes { raw in
                guard let layoutPtr = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
                for shift in [false, true] {
                    for kc in 0..<128 where !(0x41...0x5C).contains(kc) {  // skip the keypad
                        var dead: UInt32 = 0
                        var len = 0
                        var chars = [UniChar](repeating: 0, count: 4)
                        let mods: UInt32 = shift ? UInt32((shiftKey >> 8) & 0xFF) : 0
                        let status = UCKeyTranslate(
                            layoutPtr, UInt16(kc), UInt16(kUCKeyActionDown), mods, UInt32(LMGetKbdType()),
                            OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, 4, &len, &chars)
                        if status == noErr, len > 0 {
                            let s = String(utf16CodeUnits: chars, count: len)
                            if map[s] == nil { map[s] = (CGKeyCode(kc), shift) }
                        }
                    }
                }
            }
        }
        if map["a"] == nil {  // US ANSI fallback
            let us = "asdfhgzxcv\u{0}bqweryt123465=97-80]ou[ip\u{0}lj'k;\\,/nm.\u{0}\u{0}`"
            for (i, ch) in us.enumerated() where ch != "\u{0}" { map[String(ch)] = (CGKeyCode(i), false) }
        }
        layout = map
    }

    /// For a character the layout has no key for (é, ñ, €): the key of its base letter if it has one, so
    /// apps that look at key codes rather than text see something close. (The text itself is always sent.)
    static func baseKey(_ s: String) -> CGKeyCode? {
        guard let first = s.decomposedStringWithCanonicalMapping.unicodeScalars.first, first.isASCII else { return nil }
        return layout[String(first).lowercased()]?.0
    }

    static func normalize(_ name: String) -> String {
        var n = name.lowercased().replacingOccurrences(of: " ", with: "")
        for suffix in ["_l", "_r"] where n.count > 2 && n.hasSuffix(suffix) { n.removeLast(2) }
        n = n.replacingOccurrences(of: "_", with: "")
        if n.hasPrefix("arrow") { n.removeFirst(5) }
        return n
    }

    /// Parse "cmd+shift+t" / ["cmd","shift","t"] / "Control_L+a" → (keycode, flags).
    static func parseCombo(_ keys: [String]) throws -> (CGKeyCode, CGEventFlags) {
        var flags: CGEventFlags = []
        var main: CGKeyCode?
        var mainShift = false
        for raw in keys {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let n = normalize(trimmed)
            if let f = modifiers[n] {
                if main == nil && keys.count == 1 {
                    // A lone modifier press, e.g. "shift": send its own keycode.
                    let code: CGKeyCode = ["shift": 0x38, "ctrl": 0x3B, "control": 0x3B, "alt": 0x3A, "option": 0x3A,
                                           "opt": 0x3A, "fn": 0x3F][n] ?? 0x37
                    return (code, f)
                }
                flags.insert(f)
            } else if let code = named[n] {
                main = code
            } else if let ch = symbols[n] ?? (trimmed.count == 1 ? trimmed : nil) {
                let lookup = ch.count == 1 && ch.first!.isLetter ? ch.lowercased() : ch
                guard let (code, shift) = layout[lookup] else { throw HelperError("no key for \(raw)") }
                main = code
                mainShift = shift || (ch.first!.isUppercase && keys.count == 1)
            } else if n.hasPrefix("kp"), let d = Int(n.dropFirst(2)), (0...9).contains(d) {
                main = [0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5B, 0x5C][d]
            } else {
                throw HelperError("unknown key \"\(raw)\"")
            }
        }
        guard let code = main else { throw HelperError("no non-modifier key in \(keys)") }
        if mainShift { flags.insert(.maskShift) }
        return (code, flags)
    }

    /// Keys pressed one after another: "Tab Tab Return", "cmd+a BackSpace", ["cmd+a", "BackSpace"] or
    /// ["Tab", "Tab"]. A single combo, "cmd+t" or ["cmd", "t"] (one key plus modifiers), is a sequence of one.
    static func sequence(_ value: Any?) -> [[String]] {
        if let arr = value as? [String] {
            let parts = arr.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let mains = parts.filter { modifiers[normalize($0)] == nil }
            let combos = parts.contains { ($0.contains("+") && $0.count > 1) || $0.contains(" ") }
            if parts.count > 1, combos || mains.count > 1 { return parts.flatMap { sequence($0) } }
            return parts.isEmpty ? [] : [splitCombo(parts)]
        }
        guard var s = (value as? String)?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return [] }
        // "ctrl + c" is one combo; "+" alone (or "cmd++") is the plus key.
        s = s.replacingOccurrences(of: #"(?<=\S)\s*\+\s*(?=\S)"#, with: "+", options: .regularExpression)
        return s.split(whereSeparator: \.isWhitespace).map { splitCombo(String($0)) }
    }

    static func splitCombo(_ value: Any?) -> [String] {
        if let arr = value as? [String] { return arr.count == 1 ? splitCombo(arr[0]) : arr }
        guard let s = value as? String else { return [] }
        if s == "+" { return ["+"] }
        if s.hasSuffix("++") { return s.dropLast(2).split(separator: "+").map(String.init) + ["+"] }
        return s.split(separator: "+").map(String.init)
    }
}
