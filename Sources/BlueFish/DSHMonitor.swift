import AppKit
import Foundation

/// Watches the DSH session store and turns it into pet-sized status.
///
/// The session log is an append-only file of concatenated zstd frames, one JSON
/// event per line. We only need the last handful of events, so instead of
/// decompressing whole (potentially 50 MB) logs we decompress the last chunk
/// starting from a zstd frame boundary. That keeps the monitor at a few
/// milliseconds per poll.
final class DSHMonitor {
    struct Config {
        var pollInterval: TimeInterval = 1.5
        var tailBytes = 384 * 1024
        var bigTailBytes = 2 * 1024 * 1024
        var maxSessions = 40
        var activeWindow: TimeInterval = 120
        var log: ((String) -> Void)?
    }

    private struct HeaderInfo {
        var cwd: String = ""
        var createdAt: Date?
        var title: String = ""
        var firstUserText: String = ""
        var firstUserAt: Date?
    }

    private struct CacheEntry {
        var size: UInt64 = 0
        var mtime: Date = .distantPast
        var header: HeaderInfo?
        var headerTried = false
        var lastTurnStart: Date?
        var snapshot: SessionSnapshot?
    }

    private let config: Config
    private let rootURL: URL
    private let queue = DispatchQueue(label: "bluefish.dsh-monitor", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var cache: [String: CacheEntry] = [:]
    private var archivedIDs: Set<String> = []
    private var workspaceMetaUpdatedAt: Date = .distantPast
    private var workspaceTitles: [String: String] = [:]

    private var costUpdatedAt: Date = .distantPast
    private var todayCost: Double?
    private var todayCalls: Int?
    private var todayTokens: Int?
    private var planQuotas: [PlanQuota] = []

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private let zstdPath: String?
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    private(set) var isPaused = false
    private var lastAppRunning = false
    var onUpdate: ((DSHStatus) -> Void)?

    init(config: Config = Config()) {
        self.config = config
        self.rootURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dsh/sessions", isDirectory: true)
        self.zstdPath = DSHMonitor.findZstd()
        self.config.log?("zstd=\(zstdPath ?? "not found")")
    }

    func start() {
        queue.async { [weak self] in
            self?.refreshLocked()
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + config.pollInterval, repeating: config.pollInterval, leeway: .milliseconds(300))
        t.setEventHandler { [weak self] in
            guard let self, !self.isPaused else { return }
            self.refreshLocked()
        }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func setPaused(_ paused: Bool) {
        queue.async {
            self.isPaused = paused
            if !paused { self.refreshLocked() }
        }
    }

    /// Synchronous refresh, used by `--dump` and tests.
    func refreshNow() -> DSHStatus {
        queue.sync { self.scanLocked() }
    }

    private func refreshLocked() {
        guard !isPaused else { return }
        let status = scanLocked()
        DispatchQueue.main.async { [weak self] in
            self?.onUpdate?(status)
        }
    }

    // MARK: - Scan

    private func scanLocked() -> DSHStatus {
        let now = Date()
        updateWorkspaceMetaIfNeeded(now: now)
        updateCostIfNeeded(now: now)

        var sessions: [SessionSnapshot] = []
        let fm = FileManager.default
        let workspaceDirs = (try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []

        var seen = Set<String>()
        for workspaceDir in workspaceDirs {
            guard (try? workspaceDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let sessionDirs = (try? fm.contentsOfDirectory(at: workspaceDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            for sessionDir in sessionDirs {
                guard sessionDir.lastPathComponent.hasPrefix("session-") else { continue }
                let logURL = sessionDir.appendingPathComponent("session.v4.jsonl.zstd")
                guard let values = try? logURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                      let size = values.fileSize.map(UInt64.init),
                      let mtime = values.contentModificationDate else { continue }
                let path = logURL.path
                seen.insert(path)

                var entry = cache[path] ?? CacheEntry()
                let headerChanged = entry.snapshot == nil || entry.size == 0
                if !entry.headerTried || headerChanged {
                    entry.header = readHeader(logURL: logURL)
                    entry.headerTried = true
                }

                if entry.size != size || entry.snapshot == nil {
                    let parsed = parseTail(logURL: logURL, size: size)
                    entry.lastTurnStart = parsed.turnStartedAt ?? entry.lastTurnStart
                    if entry.lastTurnStart == nil, parsed.turnActive {
                        entry.lastTurnStart = lastTurnStartDate(logURL: logURL)
                    }
                    var snapshot = buildSnapshot(
                        sessionDir: sessionDir,
                        logURL: logURL,
                        size: size,
                        mtime: mtime,
                        header: entry.header,
                        parsed: parsed,
                        turnStartHint: entry.lastTurnStart
                    )
                    if !snapshot.turnActive { entry.lastTurnStart = nil }
                    if snapshot.title.isEmpty, let previous = entry.snapshot?.title { snapshot.title = previous }
                    snapshot.isArchived = archivedIDs.contains(snapshot.id)
                    entry.snapshot = snapshot
                    entry.size = size
                    entry.mtime = mtime
                    cache[path] = entry
                } else if var snapshot = entry.snapshot {
                    snapshot.fileModifiedAt = mtime
                    if entry.lastTurnStart != nil, snapshot.turnActive {
                        snapshot.turnStartedAt = entry.lastTurnStart
                    }
                    snapshot.isArchived = archivedIDs.contains(snapshot.id)
                    entry.snapshot = snapshot
                    cache[path] = entry
                }

                if var snapshot = cache[path]?.snapshot {
                    snapshot.derivePhase(now: now)
                    if !snapshot.isArchived { sessions.append(snapshot) }
                }
            }
        }

        for key in cache.keys where !seen.contains(key) {
            cache.removeValue(forKey: key)
        }

        sessions.sort { $0.lastEventAt > $1.lastEventAt }
        if sessions.count > config.maxSessions { sessions = Array(sessions.prefix(config.maxSessions)) }

        let appRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.deepseek.dsh").isEmpty
        let anyFresh = sessions.contains { now.timeIntervalSince($0.lastEventAt) < 12 }
        let wasAppRunning = lastAppRunning
        lastAppRunning = appRunning
        var status = DSHStatus()
        status.sessions = sessions
        // The desktop app quitting should flip the pet to "disconnected"
        // immediately; the freshness fallback only covers CLI-run backends.
        status.dshRunning = appRunning || (!wasAppRunning && anyFresh)
        status.todayCost = todayCost
        status.todayCalls = todayCalls
        status.todayTokens = todayTokens
        status.planQuotas = planQuotas
        status.updatedAt = now
        return status
    }

    private func buildSnapshot(
        sessionDir: URL,
        logURL: URL,
        size: UInt64,
        mtime: Date,
        header: HeaderInfo?,
        parsed: ParsedTail,
        turnStartHint: Date?
    ) -> SessionSnapshot {
        let id = sessionDir.lastPathComponent
        let workspaceDirName = sessionDir.deletingLastPathComponent().lastPathComponent
        let workspacePath = decodeWorkspacePath(workspaceDirName)
        let cwd = parsed.cwd.isEmpty ? (header?.cwd ?? workspacePath) : parsed.cwd
        let workspaceName = baseName(cwd.isEmpty ? workspacePath : cwd)
        let title = parsed.title.isEmpty ? (header?.title ?? "") : parsed.title
        let parsedUser = parsed.lastUserText ?? ""
        let lastUser = parsedUser.isEmpty ? (header?.firstUserText ?? "") : parsedUser
        var snapshot = SessionSnapshot(
            id: id,
            directory: sessionDir.path,
            logPath: logURL.path,
            title: title,
            cwd: cwd,
            workspaceName: workspaceName,
            createdAt: header?.createdAt,
            lastEventAt: parsed.lastEventAt == .distantPast ? mtime : parsed.lastEventAt,
            fileModifiedAt: mtime
        )
        snapshot.turnActive = parsed.turnActive
        snapshot.turnStartedAt = parsed.turnStartedAt ?? turnStartHint
        snapshot.turnNumber = parsed.turnNumber
        snapshot.stepNumber = parsed.stepNumber
        snapshot.lastTurnErrored = parsed.lastTurnErrored
        snapshot.lastErrorText = parsed.lastErrorText
        snapshot.lastCompletedAt = parsed.lastCompletedAt
        snapshot.lastErrorAt = parsed.lastErrorAt
        snapshot.pendingApproval = parsed.pendingApproval
        snapshot.lastToolName = parsed.lastToolName
        snapshot.lastToolDetail = parsed.lastToolDetail
        snapshot.lastToolStartedAt = parsed.lastToolStartedAt
        snapshot.lastAssistantText = parsed.lastAssistantText
        snapshot.lastUserText = lastUser
        snapshot.taskStartedAt = parsed.lastUserAt ?? header?.firstUserAt
        snapshot.tokensThisTurn = parsed.tokensThisTurn
        snapshot.runningJobs = Array(parsed.jobs.values)
        snapshot.deliverables = parsed.deliverables
        snapshot.lastEventType = parsed.lastEventType
        snapshot.isArchived = archivedIDs.contains(id)
        snapshot.derivePhase()
        return snapshot
    }

    private func decodeWorkspacePath(_ name: String) -> String {
        var s = name
        if s.hasPrefix("--") { s.removeFirst(2) }
        if s.hasSuffix("--") { s.removeLast(2) }
        if s.hasPrefix("-") { s.removeFirst() }
        return "/" + s.replacingOccurrences(of: "-", with: "/")
    }

    private func updateWorkspaceMetaIfNeeded(now: Date) {
        guard now.timeIntervalSince(workspaceMetaUpdatedAt) > 60 else { return }
        workspaceMetaUpdatedAt = now
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dsh/storages/workspace.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let global = obj["global"] as? [String: Any],
           let archived = global["archivedSessionIds"] as? [String] {
            archivedIDs = Set(archived)
        }
        if let tables = obj["tables"] as? [String: Any],
           let workspaces = tables["workspaces"] as? [String: Any] {
            var titles: [String: String] = [:]
            for (_, value) in workspaces {
                guard let ws = value as? [String: Any],
                      let sessionIDs = ws["sessionIds"] as? [String] else { continue }
                let title = (ws["title"] as? String) ?? ""
                for id in sessionIDs { titles[id] = title }
            }
            workspaceTitles = titles
        }
    }

    private func updateCostIfNeeded(now: Date) {
        guard now.timeIntervalSince(costUpdatedAt) > 20 else { return }
        costUpdatedAt = now
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dsh/storages/cost-meter/ledger.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            todayCost = nil
            todayCalls = nil
            todayTokens = nil
            planQuotas = []
            return
        }

        if let days = obj["days"] as? [String: Any],
           let today = days[dateFormatter.string(from: now)] as? [String: Any] {
            todayCost = (today["costCny"] as? NSNumber)?.doubleValue ?? (today["costCny"] as? Double)
            todayCalls = (today["calls"] as? NSNumber)?.intValue ?? (today["calls"] as? Int)
            let fields = ["input", "output", "cacheRead", "cacheWrite", "reasoning"]
            todayTokens = fields.reduce(0) { partial, key in
                partial + ((today[key] as? NSNumber)?.intValue ?? 0)
            }
        } else {
            todayCost = nil
            todayCalls = nil
            todayTokens = nil
        }

        planQuotas = parsePlanQuotas(obj["planSamples"])
    }

    /// dsh-cost-meter keeps one sample per quota window:
    ///   planSamples.go.fiveHour[] = { t, p, lt, lc, r, s }
    /// where p is the provider-reported percentage, r the reset time and
    /// lt / lc the locally counted tokens / cost at sample time.
    private func parsePlanQuotas(_ raw: Any?) -> [PlanQuota] {
        guard let providers = raw as? [String: Any] else { return [] }
        let keys = providers.keys.sorted { a, b in
            if a == "go" { return true }
            if b == "go" { return false }
            return a < b
        }
        let windowNames: [(String, String)] = [("fiveHour", "5h"), ("weekly", "周"), ("monthly", "月")]
        var quotas: [PlanQuota] = []
        for providerKey in keys {
            guard let windows = providers[providerKey] as? [String: Any] else { continue }
            let provider = planProviderLabel(providerKey)
            var providerQuotas: [PlanQuota] = []
            for (name, label) in windowNames {
                guard let samples = windows[name] as? [[String: Any]] else { continue }
                guard let latest = samples.last(where: { ($0["p"] as? NSNumber) != nil }) ?? samples.last else { continue }
                let percent = (latest["p"] as? NSNumber)?.intValue ?? 0
                let resetRaw = latest["r"] as? String
                let reset = resetRaw.flatMap { Self.isoFractional.date(from: $0) ?? Self.isoPlain.date(from: $0) }
                providerQuotas.append(PlanQuota(
                    provider: provider,
                    window: label,
                    percent: percent,
                    resetsAt: reset,
                    sampledAt: dateFromMS(latest["t"])
                ))
            }
            if !providerQuotas.isEmpty {
                quotas = providerQuotas
                break
            }
        }
        return quotas
    }

    private func planProviderLabel(_ key: String) -> String {
        switch key.lowercased() {
        case "go": return "Go"
        case "codex": return "Codex"
        case "minimax": return "MiniMax"
        case "volcengine-agent": return "火山"
        case "tencent-coding", "tencent-token": return "腾讯"
        case "baidu-coding": return "百度"
        case "bailian": return "百炼"
        default:
            guard let first = key.first else { return key }
            return first.uppercased() + key.dropFirst()
        }
    }

    // MARK: - Log parsing

    private struct ParsedTail {
        var turnActive = false
        var turnStartedAt: Date?
        var turnNumber = 0
        var stepNumber = 0
        var lastEventAt: Date = .distantPast
        var lastEventType = ""
        var pendingApproval: ApprovalRequest?
        var lastToolName: String?
        var lastToolDetail: String?
        var lastToolStartedAt: Date?
        var lastAssistantText: String?
        var lastUserText: String?
        var lastUserAt: Date?
        var tokensThisTurn = 0
        var jobs: [String: JobInfo] = [:]
        var deliverables: [String] = []
        var lastCompletedAt: Date?
        var lastAssistantHadToolCall = false
        var lastAssistantHadText = false
        var lastErrorAt: Date?
        var lastErrorText: String?
        var lastTurnErrored = false
        var title = ""
        var cwd = ""
        var sawTurnStart = false
        var lastTurnMarkerIsStart = false
    }

    private func parseTail(logURL: URL, size: UInt64) -> ParsedTail {
        guard let events = readTailEvents(logURL: logURL, size: size) else { return ParsedTail() }
        return parse(events: events)
    }

    private func readTailEvents(logURL: URL, size: UInt64) -> [[String: Any]]? {
        for limit in [config.tailBytes, config.bigTailBytes] {
            let data = readTail(logURL: logURL, size: size, limit: limit)
            guard !data.isEmpty else { continue }
            let candidates = frameOffsets(in: data).prefix(4)
            for offset in candidates {
                let chunk = data.subdata(in: offset..<data.count)
                guard let out = decompress(chunk), !out.isEmpty else { continue }
                var events: [[String: Any]] = []
                for line in out.split(separator: 0x0A) where line.count > 8 {
                    guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
                    events.append(obj)
                }
                if !events.isEmpty {
                    return events.count > 800 ? Array(events.suffix(800)) : events
                }
            }
        }
        return nil
    }

    private func readTail(logURL: URL, size: UInt64, limit: Int) -> Data {
        guard let fh = try? FileHandle(forReadingFrom: logURL) else { return Data() }
        defer { try? fh.close() }
        let start = size > UInt64(limit) ? size - UInt64(limit) : 0
        do {
            try fh.seek(toOffset: start)
            return fh.readDataToEndOfFile()
        } catch {
            return Data()
        }
    }

    private func frameOffsets(in data: Data) -> [Int] {
        guard data.count >= 4 else { return [] }
        var offsets: [Int] = []
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let n = data.count - 3
            var i = 0
            while i < n {
                if base[i] == 0x28, base[i + 1] == 0xB5, base[i + 2] == 0x2F, base[i + 3] == 0xFD {
                    offsets.append(i)
                    i += 4
                } else {
                    i += 1
                }
            }
        }
        return offsets
    }

    private func decode(_ event: [String: Any], type: String) -> [String: Any] {
        (event["data"] as? [String: Any]) ?? [:]
    }

    private func parse(events: [[String: Any]]) -> ParsedTail {
        var p = ParsedTail()
        var pending: [String: ApprovalRequest] = [:]
        var jobMap: [String: JobInfo] = [:]
        var turnStart: Date?
        var compactionActive = false
        var lastTurnMarkerStart: Bool?
        var tokensSinceTurnStart = 0
        var latestTime: Date = .distantPast

        for event in events {
            let type = (event["type"] as? String) ?? ""
            let time = dateFromMS(event["time"]) ?? latestTime
            if time > latestTime { latestTime = time }
            p.lastEventType = type
            let d = decode(event, type: type)

            switch type {
            case "session":
                if let cwd = d["cwd"] as? String { p.cwd = cwd }

            case "session/title":
                if let title = d["title"] as? String, !title.isEmpty { p.title = title }

            case "turn/start":
                p.turnActive = true
                turnStart = time
                p.turnStartedAt = time
                p.turnNumber = intValue(d["turn"]) ?? p.turnNumber
                p.stepNumber = 0
                p.lastTurnErrored = false
                p.lastErrorAt = nil
                p.lastCompletedAt = nil
                p.tokensThisTurn = 0
                tokensSinceTurnStart = 0
                p.sawTurnStart = true
                lastTurnMarkerStart = true
                p.lastTurnMarkerIsStart = true

            case "turn/end":
                p.turnActive = false
                lastTurnMarkerStart = false
                p.lastTurnMarkerIsStart = false
                if let reason = d["reason"] as? [String: Any] {
                    let kind = (reason["kind"] as? String) ?? ""
                    if kind == "completed" {
                        // DSH ends a turn after every model call, including
                        // tool-call turns. A real task completion is the turn
                        // whose final assistant message has text but no tool
                        // call. Otherwise the pet would celebrate every step.
                        let finalAnswer = !p.lastAssistantHadToolCall && p.lastAssistantHadText
                        p.lastCompletedAt = finalAnswer ? time : nil
                        p.lastTurnErrored = false
                        p.lastErrorAt = nil
                    } else if kind == "aborted" {
                        p.lastErrorAt = time
                        p.lastErrorText = "本轮被中止"
                        p.lastTurnErrored = true
                    } else {
                        p.lastErrorAt = time
                        p.lastTurnErrored = true
                        if let err = reason["error"] as? [String: Any],
                           let message = err["message"] as? String {
                            p.lastErrorText = message
                        } else {
                            p.lastErrorText = "本轮失败"
                        }
                    }
                }
                if let usage = d["usage"] as? [String: Any], let total = intValue(usage["totalTokens"]) {
                    p.tokensThisTurn = total
                }
                turnStart = nil

            case "step/start":
                p.stepNumber = intValue(d["step"]) ?? p.stepNumber

            case "assistant/message":
                if let usage = d["usage"] as? [String: Any], let total = intValue(usage["totalTokens"]) {
                    tokensSinceTurnStart += total
                    p.tokensThisTurn = tokensSinceTurnStart
                }
                if let message = d["message"] as? [String: Any],
                   let content = message["content"] as? [[String: Any]] {
                    p.lastAssistantHadToolCall = content.contains { ($0["type"] as? String) == "tool-call" }
                    let text = content.compactMap { block -> String? in
                        guard (block["type"] as? String) == "text" else { return nil }
                        return block["text"] as? String
                    }.joined(separator: "\n")
                    p.lastAssistantHadText = !text.isEmpty
                    if !text.isEmpty { p.lastAssistantText = tail(text, 160) }
                }

            case "user/message":
                p.lastUserAt = time
                if let content = d["content"] as? [[String: Any]] {
                    let text = content.compactMap { block -> String? in
                        guard (block["type"] as? String) == "text" else { return nil }
                        return block["text"] as? String
                    }.joined(separator: " ")
                    if !text.isEmpty { p.lastUserText = tail(text, 160) }
                }

            case "tool/call":
                let raw = (d["name"] as? String) ?? "tool"
                let args = parseArguments(d["arguments"])
                let action = describeTool(raw, args)
                p.lastToolName = action.0
                p.lastToolDetail = action.1
                p.lastToolStartedAt = time

            case "tool/result":
                if let message = d["message"] as? [String: Any],
                   (message["isError"] as? Bool) == true {
                    p.lastToolDetail = "报错了"
                }

            case "approval/asked":
                let id = (d["id"] as? String) ?? UUID().uuidString
                let tool = (d["toolName"] as? String) ?? "操作"
                let reason = (d["reason"] as? String) ?? ""
                pending[id] = ApprovalRequest(id: id, tool: tool, reason: reason, since: time)

            case "approval/decided":
                if let id = d["id"] as? String { pending.removeValue(forKey: id) }

            case "job/registered":
                if let id = d["jobId"] as? String {
                    jobMap[id] = JobInfo(
                        id: id,
                        label: (d["label"] as? String) ?? (d["kind"] as? String) ?? "任务",
                        kind: (d["kind"] as? String) ?? "",
                        startedAt: dateFromMS(d["startedAt"]) ?? time
                    )
                }

            case "job/settled":
                if let id = d["jobId"] as? String { jobMap.removeValue(forKey: id) }

            case "deliverables/presented":
                if let files = d["files"] as? [[String: Any]] {
                    p.deliverables = files.compactMap { $0["path"] as? String }
                }

            case "compaction/start":
                compactionActive = true
                p.lastToolName = "整理记忆"
                p.lastToolDetail = nil

            case "compaction/end":
                compactionActive = false

            default:
                break
            }
        }

        p.lastEventAt = latestTime
        p.lastTurnErrored = p.turnActive ? p.lastTurnErrored : p.lastTurnErrored
        if p.turnActive == false, lastTurnMarkerStart == nil, !events.isEmpty {
            // The tail window started in the middle of a turn (or right after
            // one). Only trust a mid-turn window when the file is fresh enough
            // to be live; freshness is applied by the caller.
            let tailTypes: Set<String> = [
                "step/start", "step/end", "assistant/message", "tool/call", "tool/result",
                "job/registered", "job/settled", "approval/asked", "approval/decided",
                "llm/retry", "llm/retry-started", "compaction/start", "compaction/end"
            ]
            if tailTypes.contains(p.lastEventType) {
                p.turnActive = true
            }
        }
        if p.turnActive, p.turnStartedAt == nil {
            p.turnStartedAt = turnStart
        }
        if compactionActive { p.lastToolName = "整理记忆" }
        if !pending.isEmpty {
            p.pendingApproval = pending.values.sorted { $0.since > $1.since }.first
            if let approval = p.pendingApproval, Date().timeIntervalSince(approval.since) > 3600 {
                p.pendingApproval = nil
            }
        }
        p.jobs = jobMap
        return p
    }

    private func parseArguments(_ raw: Any?) -> [String: Any] {
        if let dict = raw as? [String: Any] { return dict }
        guard let string = raw as? String, let data = string.data(using: .utf8) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func describeTool(_ name: String, _ args: [String: Any]) -> (String, String?) {
        func field(_ keys: String...) -> String? {
            for key in keys {
                if let v = args[key] as? String, !v.isEmpty { return v }
            }
            return nil
        }
        func short(_ value: String, _ limit: Int = 34) -> String {
            tail(value.replacingOccurrences(of: "\n", with: " "), limit)
        }
        switch name {
        case "bash":
            if let desc = field("description") { return ("跑命令", short(desc)) }
            if let cmd = field("command") { return ("跑命令", short(cmd)) }
            return ("跑命令", nil)
        case "read":
            if let p = field("file_path") { return ("读文件", baseName(p)) }
            return ("读文件", nil)
        case "write":
            if let p = field("file_path") { return ("写文件", baseName(p)) }
            return ("写文件", nil)
        case "edit":
            if let p = field("file_path") { return ("改代码", baseName(p)) }
            return ("改代码", nil)
        case "grep":
            if let p = field("pattern") { return ("搜代码", short(p)) }
            return ("搜代码", nil)
        case "glob":
            if let p = field("pattern") { return ("找文件", short(p)) }
            return ("找文件", nil)
        case "web_search":
            if let queries = args["queries"] as? [String], let first = queries.first { return ("上网搜", short(first)) }
            return ("上网搜", nil)
        case "web_fetch":
            if let url = field("url"), let host = URL(string: url)?.host { return ("看网页", host) }
            return ("看网页", nil)
        case "generate_image", "generate_images", "edit_image":
            return ("画图", field("prompt").map { short($0) })
        case "todo_write":
            if let todos = args["todos"] as? [[String: Any]],
               let first = todos.first?["content"] as? String {
                return ("写计划", short(first))
            }
            return ("写计划", nil)
        case "present":
            if let files = args["files"] as? [[String: Any]], let first = files.first {
                if let path = first["path"] as? String { return ("交付", baseName(path)) }
            }
            return ("交付", nil)
        case "ask_user_question":
            if let questions = args["questions"] as? [[String: Any]],
               let q = questions.first?["question"] as? String { return ("问你", short(q)) }
            return ("问你", nil)
        case "subagent", "subagent_fork":
            return ("派子代理", field("description").map { short($0) })
        case "job_output", "job_list":
            return ("看后台任务", nil)
        case "update_goal", "create_goal":
            return ("更新目标", nil)
        case "skill":
            return ("加载技能", field("name"))
        default:
            return (name, nil)
        }
    }

    // MARK: - First-frame header

    private func readHeader(logURL: URL) -> HeaderInfo? {
        guard let fh = try? FileHandle(forReadingFrom: logURL) else { return nil }
        defer { try? fh.close() }
        let data = (try? fh.read(upToCount: 96 * 1024)) ?? Data()
        guard !data.isEmpty else { return nil }
        let offsets = frameOffsets(in: data)
        guard let first = offsets.first else { return nil }
        guard let out = decompress(data.subdata(in: first..<data.count)) else { return nil }
        var info = HeaderInfo()
        for line in out.split(separator: 0x0A).prefix(40) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            let type = (obj["type"] as? String) ?? ""
            let d = (obj["data"] as? [String: Any]) ?? [:]
            if type == "session" {
                info.cwd = (obj["cwd"] as? String) ?? ""
                info.createdAt = dateFromMS(obj["createdAt"])
            } else if type == "session/title", let t = d["title"] as? String {
                info.title = t
            } else if type == "user/message", info.firstUserText.isEmpty {
                if let content = d["content"] as? [[String: Any]] {
                    info.firstUserText = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: " ")
                }
                info.firstUserAt = dateFromMS(obj["time"])
            } else if type == "agent/inbox/spliced", info.firstUserText.isEmpty {
                if let inserted = d["inserted"] as? [[String: Any]],
                   let first = inserted.first,
                   (first["role"] as? String) == "user" {
                    if let content = first["content"] as? [[String: Any]] {
                        info.firstUserText = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: " ")
                    }
                    info.firstUserAt = dateFromMS(obj["time"])
                }
            }
        }
        config.log?("header \(logURL.lastPathComponent) cwd=\(info.cwd) title=\(info.title)")
        return info
    }

    /// If the pet starts while a turn is already in progress, the tail may not
    /// contain the turn/start event. Decompress once and find the last marker.
    private func lastTurnStartDate(logURL: URL) -> Date? {
        guard let zstd = zstdPath else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: zstd)
        process.arguments = ["-dc", "-q", logURL.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        var buffer = Data()
        var lastMarker: (Bool, Date)? // (isStart, time)
        let handle = pipe.fileHandleForReading
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: 0..<newline)
                buffer.removeSubrange(0...newline)
                guard line.count > 10,
                      let text = String(data: line, encoding: .utf8),
                      text.contains("\"turn/start\"") || text.contains("\"turn/end\"") else { continue }
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let type = obj["type"] as? String,
                      let time = dateFromMS(obj["time"]) else { continue }
                lastMarker = (type == "turn/start", time)
            }
        }
        process.waitUntilExit()
        if let marker = lastMarker, marker.0 { return marker.1 }
        return nil
    }

    // MARK: - zstd

    private func decompress(_ data: Data) -> Data? {
        guard let zstd = zstdPath else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: zstd)
        process.arguments = ["-dc", "-q"]
        let inPipe = Pipe()
        let outPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        DispatchQueue.global(qos: .utility).async {
            do {
                try inPipe.fileHandleForWriting.write(contentsOf: data)
                try inPipe.fileHandleForWriting.close()
            } catch {
                try? inPipe.fileHandleForWriting.close()
            }
        }
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return out.isEmpty ? nil : out
    }

    private static func findZstd() -> String? {
        var candidates: [String] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("zstd-helper").path)
        }
        if let executable = Bundle.main.executableURL {
            candidates.append(executable.deletingLastPathComponent().appendingPathComponent("zstd-helper").path)
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        candidates.append(cwd.appendingPathComponent("build/zstd-helper").path)
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/zstd",
            "/usr/local/bin/zstd",
            "/usr/bin/zstd",
            "/opt/local/bin/zstd"
        ])
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - Helpers

    private func intValue(_ v: Any?) -> Int? {
        if let n = v as? Int { return n }
        if let n = v as? NSNumber { return n.intValue }
        if let n = v as? Double { return Int(n) }
        if let s = v as? String { return Int(s) }
        return nil
    }

    private func dateFromMS(_ v: Any?) -> Date? {
        if let n = v as? NSNumber { return Date(timeIntervalSince1970: n.doubleValue / 1000) }
        if let n = v as? Double { return Date(timeIntervalSince1970: n / 1000) }
        if let n = v as? Int { return Date(timeIntervalSince1970: Double(n) / 1000) }
        if let s = v as? String, let n = Double(s) { return Date(timeIntervalSince1970: n / 1000) }
        return nil
    }
}
