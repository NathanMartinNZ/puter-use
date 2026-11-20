import CoreGraphics
import XCTest

@testable import PuterUseHelper

/// The keyboard check while typing (`Input.type`'s `stillSafe`): asked before every key going down, Shift,
/// Return and Tab included, and never before one coming up. A failed check stops before the key and lets
/// go of the keys still down. Events go to `Input.sink`, not to an app.
@MainActor final class TypingCheckTests: XCTestCase {
    enum Step: Equatable { case check, down(CGKeyCode), up(CGKeyCode) }

    static func isDown(_ s: Step) -> Bool { if case .down = s { true } else { false } }

    /// Keys down at the end.
    static func held(_ steps: [Step]) -> Set<CGKeyCode> {
        var held = Set<CGKeyCode>()
        for s in steps {
            if case .down(let c) = s { held.insert(c) }
            if case .up(let c) = s { held.remove(c) }
        }
        return held
    }

    /// Types `text` at 280 WPM (the next key often goes down before the last is up). The check passes
    /// except on call `failAt` (1-based); the client hangs up after `hangUpAfter` keys went down.
    func record(_ text: String, failAt: Int? = nil, hangUpAfter: Int? = nil) async -> (ok: Bool, steps: [Step]) {
        if Keys.layout.isEmpty { Keys.prepare() }
        var steps: [Step] = []
        var checks = 0
        let conn = Connection(fd: -1, key: nil)
        Input.sink = { e in
            let code = CGKeyCode(e.getIntegerValueField(.keyboardEventKeycode))
            let down = e.type == .flagsChanged ? e.flags.contains(.maskShift) : e.type == .keyDown
            steps.append(down ? .down(code) : .up(code))
            if let n = hangUpAfter, steps.filter(Self.isDown).count == n { conn.hangUp() }
        }
        defer { Input.sink = nil }
        let ok = await Connection.$current.withValue(conn) {
            await Input.type(text, Route(pid: 424_201, wid: 1, frame: .zero), typist: Typist(wpm: 280), stillSafe: {
                checks += 1
                steps.append(.check)
                return checks != failAt
            })
        }
        return (ok, steps)
    }

    func testCheckedBeforeEveryKeyGoingDownOnly() async {
        let (ok, steps) = await record("Hi, AB!\tok\n")
        XCTAssertTrue(ok)
        let downs = steps.filter(Self.isDown)
        for code: CGKeyCode in [0x38, 0x24, 0x30] {  // Shift, Return, Tab
            XCTAssertTrue(downs.contains(.down(code)), "\(code) went down")
        }
        XCTAssertEqual(steps.filter { $0 == .check }.count, downs.count, "one check per key going down")
        for (i, s) in steps.enumerated() {
            if Self.isDown(s) { XCTAssertEqual(i > 0 ? steps[i - 1] : nil, .check, "step \(i) went down unchecked") }
            if s == .check { XCTAssertTrue(i + 1 < steps.count && Self.isDown(steps[i + 1]), "step \(i): a check before a key-up") }
        }
        XCTAssertEqual(steps.filter { if case .up = $0 { true } else { false } }.count, downs.count)
        XCTAssertTrue(Self.held(steps).isEmpty, "nothing left held")
    }

    /// Wherever it fails (Shift held or not, a key still down from rollover or not), no key goes down after
    /// it and every key that went down comes up.
    func testAFailedCheckStopsBeforeTheKeyAndLetsGo() async {
        // Keys going down: Shift, A, B, c (Shift comes up before it, unchecked), d.
        for failAt in 1...5 {
            let (ok, steps) = await record("ABcd", failAt: failAt)
            XCTAssertFalse(ok)
            XCTAssertEqual(steps.filter { $0 == .check }.count, failAt, "failAt \(failAt)")
            XCTAssertEqual(steps.filter(Self.isDown).count, failAt - 1, "failAt \(failAt): one key per check passed")
            let last = steps.lastIndex(of: .check)!
            XCTAssertFalse(steps[last...].contains(where: Self.isDown), "failAt \(failAt): a key went down after it")
            XCTAssertTrue(Self.held(steps).isEmpty, "failAt \(failAt): left held \(Self.held(steps))")
        }
    }

    /// A client hanging up stops it too, with no more checks or keys going down, and nothing left held.
    func testHangingUpStopsAndLetsGo() async {
        let (ok, steps) = await record("Abcdef", hangUpAfter: 2)  // after Shift and A
        XCTAssertFalse(ok)
        XCTAssertEqual(steps.filter(Self.isDown).count, 2)
        XCTAssertEqual(steps.filter { $0 == .check }.count, 2)
        XCTAssertTrue(Self.held(steps).isEmpty, "left held \(Self.held(steps))")
    }
}
