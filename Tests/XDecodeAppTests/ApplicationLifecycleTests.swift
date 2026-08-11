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

    @Test("Completing launch does not create the main window scene")
    func launchCompletionDoesNotCreateWindowScene() {
        var openWindowCount = 0
        let coordinator = MainWindowVisibilityCoordinator { _ in }
        coordinator.setOpenWindowAction { openWindowCount += 1 }

        coordinator.completeLaunch(shouldPresent: true)

        #expect(openWindowCount == 0)
    }

    @Test("Explicit presentation opens the main window scene before it is attached")
    func explicitPresentationOpensUnattachedWindowScene() {
        var openWindowCount = 0
        var presentedWindowCount = 0
        let coordinator = MainWindowVisibilityCoordinator { _ in
            presentedWindowCount += 1
        }
        coordinator.setOpenWindowAction { openWindowCount += 1 }

        coordinator.present()

        #expect(openWindowCount == 1)
        #expect(presentedWindowCount == 0)
    }

    @Test("Registering the scene opener fulfills an earlier presentation request")
    func delayedSceneOpenerRegistrationFulfillsPresentationRequest() {
        var openWindowCount = 0
        let coordinator = MainWindowVisibilityCoordinator { _ in }

        coordinator.present()
        coordinator.setOpenWindowAction { openWindowCount += 1 }
        coordinator.setOpenWindowAction { openWindowCount += 1 }

        #expect(openWindowCount == 1)
    }

    @Test("A delayed main window attachment fulfills explicit presentation")
    func delayedAttachmentFulfillsExplicitPresentation() {
        var presentedWindows: [NSWindow] = []
        let coordinator = MainWindowVisibilityCoordinator { window in
            presentedWindows.append(window)
        }
        let window = makeWindow()

        coordinator.present()
        coordinator.attach(window)

        #expect(presentedWindows.count == 1)
        #expect(presentedWindows.first === window)
        #expect(window.alphaValue == 1)
        #expect(!window.isReleasedWhenClosed)
    }

    @Test("Repeated presentation reuses the attached main window")
    func repeatedPresentationReusesAttachedWindow() {
        var openWindowCount = 0
        var presentedWindows: [NSWindow] = []
        let coordinator = MainWindowVisibilityCoordinator { window in
            presentedWindows.append(window)
        }
        coordinator.setOpenWindowAction { openWindowCount += 1 }
        let window = makeWindow()
        coordinator.attach(window)

        coordinator.present()
        window.close()
        coordinator.present()

        #expect(openWindowCount == 2)
        #expect(presentedWindows.count == 2)
        #expect(presentedWindows.allSatisfy { $0 === window })
    }

    @Test("Closing the last window keeps automatic decoding running")
    func closingLastWindowDoesNotTerminateApplication() {
        let delegate = AppDelegate()

        #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(.shared))
    }

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
    }
}
