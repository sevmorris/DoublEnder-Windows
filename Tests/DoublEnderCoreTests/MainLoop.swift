import XCTest
@testable import DoublEnderCore

extension XCTestCase {
    /// Runs main-loop work (`MainQueue`) until `done` or the timeout.
    @discardableResult
    func runMainLoop(until done: () -> Bool = { false }, timeout: Double = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            MainQueue.drain()
            if done() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return false
    }

    func runMainLoop(for seconds: Double) {
        runMainLoop(until: { false }, timeout: seconds)
    }
}
