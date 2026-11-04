import Foundation

enum ReleaseCheckOutcome: Equatable {
    case available(ReleaseUpdate)
    case upToDate
    case failed(String)
}

@MainActor final class ReleaseUpdateChecker {
    static let automaticDefaultsKey = "farpane.updates.automatic"
    let currentVersion: String?
    private let defaults: UserDefaults
    private let fetch: () async throws -> [GitHubRelease]
    private let now: () -> Date
    private var task: Task<Void, Never>?
    private var lastAttempt: Date?
    private var retryInterval: TimeInterval = 6 * 60 * 60
    private var wantsManualResult = false
    private(set) var outcome: ReleaseCheckOutcome?
    private(set) var availableUpdate: ReleaseUpdate?
    var onChange: (() -> Void)?
    var onManualResult: ((ReleaseCheckOutcome) -> Void)?

    init(
        currentVersion: String? = Bundle.main.infoDictionary?["CFBundleShortVersionString"]
            as? String, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init,
        fetch: @escaping () async throws -> [GitHubRelease] = {
            try await GitHubReleaseClient().fetch()
        }
    ) {
        self.currentVersion = currentVersion
        self.defaults = defaults
        self.now = now
        self.fetch = fetch
    }

    var automaticEnabled: Bool {
        defaults.object(forKey: Self.automaticDefaultsKey) as? Bool ?? true
    }

    var isChecking: Bool { task != nil }

    var statusText: String {
        if isChecking { return "正在检查更新…" }
        switch outcome {
        case .available(let update):
            return "发现新版本 \(update.tag)\(update.isPrerelease ? "（预览版）" : "")，可前往发布页下载。"
        case .upToDate: return "当前已是最新可用版本。"
        case .failed(let message): return message
        case nil: return automaticEnabled ? "启动时及运行期间每 6 小时检查一次。" : "自动检查已关闭，仍可手动检查。"
        }
    }

    func setAutomaticEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.automaticDefaultsKey)
        onChange?()
        if enabled { checkIfDue() }
    }

    @discardableResult func checkIfDue() -> Task<Void, Never>? {
        guard automaticEnabled, currentVersion.flatMap(ReleaseVersion.init) != nil else {
            return nil
        }
        if let lastAttempt, now().timeIntervalSince(lastAttempt) >= 0,
            now().timeIntervalSince(lastAttempt) < retryInterval
        {
            return nil
        }
        return check(manual: false)
    }

    @discardableResult func check(manual: Bool = true) -> Task<Void, Never>? {
        wantsManualResult = wantsManualResult || manual
        if let task { return task }
        guard let current = currentVersion.flatMap(ReleaseVersion.init) else {
            finish(.failed("无法读取当前版本，请使用已安装的 FarPane，或前往发布页下载。"))
            return nil
        }
        lastAttempt = now()
        let fetch = self.fetch
        task = Task { [weak self] in
            let result: ReleaseCheckOutcome
            do {
                let releases = try await fetch()
                guard let latest = ReleaseUpdate.latest(in: releases) else {
                    throw ReleaseCheckError.noCompatibleRelease
                }
                if latest.0 > current { result = .available(latest.1) } else { result = .upToDate }
            } catch {
                result = .failed((error as? ReleaseCheckError)?.message ?? "暂时无法检查更新，请检查网络后重试。")
            }
            guard !Task.isCancelled else { return }
            self?.finish(result)
        }
        onChange?()
        return task
    }

    func stop() {
        task?.cancel()
        task = nil
        wantsManualResult = false
    }

    private func finish(_ result: ReleaseCheckOutcome) {
        task = nil
        outcome = result
        switch result {
        case .available(let update):
            availableUpdate = update
            retryInterval = 6 * 60 * 60
        case .upToDate:
            availableUpdate = nil
            retryInterval = 6 * 60 * 60
        case .failed:
            // 临时断网不清除已发现的更新，也不弹出后台错误提示。
            retryInterval = 60 * 60
        }
        let shouldPresent = wantsManualResult
        wantsManualResult = false
        onChange?()
        if shouldPresent { onManualResult?(result) }
    }
}
