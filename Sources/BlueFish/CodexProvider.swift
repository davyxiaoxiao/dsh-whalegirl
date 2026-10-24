import AppKit
import Foundation

/// Codex adapter.
///
/// Codex writes one rollout JSONL per thread under
/// `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`. The tail is enough to know
/// what a thread is doing: `task_started` / `task_complete` frame a turn,
/// `item_completed` carries tools and the final answer, and
/// `token_usage_record` / `token_count` carry usage.
final class CodexProvider: AgentProvider {
    struct Config {
        var maxSessions = 40
        var recentWindow: TimeInterval = 7 * 24 * 3600
        var tailBytes = 512 * 1024
        var bigTailBytes = 4 * 1024 * 1024
        /// Override for tests / `--dump-codex`; defaults to `~/.codex/sessions`.
        var rootURL: URL?
    }

    let id = AgentProviderID.codex
    let displayName = "Codex"
    let shortName = "Codex"
    let capabilities: AgentCapabilities = [.sessions, .usage, .reveal]
    var watchPath: String? { rootURL.path }

    private struct HeaderInfo {
        var sessionID: String = ""
        var cwd: String = ""
        var createdAt: Date?
        var originator: String = ""
        var firstUserText: String = ""
        var firstUserAt: Date?
    }

    private struct CacheEntry {
        var size: UInt64 = 0
        var mtime: Date = .distantPast
        var header: HeaderInfo?
        var headerTried = false
        var snapshot: AgentSession?
        var tokensToday = 0
        var callsToday = 0
    }

    private struct ParsedTail {
        var turnActive = false
        var turnStartedAt: Date?
        var taskStartedAt: Date?
        var turnNumber = 0
        var stepNumber = 0
        var startedToolCalls = 0
        var completedToolItems = 0
        var lastEventAt: Date = .distantPast
        var lastEventType = ""
        var lastToolName: String?
        var lastToolDetail: String?
        var lastToolStartedAt: Date?
        var lastAssistantText: String?
        var lastUserText: String?
        var lastUserAt: Date?
        var tokensThisTurn = 0
        var lastTurnTokens = 0
        var threadTokens = 0
        var todayTokens = 0
        var callsToday = 0
        var lastCompletedAt: Date?
        var lastErrorAt: Date?
        var lastErrorText: String?
        var lastTurnErrored = false
        var sawBoundary = false
        var sawUsageRecord = false
        var cwd = ""
        var quotas: [UsageQuota] = []
    }

    private let config: Config
    private let rootURL: URL
    private let log: ((String) -> Void)?
    private var cache: [String: CacheEntry] = [:]
    private var quotas: [UsageQuota] = []

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

    private static let midTurnTypes: Set<String> = [
        "item_completed", "token_count", "token_usage_record",
        "custom_tool_call", "function_call", "reasoning", "message",
        "compacted", "turn_context"
    ]

    init(config: Config = Config(), log: ((String) -> Void)? = nil) {
        self.config = config
        self.log = log
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
        self.rootURL = config.rootURL ?? codexHome
            .appendingPathComponent("sessions", isDirectory: true)
    }

    // MARK: - AgentProvider

    func refresh(now: Date) -> ProviderStatus {
        let dayStart = Calendar.current.startOfDay(for: now)
        var sessions: [AgentSession] = []
        var seen = Set<String>()

        for file in recentFiles(now: now) {
            let path = file.url.path
            seen.insert(path)

            var entry = cache[path] ?? CacheEntry()
            let headerChanged = entry.snapshot == nil
            if !entry.headerTried || headerChanged {
                entry.header = readHeader(logURL: file.url)
                entry.headerTried = true
            }

            if entry.size != file.size || entry.snapshot == nil {
                let parsed = parseTail(logURL: file.url, size: file.size, now: now, dayStart: dayStart)
                let built = buildSnapshot(
                    logURL: file.url,
                    mtime: file.mtime,
                    header: entry.header,
                    parsed: parsed,
                    now: now,
                    dayStart: dayStart
                )
                entry.snapshot = built.snapshot
                entry.tokensToday = built.tokensToday
                entry.callsToday = built.callsToday
                entry.size = file.size
                entry.mtime = file.mtime
                if !parsed.quotas.isEmpty { quotas = parsed.quotas }
            } else if var snapshot = entry.snapshot {
                snapshot.fileModifiedAt = file.mtime
                snapshot.derivePhase(now: now)
                entry.snapshot = snapshot
            }

            if var snapshot = entry.snapshot {
                snapshot.derivePhase(now: now)
                sessions.append(snapshot)
            }
            cache[path] = entry
        }

        for key in cache.keys where !seen.contains(key) {
            cache.removeValue(forKey: key)
        }

        sessions.sort { $0.lastEventAt > $1.lastEventAt }
        if sessions.count > config.maxSessions {
            sessions = Array(sessions.prefix(config.maxSessions))
        }

        let appRunning = !NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.openai.codex")
            .isEmpty
        let anyFresh = sessions.contains { now.timeIntervalSince($0.lastEventAt) < 20 }
        let running = appRunning || anyFresh

        let tokensToday = cache.values.reduce(0) { $0 + $1.tokensToday }
        let callsToday = cache.values.reduce(0) { $0 + $1.callsToday }
        let usage: ProviderUsage? = (tokensToday > 0 || callsToday > 0 || !quotas.isEmpty)
            ? ProviderUsage(
                providerID: id,
                providerName: shortName,
                today: UsageTotals(
                    costCNY: nil,
                    calls: callsToday > 0 ? callsToday : nil,
                    tokens: tokensToday > 0 ? tokensToday : nil
                ),
                quotas: quotas,
                sourceLabel: "~/.codex/sessions"
            )
            : nil

        return ProviderStatus(
            id: id,
            name: displayName,
            shortName: shortName,
            running: running,
            sessions: sessions,
            usage: usage,
            watchPath: rootURL.path,
            capabilities: capabilities,
            updatedAt: now
        )
    }

    // MARK: - Files

    private func recentFiles(now: Date) -> [(url: URL, size: UInt64, mtime: Date)] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let cutoff = now.addingTimeInterval(-config.recentWindow)
        var files: [(url: URL, size: UInt64, mtime: Date)] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            guard let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
            ),
            values.isRegularFile == true,
            let size = values.fileSize,
            let mtime = values.contentModificationDate,
            mtime > cutoff else { continue }
            files.append((url, UInt64(size), mtime))
        }
        files.sort { $0.mtime > $1.mtime }
        return Array(files.prefix(config.maxSessions))
    }

    // MARK: - Header

    private func readHeader(logURL: URL) -> HeaderInfo {
        guard let objects = LogTail.readJSONLinesFromHead(
            url: logURL,
            limit: 256 * 1024,
            maxEvents: 60
        ) else { return HeaderInfo() }

        var info = HeaderInfo()
        for obj in objects {
            let type = (obj["type"] as? String) ?? ""
            let payload = (obj["payload"] as? [String: Any]) ?? [:]
            if type == "session_meta" {
                info.sessionID = (payload["session_id"] as? String)
                    ?? (payload["id"] as? String)
                    ?? ""
                info.cwd = (payload["cwd"] as? String)
                    ?? (payload["runtime_workspace_roots"] as? [String])?.first
                    ?? ""
                info.createdAt = dateFromISO(payload["timestamp"])
                    ?? dateFromISO(obj["timestamp"])
                info.originator = (payload["originator"] as? String) ?? ""
            } else if type == "turn_context", info.cwd.isEmpty {
                info.cwd = (payload["cwd"] as? String) ?? ""
            } else if info.firstUserText.isEmpty {
                if type == "event_msg",
                   (payload["type"] as? String) == "item_completed",
                   let item = payload["item"] as? [String: Any],
                   (item["type"] as? String) == "UserMessage" {
                    info.firstUserText = textFromContent(item["content"], keys: ["text", "Text"])
                    info.firstUserAt = dateFromISO(obj["timestamp"])
                } else if type == "response_item",
                          (payload["type"] as? String) == "message",
                          (payload["role"] as? String) == "user" {
                    info.firstUserText = textFromContent(payload["content"], keys: ["input_text", "text"])
                    info.firstUserAt = dateFromISO(obj["timestamp"])
                }
            }
        }
        if info.sessionID.isEmpty {
            info.sessionID = logURL.deletingPathExtension().lastPathComponent
        }
        log?("codex header \(logURL.lastPathComponent) cwd=\(info.cwd) session=\(info.sessionID)")
        return info
    }

    // MARK: - Tail

    private func parseTail(logURL: URL, size: UInt64, now: Date, dayStart: Date) -> ParsedTail {
        for limit in [config.tailBytes, config.bigTailBytes] {
            guard let events = LogTail.readJSONLines(
                url: logURL,
                size: size,
                limit: limit,
                maxEvents: 900
            ), !events.isEmpty else { continue }
            return parse(events: events, now: now, dayStart: dayStart)
        }
        return ParsedTail()
    }

    private func parse(events: [[String: Any]], now: Date, dayStart: Date) -> ParsedTail {
        var p = ParsedTail()
        var latest: Date = .distantPast
        var fallbackToday = 0
        var fallbackTurn = 0
        var fallbackCalls = 0

        for obj in events {
            let type = (obj["type"] as? String) ?? ""
            let payload = (obj["payload"] as? [String: Any]) ?? [:]
            let subType = (payload["type"] as? String) ?? ""
            let time = dateFromISO(obj["timestamp"]) ?? latest
            if time > latest { latest = time }
            p.lastEventType = subType.isEmpty ? type : subType
            let isToday = time >= dayStart

            switch type {
            case "session_meta", "turn_context":
                if let cwd = payload["cwd"] as? String, !cwd.isEmpty { p.cwd = cwd }

            case "event_msg":
                switch subType {
                case "task_started":
                    let start = dateFromEpoch(payload["started_at"]) ?? time
                    p.turnActive = true
                    p.turnStartedAt = start
                    p.taskStartedAt = p.lastUserAt ?? start
                    p.turnNumber += 1
                    p.stepNumber = 0
                    p.startedToolCalls = 0
                    p.completedToolItems = 0
                    p.tokensThisTurn = 0
                    p.lastTurnTokens = 0
                    fallbackTurn = 0
                    p.lastCompletedAt = nil
                    p.lastErrorAt = nil
                    p.lastErrorText = nil
                    p.lastTurnErrored = false
                    p.lastToolName = nil
                    p.lastToolDetail = nil
                    p.lastToolStartedAt = nil
                    p.lastAssistantText = nil
                    p.sawBoundary = true

                case "task_complete":
                    p.turnActive = false
                    p.lastCompletedAt = dateFromEpoch(payload["completed_at"]) ?? time
                    p.lastErrorAt = nil
                    p.lastErrorText = nil
                    p.lastTurnErrored = false
                    p.sawBoundary = true
                    let message = (payload["last_agent_message"] as? String) ?? ""
                    if !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        p.lastAssistantText = tail(message, 160)
                    }

                case "turn_aborted":
                    let reason = (payload["reason"] as? String) ?? "interrupted"
                    p.turnActive = false
                    p.lastErrorAt = dateFromEpoch(payload["completed_at"]) ?? time
                    p.lastErrorText = reason == "interrupted" ? "本轮被中止" : "本轮失败：\(reason)"
                    p.lastTurnErrored = true
                    p.sawBoundary = true

                case "task_failed", "error", "stream_error":
                    p.turnActive = false
                    p.lastErrorAt = time
                    p.lastErrorText = (payload["message"] as? String)
                        ?? (payload["error"] as? String)
                        ?? "本轮失败"
                    p.lastTurnErrored = true
                    p.sawBoundary = true

                case "item_completed":
                    if let item = payload["item"] as? [String: Any] {
                        applyItem(item, at: time, to: &p)
                    }

                case "token_count":
                    if let info = payload["info"] as? [String: Any] {
                        let thread = intValue((info["total_token_usage"] as? [String: Any])?["total_tokens"])
                        if let thread, thread > p.threadTokens { p.threadTokens = thread }
                        if let last = intValue((info["last_token_usage"] as? [String: Any])?["total_tokens"]) {
                            fallbackTurn += last
                            if isToday {
                                fallbackToday += last
                                fallbackCalls += 1
                            }
                        }
                    }
                    if let parsed = parseQuotas(payload["rate_limits"], now: now), !parsed.isEmpty {
                        p.quotas = parsed
                    }

                default:
                    break
                }

            case "response_item":
                applyResponseItem(payload, at: time, to: &p)

            case "token_usage_record":
                p.sawUsageRecord = true
                let usage = (payload["usage"] as? [String: Any]) ?? [:]
                if let total = intValue(usage["total_tokens"]), total > 0 {
                    p.tokensThisTurn += total
                    if isToday {
                        p.todayTokens += total
                        p.callsToday += 1
                    }
                }
                if let turn = intValue((payload["turn_token_usage"] as? [String: Any])?["total_tokens"]),
                   turn > p.lastTurnTokens {
                    p.lastTurnTokens = turn
                }
                if let thread = intValue((payload["thread_token_usage"] as? [String: Any])?["total_tokens"]),
                   thread > p.threadTokens {
                    p.threadTokens = thread
                }

            case "compacted":
                p.lastToolName = "整理记忆"
                p.lastToolDetail = nil

            default:
                break
            }
        }

        p.lastEventAt = latest

        // Older Codex builds only emit `token_count`; newer ones emit both.
        // Only fall back when the tail has no per-response usage records.
        if !p.sawUsageRecord {
            if fallbackToday > p.todayTokens {
                p.todayTokens = fallbackToday
                p.callsToday = max(p.callsToday, fallbackCalls)
            }
            if fallbackTurn > p.tokensThisTurn {
                p.tokensThisTurn = fallbackTurn
            }
        }
        if p.turnActive, p.lastTurnTokens > p.tokensThisTurn {
            p.tokensThisTurn = p.lastTurnTokens
        }
        p.stepNumber = max(p.startedToolCalls, p.completedToolItems)
        if p.taskStartedAt == nil {
            p.taskStartedAt = p.lastUserAt ?? p.turnStartedAt
        }
        return p
    }

    private func applyItem(_ item: [String: Any], at time: Date, to p: inout ParsedTail) {
        let kind = (item["type"] as? String) ?? ""

        switch kind {
        case "UserMessage":
            let text = textFromContent(item["content"], keys: ["text", "Text"])
            if !text.isEmpty {
                p.lastUserText = tail(text, 160)
                p.lastUserAt = time
                p.taskStartedAt = time
            }

        case "AgentMessage":
            let text = textFromContent(item["content"], keys: ["Text", "text"])
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                p.lastAssistantText = tail(text, 160)
            }

        case "CommandExecution", "FileChange", "McpToolCall", "Extension",
             "ContextCompaction", "ImageView":
            p.completedToolItems += 1
            let action = describeItem(item)
            p.lastToolName = action.0
            p.lastToolDetail = action.1
            p.lastToolStartedAt = time

        default:
            break
        }
    }

    private func applyResponseItem(_ payload: [String: Any], at time: Date, to p: inout ParsedTail) {
        let kind = (payload["type"] as? String) ?? ""

        switch kind {
        case "message":
            let role = (payload["role"] as? String) ?? ""
            let text = textFromContent(payload["content"], keys: ["input_text", "output_text", "text", "Text"])
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            if role == "user" {
                p.lastUserText = tail(text, 160)
                p.lastUserAt = time
                p.taskStartedAt = time
            } else if role == "assistant" {
                p.lastAssistantText = tail(text, 160)
            }

        case "custom_tool_call":
            p.startedToolCalls += 1
            let name = (payload["name"] as? String) ?? "tool"
            let input = (payload["input"] as? String) ?? ""
            let action = describeCustomTool(name: name, input: input)
            p.lastToolName = action.0
            p.lastToolDetail = action.1
            p.lastToolStartedAt = time

        case "function_call":
            p.startedToolCalls += 1
            let name = (payload["name"] as? String) ?? "tool"
            let namespace = (payload["namespace"] as? String) ?? ""
            let args = parseArguments(payload["arguments"])
            let action = describeFunctionCall(name: name, namespace: namespace, args: args)
            p.lastToolName = action.0
            p.lastToolDetail = action.1
            p.lastToolStartedAt = time

        case "image_generation_call":
            p.startedToolCalls += 1
            let prompt = (payload["revised_prompt"] as? String) ?? ""
            p.lastToolName = "画图"
            p.lastToolDetail = prompt.isEmpty ? nil : tail(prompt.replacingOccurrences(of: "\n", with: " "), 34)
            p.lastToolStartedAt = time

        case "web_search_call", "web_search":
            p.startedToolCalls += 1
            let query = (payload["query"] as? String) ?? (payload["action"] as? [String: Any])?["query"] as? String
            p.lastToolName = "上网搜"
            p.lastToolDetail = query.map { tail($0, 34) }
            p.lastToolStartedAt = time

        case "local_shell_call", "shell_call":
            p.startedToolCalls += 1
            p.lastToolName = "跑命令"
            p.lastToolDetail = nil
            p.lastToolStartedAt = time

        default:
            break
        }
    }

    private func describeItem(_ item: [String: Any]) -> (String, String?) {
        let kind = (item["type"] as? String) ?? ""
        switch kind {
        case "CommandExecution":
            let command = commandString(item["command"])
            var detail = command.map { tail($0.replacingOccurrences(of: "\n", with: " "), 40) }
            if (item["status"] as? String) == "failed" {
                detail = detail.map { "\($0) · 失败" } ?? "失败了"
            }
            return ("跑命令", detail)

        case "FileChange":
            let changes = (item["changes"] as? [String: Any]) ?? [:]
            if changes.count > 1 { return ("改文件", "\(changes.count) 个文件") }
            if let path = changes.keys.first { return ("改文件", baseName(path)) }
            return ("改文件", nil)

        case "McpToolCall":
            let server = (item["server"] as? String) ?? "MCP"
            let tool = (item["tool"] as? String) ?? "tool"
            let args = (item["arguments"] as? [String: Any]) ?? [:]
            let title = (args["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return ("调工具", title.map { tail($0, 34) } ?? "\(server)/\(tool)")

        case "Extension":
            let kind = (item["kind"] as? String) ?? "扩展"
            if kind == "clock.sleep", let ms = intValue(item["durationMs"]) {
                return ("等待", "\(max(1, ms / 1000))s")
            }
            return ("扩展", kind)

        case "ContextCompaction":
            return ("整理记忆", nil)

        case "ImageView":
            let path = (item["path"] as? String) ?? ""
            return ("看图片", path.isEmpty ? nil : baseName(path))

        default:
            return (kind.isEmpty ? "工具" : kind, nil)
        }
    }

    private func describeCustomTool(name: String, input: String) -> (String, String?) {
        let lower = name.lowercased()
        if lower.contains("exec") || input.contains("exec_command") || input.contains("tools.exec") {
            return ("跑命令", extractExecCommand(input).map { tail($0.replacingOccurrences(of: "\n", with: " "), 40) })
        }
        if lower.contains("patch") || lower.contains("edit") || lower.contains("write") {
            return ("改代码", firstPatchPath(input).map(baseName))
        }
        return (name.isEmpty ? "工具" : name, input.isEmpty ? nil : tail(input.replacingOccurrences(of: "\n", with: " "), 34))
    }

    private func describeFunctionCall(name: String, namespace: String, args: [String: Any]) -> (String, String?) {
        if let cmd = (args["cmd"] as? String) ?? (args["command"] as? String) {
            return ("跑命令", tail(cmd.replacingOccurrences(of: "\n", with: " "), 40))
        }
        if let title = args["title"] as? String, !title.isEmpty {
            return ("调工具", tail(title, 34))
        }
        if let code = args["code"] as? String, !code.isEmpty {
            return ("调工具", tail(code.replacingOccurrences(of: "\n", with: " "), 34))
        }
        let qualified = namespace.isEmpty ? name : "\(namespace)/\(name)"
        return ("调工具", qualified)
    }

    private func commandString(_ raw: Any?) -> String? {
        if let command = raw as? [String], !command.isEmpty {
            return command.last
        }
        if let command = raw as? String, !command.isEmpty { return command }
        return nil
    }

    /// Codex's `exec` tool is a JS snippet. Pull out `cmd: "..."` without
    /// pretending to be a JavaScript parser.
    private func extractExecCommand(_ input: String) -> String? {
        guard let marker = input.range(of: #"cmd\s*:\s*""#, options: .regularExpression) else { return nil }
        var result = ""
        var escaped = false
        for ch in input[marker.upperBound...] {
            if escaped {
                switch ch {
                case "n": result.append("\n")
                case "t": result.append("\t")
                default: result.append(ch)
                }
                escaped = false
                continue
            }
            if ch == "\\" { escaped = true; continue }
            if ch == "\"" { break }
            result.append(ch)
        }
        let value = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func firstPatchPath(_ input: String) -> String? {
        for line in input.split(separator: "\n") {
            if line.hasPrefix("*** Update File: ") {
                return String(line.dropFirst("*** Update File: ".count))
            }
            if line.hasPrefix("*** Add File: ") {
                return String(line.dropFirst("*** Add File: ".count))
            }
            if line.hasPrefix("*** Delete File: ") {
                return String(line.dropFirst("*** Delete File: ".count))
            }
        }
        return nil
    }

    private func buildSnapshot(
        logURL: URL,
        mtime: Date,
        header: HeaderInfo?,
        parsed: ParsedTail,
        now: Date,
        dayStart: Date
    ) -> (snapshot: AgentSession, tokensToday: Int, callsToday: Int) {
        let cwd = parsed.cwd.isEmpty ? (header?.cwd ?? "") : parsed.cwd
        let headerCreated = header?.createdAt
        var tokensToday = parsed.todayTokens
        // A thread created today has a cumulative thread total that covers the
        // whole day even when the tail no longer contains the early records.
        if let created = headerCreated, created >= dayStart {
            tokensToday = max(tokensToday, parsed.threadTokens)
        }

        var snapshot = AgentSession(
            id: header?.sessionID ?? logURL.deletingPathExtension().lastPathComponent,
            directory: logURL.deletingLastPathComponent().path,
            logPath: logURL.path,
            title: "",
            cwd: cwd,
            workspaceName: cwd.isEmpty ? "Codex" : baseName(cwd),
            createdAt: headerCreated,
            lastEventAt: parsed.lastEventAt == .distantPast ? mtime : parsed.lastEventAt,
            fileModifiedAt: mtime,
            providerID: id,
            providerName: shortName
        )
        snapshot.turnActive = parsed.turnActive
        snapshot.turnStartedAt = parsed.turnStartedAt
        snapshot.taskStartedAt = parsed.lastUserAt
            ?? header?.firstUserAt
            ?? parsed.turnStartedAt
        snapshot.turnNumber = parsed.turnNumber
        snapshot.stepNumber = parsed.stepNumber
        snapshot.lastTurnErrored = parsed.lastTurnErrored
        snapshot.lastErrorText = parsed.lastErrorText
        snapshot.lastCompletedAt = parsed.lastCompletedAt
        snapshot.lastErrorAt = parsed.lastErrorAt
        snapshot.lastToolName = parsed.lastToolName
        snapshot.lastToolDetail = parsed.lastToolDetail
        snapshot.lastToolStartedAt = parsed.lastToolStartedAt
        snapshot.lastAssistantText = parsed.lastAssistantText
        snapshot.lastUserText = parsed.lastUserText ?? header?.firstUserText
        snapshot.tokensThisTurn = parsed.tokensThisTurn
        snapshot.lastEventType = parsed.lastEventType

        // The tail may start in the middle of a turn. If the file is fresh and
        // the last event is a mid-turn event, trust it rather than showing idle.
        if !snapshot.turnActive, !parsed.sawBoundary {
            let fresh = now.timeIntervalSince(max(parsed.lastEventAt, mtime)) < 120
            if fresh, Self.midTurnTypes.contains(parsed.lastEventType) {
                snapshot.turnActive = true
                snapshot.turnStartedAt = parsed.turnStartedAt
                    ?? parsed.lastUserAt
                    ?? parsed.lastEventAt
            }
        }

        snapshot.derivePhase(now: now)
        return (snapshot, tokensToday, parsed.callsToday)
    }

    // MARK: - Rate limits

    private func parseQuotas(_ raw: Any?, now: Date) -> [UsageQuota]? {
        guard let dict = raw as? [String: Any] else { return nil }
        var result: [UsageQuota] = []
        for (key, fallbackWindow) in [("primary", "5h"), ("secondary", "周")] {
            guard let window = dict[key] as? [String: Any] else { continue }
            guard let percent = intValue(window["used_percent"])
                ?? intValue(window["usedPercent"])
                ?? intValue(window["percent"]) else { continue }
            let minutes = intValue(window["window_minutes"]) ?? intValue(window["windowMinutes"])
            let label = minutes.map { $0 >= 1440 ? "周" : "\(max(1, $0 / 60))h" } ?? fallbackWindow
            let resetSeconds = intValue(window["resets_in_seconds"])
                ?? intValue(window["resetsInSeconds"])
            let resetsAt = resetSeconds.map { now.addingTimeInterval(TimeInterval($0)) }
                ?? dateFromEpoch(window["resets_at"])
            result.append(UsageQuota(
                provider: "Codex",
                window: label,
                percent: percent,
                resetsAt: resetsAt,
                sampledAt: now
            ))
        }
        return result
    }

    // MARK: - Helpers

    private func textFromContent(_ raw: Any?, keys: Set<String>) -> String {
        guard let blocks = raw as? [[String: Any]] else { return "" }
        return blocks.compactMap { block -> String? in
            let type = (block["type"] as? String) ?? ""
            guard keys.contains(type) else { return nil }
            return block["text"] as? String
        }.joined(separator: "\n")
    }

    private func parseArguments(_ raw: Any?) -> [String: Any] {
        if let dict = raw as? [String: Any] { return dict }
        guard let string = raw as? String, let data = string.data(using: .utf8) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func intValue(_ v: Any?) -> Int? {
        if let n = v as? Int { return n }
        if let n = v as? NSNumber { return n.intValue }
        if let n = v as? Double { return Int(n) }
        if let s = v as? String { return Int(s) }
        return nil
    }

    private func dateFromISO(_ raw: Any?) -> Date? {
        guard let s = raw as? String else { return nil }
        return Self.isoFractional.date(from: s) ?? Self.isoPlain.date(from: s)
    }

    private func dateFromEpoch(_ raw: Any?) -> Date? {
        if let n = raw as? NSNumber { return Date(timeIntervalSince1970: n.doubleValue) }
        if let n = raw as? Double { return Date(timeIntervalSince1970: n) }
        if let n = raw as? Int { return Date(timeIntervalSince1970: Double(n)) }
        if let s = raw as? String, let n = Double(s) { return Date(timeIntervalSince1970: n) }
        return nil
    }
}
