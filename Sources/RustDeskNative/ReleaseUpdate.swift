import Foundation

/// 发布 tag 使用 SemVer；构建元数据不参与先后比较。
struct ReleaseVersion: Comparable {
    let numbers: [Int]
    let prerelease: [String]

    init?(_ value: String) {
        let value = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let metadata = value.split(separator: "+", omittingEmptySubsequences: false)
        guard metadata.count <= 2 else { return nil }
        if metadata.count == 2, !Self.validIdentifiers(String(metadata[1])) { return nil }
        let parts = metadata[0].split(
            separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let components = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3 else { return nil }
        var numbers: [Int] = []
        for component in components {
            guard Self.isNumeric(String(component)), component.count == 1 || component.first != "0",
                let number = Int(component)
            else { return nil }
            numbers.append(number)
        }
        self.numbers = numbers
        if parts.count == 2 {
            guard Self.validIdentifiers(String(parts[1])) else { return nil }
            prerelease = parts[1].split(separator: ".").map(String.init)
            guard
                prerelease.allSatisfy({ !Self.isNumeric($0) || $0.count == 1 || !$0.hasPrefix("0") }
                )
            else { return nil }
        } else {
            prerelease = []
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.numbers != rhs.numbers { return lhs.numbers.lexicographicallyPrecedes(rhs.numbers) }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            let leftNumeric = isNumeric(left)
            let rightNumeric = isNumeric(right)
            if leftNumeric != rightNumeric { return leftNumeric }
            if leftNumeric, left.count != right.count { return left.count < right.count }
            return left < right
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    private static func isNumeric(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func validIdentifiers(_ value: String) -> Bool {
        value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty
                && $0.utf8.allSatisfy {
                    (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                        || $0 == 45
                }
        }
    }
}

struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let state: String
        let size: Int
    }

    let tagName: String
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case draft, prerelease, assets
    }

    func hasMacInstaller(architecture: String) -> Bool {
        // 历史 Release 曾附带旧版本安装包；文件名必须与当前 tag 完全一致。
        let names = [architecture, "universal"].map { "FarPane-\(tagName)-macos-\($0).dmg" }
        return assets.contains { names.contains($0.name) && $0.state == "uploaded" && $0.size > 0 }
    }
}

struct ReleaseUpdate: Equatable {
    let tag: String
    let isPrerelease: Bool

    var pageURL: URL {
        // 从已验证的 tag 构造官方地址，不执行响应中的任意 URL。
        URL(string: "https://github.com/williamnie/farpane/releases/tag/\(tag)")!
    }

    static var currentArchitecture: String {
        #if arch(arm64)
            return "arm64"
        #else
            return "x86_64"
        #endif
    }

    static func newest(
        in releases: [GitHubRelease], after current: ReleaseVersion,
        architecture: String = currentArchitecture
    ) -> ReleaseUpdate? {
        guard let latest = latest(in: releases, architecture: architecture), latest.0 > current
        else { return nil }
        return latest.1
    }

    static func latest(in releases: [GitHubRelease], architecture: String = currentArchitecture)
        -> (ReleaseVersion, ReleaseUpdate)?
    {
        releases.compactMap { release -> (ReleaseVersion, ReleaseUpdate)? in
            guard !release.draft, let version = ReleaseVersion(release.tagName),
                release.hasMacInstaller(architecture: architecture)
            else { return nil }
            return (version, ReleaseUpdate(tag: release.tagName, isPrerelease: release.prerelease))
        }.max { $0.0 < $1.0 }
    }
}

enum ReleaseCheckError: Error {
    case invalidResponse
    case httpStatus(Int)
    case noCompatibleRelease

    var message: String {
        switch self {
        case .httpStatus(403), .httpStatus(429): return "检查过于频繁，请稍后重试。"
        case .noCompatibleRelease: return "尚未找到适用于这台 Mac 的安装包，请前往发布页查看。"
        default: return "暂时无法检查更新，请稍后重试或打开发布页。"
        }
    }
}

struct GitHubReleaseClient {
    static let releasesPage = URL(string: "https://github.com/williamnie/farpane/releases")!
    let session: URLSession

    init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        self.session = session ?? URLSession(configuration: configuration)
    }

    func fetch() async throws -> [GitHubRelease] {
        let url = URL(
            string: "https://api.github.com/repos/williamnie/farpane/releases?per_page=100")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("FarPane-Update-Check", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw ReleaseCheckError.invalidResponse
        }
        guard response.statusCode == 200 else {
            throw ReleaseCheckError.httpStatus(response.statusCode)
        }
        guard data.count <= 4 * 1024 * 1024 else { throw ReleaseCheckError.invalidResponse }
        return try JSONDecoder().decode([GitHubRelease].self, from: data)
    }
}
