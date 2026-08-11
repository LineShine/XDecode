import Foundation
import Testing
@testable import XDecodeApp

@Suite("Update checker")
struct UpdateCheckerTests {
    private let downloadURL = URL(string: "https://flatstore.sfhw.cc/api/releases/release-id/download")!

    @Test("The endpoint targets the public XDecode macOS release")
    func endpoint() {
        let components = URLComponents(url: UpdateChecker.releasesEndpoint, resolvingAgainstBaseURL: false)

        #expect(components?.scheme == "https")
        #expect(components?.host == "flatstore.sfhw.cc")
        #expect(components?.path == "/api/apps/5064015e-5fab-4aa6-9943-67678c272378/releases")
        #expect(components?.queryItems?.contains(URLQueryItem(name: "platform", value: "macOS")) == true)
        #expect(components?.queryItems?.contains(URLQueryItem(name: "limit", value: "1")) == true)
    }

    @Test("FlatStore response creates a release and resolves its relative download URL")
    func flatStoreResponse() throws {
        let data = Data(#"""
        {
            "currentRelease": {
                "version": "1.2.0",
                "downloadUrl": "/api/releases/release-id/download",
                "sizeBytes": 1024
            }
        }
        """#.utf8)

        let release = try UpdateChecker.release(
            from: data,
            relativeTo: UpdateChecker.releasesEndpoint
        )

        #expect(
            release == UpdateRelease(
                version: "1.2.0",
                downloadURL: downloadURL,
                sizeBytes: 1024
            )
        )
    }

    @Test("An app without a macOS release is reported as unpublished")
    func noPublishedRelease() {
        let data = Data(#"{"currentRelease":null,"releases":[]}"#.utf8)

        #expect(throws: UpdateCheckError.noPublishedRelease) {
            try UpdateChecker.release(from: data, relativeTo: UpdateChecker.releasesEndpoint)
        }
    }

    @Test("Malformed FlatStore responses are rejected")
    func malformedResponse() {
        let data = Data(#"{"currentRelease":{"version":"1.2.0"}}"#.utf8)

        #expect(throws: UpdateCheckError.invalidResponse) {
            try UpdateChecker.release(from: data, relativeTo: UpdateChecker.releasesEndpoint)
        }
    }

    @Test("A valid DMG is saved without overwriting an existing download")
    func downloadDiskImage() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdatePackageDownloaderTests-\(UUID().uuidString)", isDirectory: true)
        let downloads = base.appendingPathComponent("Downloads", isDirectory: true)
        let temporaryPackage = base.appendingPathComponent("download.tmp")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        try makeDiskImage(at: temporaryPackage, size: 1024)
        let existingPackage = downloads.appendingPathComponent("XDecode-1.2.0.dmg")
        try Data("existing".utf8).write(to: existingPackage)
        let response = HTTPURLResponse(
            url: downloadURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Disposition": "attachment; filename=\"XDecode-1.2.0.dmg\""]
        )!
        let downloader = UpdatePackageDownloader(downloadsDirectory: downloads) { _ in
            (temporaryPackage, response)
        }
        let release = UpdateRelease(version: "1.2.0", downloadURL: downloadURL, sizeBytes: 1024)

        let savedPackage = try await downloader.download(release)

        #expect(savedPackage.lastPathComponent == "XDecode-1.2.0-1.dmg")
        #expect(FileManager.default.fileExists(atPath: savedPackage.path))
        #expect(try Data(contentsOf: existingPackage) == Data("existing".utf8))
    }

    @Test("DMG validation rejects size mismatches")
    func diskImageSizeMismatch() throws {
        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdatePackageSizeTests-\(UUID().uuidString).dmg")
        try makeDiskImage(at: package, size: 1024)
        defer { try? FileManager.default.removeItem(at: package) }

        #expect(throws: UpdateDownloadError.sizeMismatch(expected: 2048, actual: 1024)) {
            try UpdatePackageDownloader.validateDiskImage(at: package, expectedSize: 2048)
        }
    }

    @Test("DMG validation rejects files without a UDIF trailer")
    func invalidDiskImage() throws {
        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdatePackageFormatTests-\(UUID().uuidString).dmg")
        try Data(repeating: 0, count: 1024).write(to: package)
        defer { try? FileManager.default.removeItem(at: package) }

        #expect(throws: UpdateDownloadError.invalidDiskImage) {
            try UpdatePackageDownloader.validateDiskImage(at: package, expectedSize: 1024)
        }
    }

    @Test("A newer semantic version is reported as available")
    func newerVersion() throws {
        let release = UpdateRelease(version: "v1.2.0", downloadURL: downloadURL, sizeBytes: 1024)

        #expect(
            try UpdateChecker.availability(currentVersion: "1.1.9", latestRelease: release)
                == .updateAvailable(release)
        )
    }

    @Test("Equivalent and older releases do not offer an update")
    func currentOrOlderVersion() throws {
        let equivalent = UpdateRelease(version: "1.0", downloadURL: downloadURL, sizeBytes: 1024)
        let older = UpdateRelease(version: "v0.9.9", downloadURL: downloadURL, sizeBytes: 1024)

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
        let release = UpdateRelease(version: "latest", downloadURL: downloadURL, sizeBytes: 1024)

        #expect(throws: UpdateCheckError.invalidVersion("latest")) {
            try UpdateChecker.availability(currentVersion: "1.0.0", latestRelease: release)
        }
    }

    private func makeDiskImage(at url: URL, size: Int) throws {
        var data = Data(repeating: 0, count: size)
        data.replaceSubrange((size - 512)..<(size - 508), with: Data("koly".utf8))
        try data.write(to: url)
    }
}
