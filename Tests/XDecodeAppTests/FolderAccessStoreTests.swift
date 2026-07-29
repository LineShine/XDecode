import Foundation
import Testing
@testable import XDecodeApp

@Suite("Folder access store", .serialized)
@MainActor
struct FolderAccessStoreTests {
    @Test("Folder authorization persists and covers descendants only")
    func persistsAuthorization() throws {
        let suiteName = "XDecodeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = base.appendingPathComponent("authorized", isDirectory: true)
        let file = root.appendingPathComponent("nested/sample.xlog")
        let sibling = base.appendingPathComponent("authorized-copy/sample.xlog")

        let store = makeStore(defaults: defaults)
        try store.remember(root)

        #expect(store.authorizedDirectory(containing: file) == root)
        #expect(store.authorizedDirectory(containing: sibling) == nil)

        let restoredStore = makeStore(defaults: defaults)
        #expect(restoredStore.authorizedDirectory(containing: file) == root)
    }

    @Test("The narrowest authorized folder is selected")
    func selectsNarrowestFolder() throws {
        let suiteName = "XDecodeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        let file = nested.appendingPathComponent("sample.logan")

        let store = makeStore(defaults: defaults)
        try store.remember(root)
        try store.remember(nested)

        #expect(store.authorizedDirectory(containing: file) == nested)
    }

    @Test("Statically entitled folders authorize descendants without bookmarks")
    func authorizesStaticFolder() throws {
        let suiteName = "XDecodeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let downloads = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = downloads.appendingPathComponent("nested/sample.xlog")
        let store = makeStore(defaults: defaults, staticallyAuthorizedDirectories: [downloads])

        #expect(
            store.authorizedDirectory(containing: file)?.standardizedFileURL.path
                == downloads.standardizedFileURL.path
        )
    }

    private func makeStore(
        defaults: UserDefaults,
        staticallyAuthorizedDirectories: [URL] = []
    ) -> FolderAccessStore {
        FolderAccessStore(
            defaults: defaults,
            staticallyAuthorizedDirectories: staticallyAuthorizedDirectories,
            createBookmark: { Data($0.standardizedFileURL.path.utf8) },
            resolveBookmark: { data in
                guard let path = String(data: data, encoding: .utf8) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                return (URL(fileURLWithPath: path, isDirectory: true), false)
            }
        )
    }
}
