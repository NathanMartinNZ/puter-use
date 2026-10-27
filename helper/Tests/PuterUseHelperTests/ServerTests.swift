import XCTest

@testable import PuterUseHelper

final class ServerTests: XCTestCase {
    /// A reply written to a client that has hung up fails (EPIPE) instead of ending the helper with SIGPIPE.
    func testAClientThatHungUpDoesNotEndTheHelper() throws {
        signal(SIGPIPE, SIG_DFL)  // as a process starts out
        let path = NSTemporaryDirectory() + "pu-test-\(getpid()).sock"
        defer { unlink(path) }
        try Server(path: path).start()

        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[0]) }
        close(fds[1])  // the client hangs up before its reply
        let reply = Array("{\"id\":1,\"ok\":true}\n".utf8)
        XCTAssertEqual(write(fds[0], reply, reply.count), -1)
        XCTAssertEqual(errno, EPIPE)
    }
}
