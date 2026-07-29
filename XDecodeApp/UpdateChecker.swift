import Foundation

struct UpdateRelease: Equatable, Sendable {
    let version: String
    let pageURL: URL
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

struct UpdateChecker: Sendable {
    static let latestReleaseEndpoint = URL(
        string: "https://api.github.com/repos/LineShine/XDecode/releases/latest"
    )!

    private let endpoint: URL

    init(endpoint: URL = UpdateChecker.latestReleaseEndpoint) {
        self.endpoint = endpoint
    }

    func check(currentVersion: String) async throws -> UpdateAvailability {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
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

        let payload: GitHubReleaseResponse
        do {
            payload = try JSONDecoder().decode(GitHubReleaseResponse.self, from: data)
        } catch {
            throw UpdateCheckError.invalidResponse
        }
        let release = UpdateRelease(version: payload.tagName, pageURL: payload.htmlURL)
        return try Self.availability(currentVersion: currentVersion, latestRelease: release)
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

private struct GitHubReleaseResponse: Decodable {
    let tagName: String
    let htmlURL: URL

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
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
