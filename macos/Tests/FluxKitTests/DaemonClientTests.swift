#if os(macOS)
import XCTest
@testable import FluxKit

final class DaemonClientTests: XCTestCase {
    func testStateAgainstRunningDaemon() throws {
        let path = DaemonClient.defaultSocketPath()
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("no fluxd socket at \(path)")
        }
        let client = DaemonClient(retryDelay: 0.5)
        let opened = expectation(description: "open")
        client.onOpen = { opened.fulfill() }
        client.start(path: path)
        wait(for: [opened], timeout: 5)

        let answered = expectation(description: "state")
        var state: DaemonState?
        client.call("state") { result in
            if case .success(let value) = result { state = DaemonState.decode(value) }
            answered.fulfill()
        }
        wait(for: [answered], timeout: 5)

        let snapshot = try XCTUnwrap(state, "the daemon did not answer state")
        XCTAssertFalse(snapshot.selfInfo.name.isEmpty, "the daemon reported no name")
        client.stop()
    }
}
#endif
