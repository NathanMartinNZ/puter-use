import Foundation

/// Human timing for keys and buttons: a fast, practised typist's rhythm rather than a metronome.
///
/// Keystroke studies find inter-key intervals are skewed (roughly log-normal) and depend on the pair of
/// keys: hands alternating is quick, the same finger twice is slow, common pairs like "th" are quick,
/// reaching for digits, symbols or Shift costs time, and people pause after punctuation, at line ends
/// and now and then before a word. Keys are held for a varying time, and at speed the next key often
/// goes down before the last comes up (rollover). `wpm` sets the pace (a word is 5 characters);
/// 0 means as fast as possible.
struct Typist {
    var wpm: Double

    var instant: Bool { wpm <= 0 }

    /// Mean time between key-downs at this pace. The pair factors below average about 0.92 on English,
    /// which the 1.08 offsets (simulated: plain text comes out at `wpm`, prose with its pauses ~5% under).
    var base: Double { 1.08 * 60 / (max(wpm, 1) * 5) }

    /// A random factor with median 1 and spread `sigma` (log-normal), scaled to mean 1.
    static func jitter(_ sigma: Double) -> Double {
        let u1 = Double.random(in: Double.ulpOfOne..<1), u2 = Double.random(in: 0..<1)
        let z = (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
        return exp(sigma * z - sigma * sigma / 2)
    }

    /// QWERTY finger per key: 0-3 left pinky to index, 4-7 right index to pinky.
    static let fingers: [Character: Int] = {
        var m: [Character: Int] = [:]
        let rows = ["`1qaz": 0, "2wsx": 1, "3edc": 2, "45rtfgvb": 3, "67yuhjnm": 4, "8ik,": 5, "9ol.": 6,
                    "0-=p[]\\;'/": 7]
        for (keys, f) in rows { for k in keys { m[k] = f } }
        return m
    }()

    /// Shifted symbols → the key they're on.
    static let unshifted: [Character: Character] = [
        "~": "`", "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9",
        ")": "0", "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".",
        "?": "/",
    ]

    static let quickPairs: Set<String> = [
        "th", "he", "in", "er", "an", "re", "on", "at", "en", "nd", "ti", "es", "or", "te", "of", "ed", "is", "it",
        "al", "ar", "st", "to", "nt", "ng", "se", "ha", "as", "ou", "io", "le", "ve", "co", "me", "de", "hi", "ri",
        "ro", "ic", "ne", "ea", "ra", "ce", "ll", "ee", "ss", "oo",
    ]

    static func key(_ c: Character) -> Character? {
        let l = Character(c.lowercased())
        return fingers[l] != nil ? l : unshifted[c]
    }

    /// Seconds from the key-down for `prev` to the key-down for `ch`.
    func interval(_ prev: Character?, _ ch: Character, shift: Bool, prevShift: Bool) -> Double {
        if instant { return 0.004 }
        var t = base
        if let p = prev, let a = Self.key(p), let b = Self.key(ch), let fa = Self.fingers[a], let fb = Self.fingers[b] {
            if a == b { t *= 0.9 }  // the same key again
            else if (fa < 4) != (fb < 4) { t *= 0.8 }  // hands alternate
            else if fa == fb { t *= 1.35 }  // the same finger has to move
            if Self.quickPairs.contains(String([a, b])) { t *= 0.85 }
        }
        if ch == " " { t *= 0.9 }  // thumb, always ready
        if ch.isNumber || ch.isPunctuation || ch.isSymbol { t *= 1.2 }  // a longer reach
        if shift && !prevShift { t += 0.35 * base }  // reach for Shift first
        if let p = prev {
            if ".!?".contains(p) { t += Double.random(in: 0.12...0.35) }  // end of a sentence
            else if ",;:".contains(p) { t += Double.random(in: 0.04...0.15) }
            else if p == "\n" { t += Double.random(in: 0.15...0.45) }
            else if p == " " {
                t *= 1.1  // starting a word
                if Double.random(in: 0..<1) < 0.03 { t += Double.random(in: 0.2...0.6) }  // a moment's thought
            }
        }
        if ch == "\n" { t += Double.random(in: 0.06...0.2) }
        return max(0.022, t * Self.jitter(0.3))
    }

    /// How long a key stays down.
    func dwell() -> Double {
        if instant { return 0.002 }
        let slower = (140 / max(wpm, 20)).squareRoot()  // slower typists hold keys longer
        return min(0.18, max(0.035, 0.078 * slower * Self.jitter(0.25)))
    }

    /// Between pressing a modifier (Shift, Command, …) and the next key going down.
    func modifierLead() -> Double { instant ? 0.002 : min(0.12, max(0.02, 0.045 * Self.jitter(0.35))) }

    /// Between the last key coming up and its modifier being released.
    func modifierTrail() -> Double { instant ? 0.002 : min(0.08, max(0.008, 0.025 * Self.jitter(0.4))) }

    /// Between keys of a sequence like "Tab Tab Down": navigation, not typing, so a little slower.
    func between() -> Double { instant ? 0.004 : max(0.05, 1.4 * base * Self.jitter(0.3)) }

    /// How long a mouse button is held for a click, and the gap between the clicks of a double-click.
    /// Even at full speed these stay long enough for text fields to count a triple-click.
    func clickHold() -> Double { instant ? 0.03 : min(0.14, max(0.045, 0.075 * Self.jitter(0.25))) }
    func clickGap() -> Double { instant ? 0.07 : min(0.2, max(0.07, 0.11 * Self.jitter(0.25))) }

    /// The beat between the pointer arriving and the button going down (eyes confirming the target).
    func aim() -> Double { instant ? 0 : min(0.22, max(0.04, 0.085 * Self.jitter(0.4))) }
}
