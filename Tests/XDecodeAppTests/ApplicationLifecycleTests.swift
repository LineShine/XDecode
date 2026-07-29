import AppKit
import Testing
@testable import XDecodeApp

@Suite("Application lifecycle")
@MainActor
struct ApplicationLifecycleTests {
    @Test("A direct launch presents the initial window")
    func directLaunchPresentsInitialWindow() {
        var state = InitialWindowPresentationState()

        #expect(state.resolve() == true)
        #expect(!state.isPending)
    }

    @Test("A cold file-open launch suppresses the initial window")
    func fileOpenLaunchSuppressesInitialWindow() {
        var state = InitialWindowPresentationState()

        let didSuppress = state.receiveOpenURLs()

        #expect(didSuppress)
        #expect(state.resolve() == false)
        #expect(!state.isPending)
    }

    @Test("File-open events do not hide an explicitly presented window")
    func explicitPresentationWinsOverFileOpen() {
        var state = InitialWindowPresentationState()

        state.forcePresentation()
        let didSuppress = state.receiveOpenURLs()

        #expect(!didSuppress)
        #expect(state.resolve() == nil)
    }

    @Test("Closing the last window keeps automatic decoding running")
    func closingLastWindowDoesNotTerminateApplication() {
        let delegate = AppDelegate()

        #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(.shared))
    }
}
