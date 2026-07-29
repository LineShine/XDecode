import AppKit
import Testing
@testable import XDecodeApp

@Suite("Application lifecycle")
@MainActor
struct ApplicationLifecycleTests {
    @Test("Closing the last window keeps automatic decoding running")
    func closingLastWindowDoesNotTerminateApplication() {
        let delegate = AppDelegate()

        #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(.shared))
    }
}
