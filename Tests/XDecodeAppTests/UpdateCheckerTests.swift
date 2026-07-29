import Foundation
import Testing
@testable import XDecodeApp

@Suite("Update checker")
struct UpdateCheckerTests {
    private let releaseURL = URL(string: "https://github.com/LineShine/XDecode/releases/tag/v1.2.0")!

    @Test("A newer semantic version is reported as available")
    func newerVersion() throws {
        let release = UpdateRelease(version: "v1.2.0", pageURL: releaseURL)

        #expect(
            try UpdateChecker.availability(currentVersion: "1.1.9", latestRelease: release)
                == .updateAvailable(release)
        )
    }

    @Test("Equivalent and older releases do not offer an update")
    func currentOrOlderVersion() throws {
        let equivalent = UpdateRelease(version: "1.0", pageURL: releaseURL)
        let older = UpdateRelease(version: "v0.9.9", pageURL: releaseURL)

        #expect(
            try UpdateChecker.availability(currentVersion: "1.0.0", latestRelease: equivalent)
                == .upToDate(equivalent)
        )
        #expect(
            try UpdateChecker.availability(currentVersion: "1.0.0", latestRelease: older)
                == .upToDate(older)
        )
    }

    @Test("Malformed versions are rejected")
    func malformedVersion() {
        let release = UpdateRelease(version: "latest", pageURL: releaseURL)

        #expect(throws: UpdateCheckError.invalidVersion("latest")) {
            try UpdateChecker.availability(currentVersion: "1.0.0", latestRelease: release)
        }
    }
}
