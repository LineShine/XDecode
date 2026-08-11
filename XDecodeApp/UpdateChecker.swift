import Foundation

struct UpdateRelease: Equatable, Sendable {
    let version: String
    let downloadURL: URL
    let sizeBytes: Int64
}

enum UpdateAvailability: Equatable, Sendable {
    case upToDate(UpdateRelease)
    case updateAvailable(UpdateRelease)
}

enum UpdateCheckError: LocalizedError, Equatable, Sendable {
    case noPublishedRelease
    case invalidResponse
    case requestFailed(statusCode: Int)
    case invalidVersion(String)

    var errorDescription: String? {
        switch self {
        case .noPublishedRelease:
            "暂未找到可用的发布版本。"
        case .invalidResponse:
            "更新服务返回了无法识别的数据。"
        case let .requestFailed(statusCode):
            "更新服务暂时不可用（HTTP \(statusCode)）。"
        case let .invalidVersion(version):
            "无法识别版本号“\(version)”。"
        }
    }
}

enum UpdateDownloadError: LocalizedError, Equatable, Sendable {
    case invalidPackageSize(Int64)
    case invalidResponse
    case requestFailed(statusCode: Int)
    case sizeMismatch(expected: Int64, actual: Int64)
    case invalidDiskImage
    case downloadsDirectoryUnavailable
    case cannotSavePackage
    case cannotOpenInstaller

    var errorDescription: String? {
        switch self {
        case let .invalidPackageSize(size):
            "安装包声明的大小无效（\(size) 字节）。"
        case .invalidResponse:
            "下载服务返回了无法识别的响应。"
        case let .requestFailed(statusCode):
            "安装包下载失败（HTTP \(statusCode)）。"
        case let .sizeMismatch(expected, actual):
            "安装包大小校验失败（应为 \(expected) 字节，实际为 \(actual) 字节）。"
        case .invalidDiskImage:
            "下载的文件不是有效的 DMG 安装包。"
        case .downloadsDirectoryUnavailable:
            "无法访问下载文件夹。"
        case .cannotSavePackage:
            "无法将安装包保存到下载文件夹。"
        case .cannotOpenInstaller:
            "安装包已下载，但系统无法打开安装界面。"
        }
    }
}

struct UpdateChecker: Sendable {
    static let releasesEndpoint = URL(
        string: "https://flatstore.sfhw.cc/api/apps/5064015e-5fab-4aa6-9943-67678c272378/releases?platform=macOS&limit=1"
    )!

    private let endpoint: URL

    init(endpoint: URL = UpdateChecker.releasesEndpoint) {
        self.endpoint = endpoint
    }

    func check(currentVersion: String) async throws -> UpdateAvailability {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("XDecode/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw UpdateCheckError.invalidResponse
        }
        if response.statusCode == 404 {
            throw UpdateCheckError.noPublishedRelease
        }
        guard (200..<300).contains(response.statusCode) else {
            throw UpdateCheckError.requestFailed(statusCode: response.statusCode)
        }

        let release = try Self.release(from: data, relativeTo: endpoint)
        return try Self.availability(currentVersion: currentVersion, latestRelease: release)
    }

    static func release(from data: Data, relativeTo endpoint: URL) throws -> UpdateRelease {
        let payload: FlatStoreReleasesResponse
        do {
            payload = try JSONDecoder().decode(FlatStoreReleasesResponse.self, from: data)
        } catch {
            throw UpdateCheckError.invalidResponse
        }
        guard let currentRelease = payload.currentRelease else {
            throw UpdateCheckError.noPublishedRelease
        }
        guard let downloadURL = URL(string: currentRelease.downloadURL, relativeTo: endpoint)?.absoluteURL,
              let scheme = downloadURL.scheme?.lowercased(),
              scheme == "https" else {
            throw UpdateCheckError.invalidResponse
        }
        return UpdateRelease(
            version: currentRelease.version,
            downloadURL: downloadURL,
            sizeBytes: currentRelease.sizeBytes
        )
    }

    static func availability(
        currentVersion: String,
        latestRelease: UpdateRelease
    ) throws -> UpdateAvailability {
        let current = try SemanticVersion(currentVersion)
        let latest = try SemanticVersion(latestRelease.version)
        return latest > current ? .updateAvailable(latestRelease) : .upToDate(latestRelease)
    }
}

private struct FlatStoreReleasesResponse: Decodable {
    let currentRelease: FlatStoreReleaseResponse?
}

private struct FlatStoreReleaseResponse: Decodable {
    let version: String
    let downloadURL: String
    let sizeBytes: Int64

    private enum CodingKeys: String, CodingKey {
        case version
        case downloadURL = "downloadUrl"
        case sizeBytes
    }
}

struct UpdatePackageDownloader: Sendable {
    typealias DownloadRequest = @Sendable (URLRequest) async throws -> (URL, URLResponse)

    static let maximumPackageSize: Int64 = 1_073_741_824

    private let downloadsDirectory: URL?
    private let downloadRequest: DownloadRequest

    init(
        session: URLSession = .shared,
        downloadsDirectory: URL? = FileManager.default.urls(
            for: .downloadsDirectory,
            in: .userDomainMask
        ).first
    ) {
        self.downloadsDirectory = downloadsDirectory
        downloadRequest = { request in
            try await session.download(for: request)
        }
    }

    init(
        downloadsDirectory: URL?,
        downloadRequest: @escaping DownloadRequest
    ) {
        self.downloadsDirectory = downloadsDirectory
        self.downloadRequest = downloadRequest
    }

    func download(_ release: UpdateRelease) async throws -> URL {
        guard release.sizeBytes > 0,
              release.sizeBytes <= Self.maximumPackageSize else {
            throw UpdateDownloadError.invalidPackageSize(release.sizeBytes)
        }

        var request = URLRequest(url: release.downloadURL)
        request.timeoutInterval = 300
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("XDecode/\(release.version)", forHTTPHeaderField: "User-Agent")

        let (temporaryURL, response) = try await downloadRequest(request)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        guard let response = response as? HTTPURLResponse else {
            throw UpdateDownloadError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw UpdateDownloadError.requestFailed(statusCode: response.statusCode)
        }

        try Self.validateDiskImage(at: temporaryURL, expectedSize: release.sizeBytes)
        guard let downloadsDirectory else {
            throw UpdateDownloadError.downloadsDirectoryUnavailable
        }

        return try savePackage(
            from: temporaryURL,
            suggestedFilename: response.suggestedFilename,
            version: release.version,
            in: downloadsDirectory
        )
    }

    static func validateDiskImage(at url: URL, expectedSize: Int64) throws {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw UpdateDownloadError.invalidDiskImage
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.int64Value else {
            throw UpdateDownloadError.invalidDiskImage
        }
        guard size == expectedSize else {
            throw UpdateDownloadError.sizeMismatch(expected: expectedSize, actual: size)
        }
        guard size >= 512 else {
            throw UpdateDownloadError.invalidDiskImage
        }

        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(size - 512))
            let signature = try handle.read(upToCount: 4)
            guard signature == Data("koly".utf8) else {
                throw UpdateDownloadError.invalidDiskImage
            }
        } catch let error as UpdateDownloadError {
            throw error
        } catch {
            throw UpdateDownloadError.invalidDiskImage
        }
    }

    private func savePackage(
        from temporaryURL: URL,
        suggestedFilename: String?,
        version: String,
        in directory: URL
    ) throws -> URL {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw UpdateDownloadError.downloadsDirectoryUnavailable
        }

        let filename = Self.packageFilename(suggestedFilename: suggestedFilename, version: version)
        let name = (filename as NSString).deletingPathExtension
        for index in 0...999 {
            let suffix = index == 0 ? "" : "-\(index)"
            let destination = directory.appendingPathComponent("\(name)\(suffix).dmg")
            do {
                try FileManager.default.moveItem(at: temporaryURL, to: destination)
                return destination
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            } catch {
                throw UpdateDownloadError.cannotSavePackage
            }
        }
        throw UpdateDownloadError.cannotSavePackage
    }

    private static func packageFilename(suggestedFilename: String?, version: String) -> String {
        if let suggestedFilename {
            let filename = (suggestedFilename as NSString).lastPathComponent
            if !filename.isEmpty,
               (filename as NSString).pathExtension.caseInsensitiveCompare("dmg") == .orderedSame {
                return filename
            }
        }

        let safeVersion = version.map { character in
            character.isNumber || character == "." || character == "-" ? character : "-"
        }
        return "XDecode-\(String(safeVersion)).dmg"
    }
}

private struct SemanticVersion: Comparable {
    let components: [Int]

    init(_ rawValue: String) throws {
        var version = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if version.first == "v" || version.first == "V" {
            version.removeFirst()
        }
        version = String(version.split(whereSeparator: { $0 == "-" || $0 == "+" }).first ?? "")
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              parts.compactMap({ Int($0) }).count == parts.count else {
            throw UpdateCheckError.invalidVersion(rawValue)
        }
        components = parts.compactMap { Int($0) }
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}
