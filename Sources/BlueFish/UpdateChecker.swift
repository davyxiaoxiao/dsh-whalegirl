import AppKit
import CryptoKit

// MARK: - Model

struct PetUpdateRelease: Equatable {
    /// Version without the leading `v`, e.g. `1.0.2`.
    let version: String
    let tag: String
    let pageURL: URL
    let packageURL: URL?
    let packageName: String?
    let digest: String?
    let notes: String?

    static func fake(version: String) -> PetUpdateRelease {
        PetUpdateRelease(
            version: version,
            tag: "v\(version)",
            pageURL: URL(string: "https://github.com/\(UpdateFeed.repository)/releases")!,
            packageURL: nil,
            packageName: nil,
            digest: nil,
            notes: nil
        )
    }
}

enum PetUpdateState: Equatable {
    case idle
    case checking
    case upToDate(version: String)
    case available(PetUpdateRelease)
    case downloading(version: String, progress: Double)
    case ready(version: String, packageURL: URL)
    case failed(message: String)
}

// MARK: - Versions

enum AppVersion {
    static var current: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    static func numbers(_ raw: String) -> [Int] {
        raw.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            .split(whereSeparator: { $0 == "." || $0 == "-" || $0 == "+" })
            .map { Int($0.prefix(while: { $0.isNumber })) ?? 0 }
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = numbers(candidate)
        let b = numbers(current)
        guard !a.isEmpty else { return false }
        for index in 0..<max(a.count, b.count) {
            let lhs = index < a.count ? a[index] : 0
            let rhs = index < b.count ? b[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return false
    }
}

// MARK: - Release feed

/// Reads the latest release from the GitHub API, falling back to the public
/// release page. The API has a 60 req/h anonymous limit per IP and some shared
/// networks hit it, so the HTML fallback keeps the check reliable.
enum UpdateFeed {
    static let repository = "davyxiaoxiao/dsh-whalegirl"
    static let baseURL = URL(string: "https://github.com/\(repository)/")!
    static let apiURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    static func fetch(completion: @escaping (Result<PetUpdateRelease, Error>) -> Void) {
        fetchFromAPI { result in
            switch result {
            case .success(let release):
                completion(.success(release))
            case .failure(let apiError):
                DebugLog.write("update api failed: \(apiError.localizedDescription), trying release page")
                fetchFromPage { pageResult in
                    switch pageResult {
                    case .success(let release):
                        completion(.success(release))
                    case .failure:
                        completion(.failure(apiError))
                    }
                }
            }
        }
    }

    private static func fetchFromAPI(completion: @escaping (Result<PetUpdateRelease, Error>) -> Void) {
        var request = URLRequest(url: apiURL)
        request.timeoutInterval = 12
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("WhaleGirl/\(AppVersion.current) (macOS)", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(UpdateFeedError.network(error.localizedDescription)))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(UpdateFeedError.malformed))
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                completion(.failure(UpdateFeedError.badStatus(http.statusCode)))
                return
            }
            guard let data,
                  let payload = try? JSONDecoder().decode(GitHubRelease.self, from: data),
                  !payload.draft,
                  !payload.prerelease else {
                completion(.failure(UpdateFeedError.malformed))
                return
            }
            completion(.success(release(from: payload)))
        }.resume()
    }

    private static func fetchFromPage(completion: @escaping (Result<PetUpdateRelease, Error>) -> Void) {
        var latestRequest = URLRequest(url: URL(string: "releases/latest", relativeTo: baseURL)!.absoluteURL)
        latestRequest.timeoutInterval = 15
        latestRequest.setValue("WhaleGirl/\(AppVersion.current) (macOS)", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: latestRequest) { _, response, error in
            guard error == nil else {
                completion(.failure(UpdateFeedError.network(error?.localizedDescription ?? "")))
                return
            }
            guard let finalURL = response?.url, let tag = tag(from: finalURL) else {
                completion(.failure(UpdateFeedError.noRelease))
                return
            }
            let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            let pageURL = URL(string: "releases/tag/\(tag)", relativeTo: baseURL)!.absoluteURL
            var assetsRequest = URLRequest(
                url: URL(string: "releases/expanded_assets/\(tag)", relativeTo: baseURL)!.absoluteURL
            )
            assetsRequest.timeoutInterval = 15
            assetsRequest.setValue("WhaleGirl/\(AppVersion.current) (macOS)", forHTTPHeaderField: "User-Agent")
            session.dataTask(with: assetsRequest) { data, _, _ in
                let html = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let asset = assetLink(in: html)
                completion(.success(PetUpdateRelease(
                    version: version,
                    tag: tag,
                    pageURL: pageURL,
                    packageURL: asset?.url,
                    packageName: asset?.url.lastPathComponent,
                    digest: asset?.digest,
                    notes: nil
                )))
            }.resume()
        }.resume()
    }

    private static func release(from payload: GitHubRelease) -> PetUpdateRelease {
        let asset = payload.assets.first { $0.name.lowercased().hasSuffix(".pkg") }
            ?? payload.assets.first { $0.name.lowercased().hasSuffix(".zip") }
        return PetUpdateRelease(
            version: payload.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")),
            tag: payload.tagName,
            pageURL: payload.htmlURL,
            packageURL: asset?.browserDownloadURL,
            packageName: asset?.name,
            digest: asset?.digest,
            notes: payload.body
        )
    }

    private static func tag(from url: URL) -> String? {
        let parts = url.pathComponents
        guard let index = parts.firstIndex(of: "tag"), index + 1 < parts.count else { return nil }
        let tag = parts[index + 1]
        return tag.isEmpty ? nil : tag
    }

    private static func assetLink(in html: String) -> (url: URL, digest: String?)? {
        let pattern = #"href="(/[^"]*/releases/download/[^"]+\.pkg)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..<html.endIndex, in: html)),
              let hrefRange = Range(match.range(at: 1), in: html) else { return nil }
        let href = String(html[hrefRange])
        guard let url = URL(string: href, relativeTo: baseURL)?.absoluteURL else { return nil }
        var digest: String?
        if let tailRange = html.range(of: href) {
            let tail = html[tailRange.upperBound...].prefix(4000)
            if let digestRange = tail.range(of: #"sha256:[0-9a-fA-F]{64}"#, options: .regularExpression) {
                digest = String(tail[digestRange])
            }
        }
        return (url, digest)
    }
}

private enum UpdateFeedError: LocalizedError {
    case network(String)
    case badStatus(Int)
    case noRelease
    case malformed

    var errorDescription: String? {
        switch self {
        case .network(let message):
            return message.isEmpty ? "网络连接失败" : "网络连接失败：\(message)"
        case .badStatus(let code):
            return "更新服务返回 HTTP \(code)"
        case .noRelease:
            return "还没有发布版本"
        case .malformed:
            return "解析更新信息失败"
        }
    }
}

// MARK: - Checker

/// Checks GitHub for a newer build and hands the release pkg to the system
/// Installer. The app is ad-hoc signed and installed by a pkg, so "update"
/// means: download the pkg, verify its digest, open it.
final class UpdateChecker {
    static let checkInterval: TimeInterval = 6 * 60 * 60
    static let lastCheckKey = "BlueFish.lastUpdateCheck"
    static let fakeArgument = "--fake-update"

    private let defaults: UserDefaults
    private var timer: Timer?
    private var isChecking = false
    private var latestRelease: PetUpdateRelease?
    private var currentDownloader: UpdateDownloader?

    private(set) var state: PetUpdateState = .idle {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }

    var onStateChange: ((PetUpdateState) -> Void)?
    var onError: ((String) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    deinit {
        timer?.invalidate()
        currentDownloader?.cancel()
    }

    func start() {
        if let fake = Self.fakeVersion() {
            let release = PetUpdateRelease.fake(version: fake)
            latestRelease = release
            state = .available(release)
            return
        }
        check(force: false)
        let timer = Timer(timeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            self?.check(force: false)
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        currentDownloader?.cancel()
    }

    func check(force: Bool = false) {
        guard !isChecking else { return }
        if case .downloading = state { return }
        if case .ready = state { return }
        if !force,
           let last = defaults.object(forKey: Self.lastCheckKey) as? Date,
           Date().timeIntervalSince(last) < Self.checkInterval {
            return
        }
        isChecking = true
        if force { state = .checking }
        UpdateFeed.fetch { [weak self] result in
            DispatchQueue.main.async {
                self?.apply(result)
            }
        }
    }

    /// Download the release pkg (or open the release page when the asset is
    /// missing) and hand it to the Installer. Safe to call repeatedly.
    func performUpdate() {
        switch state {
        case .available(let release):
            guard let url = release.packageURL else {
                NSWorkspace.shared.open(release.pageURL)
                return
            }
            download(release, from: url)
        case .ready(_, let fileURL):
            if FileManager.default.fileExists(atPath: fileURL.path) {
                NSWorkspace.shared.open(fileURL)
            } else if let release = latestRelease {
                state = .available(release)
                performUpdate()
            }
        default:
            break
        }
    }

    private func apply(_ result: Result<PetUpdateRelease, Error>) {
        isChecking = false
        defaults.set(Date(), forKey: Self.lastCheckKey)
        switch result {
        case .success(let release):
            latestRelease = release
            if AppVersion.isNewer(release.version, than: AppVersion.current) {
                DebugLog.write("update available current=\(AppVersion.current) latest=\(release.version)")
                state = .available(release)
            } else {
                state = .upToDate(version: AppVersion.current)
            }
        case .failure(let error):
            fail(error.localizedDescription)
        }
    }

    private func fail(_ message: String) {
        DebugLog.write("update check failed: \(message)")
        if let release = latestRelease,
           AppVersion.isNewer(release.version, than: AppVersion.current) {
            state = .available(release)
            return
        }
        state = .failed(message: message)
    }

    private func download(_ release: PetUpdateRelease, from url: URL) {
        guard currentDownloader == nil else { return }
        let ext = (release.packageName as NSString?)?.pathExtension.lowercased() ?? "pkg"
        let directory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let safeVersion = release.version.replacingOccurrences(of: "/", with: "-")
        let destination = directory.appendingPathComponent("WhaleGirl-\(safeVersion).\(ext)")
        state = .downloading(version: release.version, progress: 0)
        DebugLog.write("update downloading \(url.absoluteString) -> \(destination.path)")

        let downloader = UpdateDownloader(url: url, destination: destination, expectedDigest: release.digest)
        currentDownloader = downloader
        downloader.onProgress = { [weak self] progress in
            guard let self, case .downloading(let version, let old) = self.state else { return }
            if progress - old >= 0.01 || progress >= 0.999 {
                self.state = .downloading(version: version, progress: progress)
            }
        }
        downloader.onFinish = { [weak self] result in
            guard let self else { return }
            self.currentDownloader = nil
            switch result {
            case .success(let fileURL):
                DebugLog.write("update downloaded \(fileURL.path)")
                self.state = .ready(version: release.version, packageURL: fileURL)
                NSWorkspace.shared.open(fileURL)
            case .failure(let error):
                DebugLog.write("update download failed: \(error.localizedDescription)")
                self.state = .available(release)
                self.onError?(error.localizedDescription)
            }
        }
        downloader.start()
    }

    // MARK: - Diagnostics

    static func fakeVersion() -> String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: fakeArgument), args.count > index + 1 else { return nil }
        let raw = args[index + 1].trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
        return raw.isEmpty ? "9.9.9" : raw
    }

    /// `WhaleGirl --check-update` — one-shot network check for debugging.
    static func diagnose(completion: @escaping (String) -> Void) {
        var parts = ["current=\(AppVersion.current)"]
        UpdateFeed.fetch { result in
            switch result {
            case .success(let release):
                parts.append("latest=\(release.tag)")
                parts.append("update=\(AppVersion.isNewer(release.version, than: AppVersion.current))")
                parts.append("asset=\(release.packageName ?? "-")")
                parts.append("digest=\(release.digest ?? "-")")
                parts.append("pkg=\(release.packageURL?.absoluteString ?? "-")")
            case .failure(let error):
                parts.append("error=\(error.localizedDescription)")
            }
            let line = parts.joined(separator: " ")
            DispatchQueue.main.async { completion(line) }
        }
    }
}

// MARK: - GitHub JSON

private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL
        let digest: String?

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
            case digest
        }
    }

    let tagName: String
    let htmlURL: URL
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case body
        case draft
        case prerelease
        case assets
    }
}

// MARK: - Downloader

private enum UpdateError: LocalizedError {
    case checksumMismatch
    case missingFile

    var errorDescription: String? {
        switch self {
        case .checksumMismatch: return "安装包校验失败，已取消"
        case .missingFile: return "安装包下载不完整"
        }
    }
}

private final class UpdateDownloader: NSObject, URLSessionDownloadDelegate {
    private let url: URL
    private let destination: URL
    private let expectedDigest: String?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var tempFile: URL?
    private var finished = false

    var onProgress: ((Double) -> Void)?
    var onFinish: ((Result<URL, Error>) -> Void)?

    init(url: URL, destination: URL, expectedDigest: String?) {
        self.url = url
        self.destination = destination
        self.expectedDigest = expectedDigest
    }

    func start() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.downloadTask(with: url)
        self.task = task
        task.resume()
    }

    func cancel() {
        task?.cancel()
        session?.invalidateAndCancel()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        DispatchQueue.main.async { self.onProgress?(progress) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhaleGirl-update-\(UUID().uuidString).\(destination.pathExtension)")
        do {
            try? FileManager.default.removeItem(at: temp)
            try FileManager.default.moveItem(at: location, to: temp)
            tempFile = temp
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
            return
        }
        guard let tempFile else {
            finish(.failure(UpdateError.missingFile))
            return
        }
        do {
            try verify(tempFile)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tempFile, to: destination)
            finish(.success(destination))
        } catch {
            try? FileManager.default.removeItem(at: tempFile)
            finish(.failure(error))
        }
    }

    private func verify(_ file: URL) throws {
        guard let expectedDigest,
              expectedDigest.lowercased().hasPrefix("sha256:") else { return }
        let expected = String(expectedDigest.dropFirst("sha256:".count)).lowercased()
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else { throw UpdateError.checksumMismatch }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard !finished else { return }
        finished = true
        session?.finishTasksAndInvalidate()
        DispatchQueue.main.async { self.onFinish?(result) }
    }
}
