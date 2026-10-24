import AppKit
import Foundation
import SQLite3

/// OpenCode adapter.
///
/// OpenCode keeps sessions in a local SQLite database
/// (`~/.local/share/opencode/opencode.db`): `session` has titles, cwd, model,
/// cumulative tokens/cost and timestamps; `message` / `part` carry the turn
/// and tool details. We only read the DB, and only refresh a session's details
/// when `session.time_updated` changes.
final class OpenCodeProvider: AgentProvider {
    struct Config {
        var maxSessions = 40
        var recentWindow: TimeInterval = 7 * 24 * 3600
        /// OpenCode Go quota lookup is opt-out for anyone who wants a fully
        /// offline app. It only runs when an OpenCode account exists.
        var fetchQuotas = true
        /// Override for tests / `--dump-opencode`.
        var databaseURL: URL?
    }

    let id = AgentProviderID.openCode
    let displayName = "OpenCode"
    let shortName = "OpenCode"
    let capabilities: AgentCapabilities = [.sessions, .usage, .reveal]
    var watchPath: String? { dataDir.path }

    private struct CacheEntry {
        var updated: Int64
        var snapshot: AgentSession
        var tokensToday: Int
        var callsToday: Int
        var costToday: Double
    }

    private struct MessageInfo {
        let id: String
        let role: String
        let created: Int64
        let completed: Int64?
        let finish: String
        let tokens: Int
        let cost: Double
        let error: String?
    }

    private struct PartInfo {
        let messageID: String
        let created: Int64
        let type: String
        let data: [String: Any]
    }

    static var defaultDataDir: URL {
        let env = ProcessInfo.processInfo.environment
        let dataHome = env["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/share", isDirectory: true)
        return dataHome.appendingPathComponent("opencode", isDirectory: true)
    }

    static var defaultDatabaseURL: URL {
        defaultDataDir.appendingPathComponent("opencode.db")
    }

    private let config: Config
    private let dataDir: URL
    private let dbURL: URL
    private let logURL: URL
    private let log: ((String) -> Void)?
    private var cache: [String: CacheEntry] = [:]
    private let quotaLock = NSLock()
    private var cachedQuotas: [UsageQuota] = []
    private var lastQuotaAttempt: Date = .distantPast
    private var quotaFetchInFlight = false

    init(config: Config = Config(), log: ((String) -> Void)? = nil) {
        self.config = config
        self.log = log
        self.dataDir = Self.defaultDataDir
        self.dbURL = config.databaseURL ?? Self.defaultDatabaseURL
        self.logURL = dataDir.appendingPathComponent("log/opencode.log")
    }

    // MARK: - AgentProvider

    func refresh(now: Date) -> ProviderStatus {
        let empty = ProviderStatus(
            id: id,
            name: displayName,
            shortName: shortName,
            running: false,
            sessions: [],
            usage: nil,
            watchPath: dataDir.path,
            capabilities: capabilities,
            updatedAt: now
        )
        guard let db = OpenCodeDatabase(path: dbURL.path, log: log) else {
            cache.removeAll()
            return empty
        }

        let dayStart = Calendar.current.startOfDay(for: now)
        let dayStartMS = Int64(dayStart.timeIntervalSince1970 * 1000)
        let cutoff = Int64((now.timeIntervalSince1970 - config.recentWindow) * 1000)
        let rows = db.rows(
            """
            SELECT id, title, directory, model, agent, cost,
                   tokens_input, tokens_output, tokens_reasoning,
                   tokens_cache_read, tokens_cache_write,
                   time_created, time_updated, time_compacting, permission
            FROM session
            WHERE time_archived IS NULL AND time_updated >= ?
            ORDER BY time_updated DESC
            LIMIT ?
            """,
            [cutoff, Int64(config.maxSessions)]
        )

        var sessions: [AgentSession] = []
        var seen = Set<String>()
        for row in rows {
            guard let sessionID = string(row["id"]), !sessionID.isEmpty else { continue }
            seen.insert(sessionID)
            let updated = int64(row["time_updated"]) ?? 0
            var entry: CacheEntry
            if let cached = cache[sessionID], cached.updated == updated {
                entry = cached
            } else {
                entry = buildEntry(
                    row: row,
                    db: db,
                    now: now,
                    dayStart: dayStart,
                    dayStartMS: dayStartMS
                )
                cache[sessionID] = entry
            }
            var snapshot = entry.snapshot
            snapshot.derivePhase(now: now)
            sessions.append(snapshot)
        }

        for key in cache.keys where !seen.contains(key) {
            cache.removeValue(forKey: key)
        }

        let anyFresh = sessions.contains { now.timeIntervalSince($0.lastEventAt) < 120 }
        let logFresh: Bool = {
            guard let values = try? logURL.resourceValues(forKeys: [.contentModificationDateKey]),
                  let mtime = values.contentModificationDate else { return false }
            return now.timeIntervalSince(mtime) < 120
        }()

        let tokensToday = cache.values.reduce(0) { $0 + $1.tokensToday }
        let callsToday = cache.values.reduce(0) { $0 + $1.callsToday }
        let costToday = cache.values.reduce(0) { $0 + $1.costToday }
        maybeRefreshQuotas(now: now)
        let quotas = currentQuotas()
        var usage: ProviderUsage? = (tokensToday > 0 || callsToday > 0 || costToday > 0 || !quotas.isEmpty)
            ? ProviderUsage(
                providerID: id,
                providerName: shortName,
                today: UsageTotals(
                    costCNY: nil,
                    costUSD: costToday > 0 ? costToday : nil,
                    calls: callsToday > 0 ? callsToday : nil,
                    tokens: tokensToday > 0 ? tokensToday : nil
                ),
                quotas: quotas,
                sourceLabel: "~/.local/share/opencode/opencode.db"
            )
            : nil
        if usage == nil, !quotas.isEmpty {
            usage = ProviderUsage(
                providerID: id,
                providerName: shortName,
                today: nil,
                quotas: quotas,
                sourceLabel: "opencode.ai/console"
            )
        }

        return ProviderStatus(
            id: id,
            name: displayName,
            shortName: shortName,
            running: anyFresh || logFresh,
            sessions: sessions,
            usage: usage,
            watchPath: dataDir.path,
            capabilities: capabilities,
            updatedAt: now
        )
    }

    // MARK: - Session details

    private func buildEntry(
        row: [String: Any],
        db: OpenCodeDatabase,
        now: Date,
        dayStart: Date,
        dayStartMS: Int64
    ) -> CacheEntry {
        let sessionID = string(row["id"]) ?? ""
        let directory = string(row["directory"]) ?? ""
        let created = int64(row["time_created"]) ?? 0
        let updated = int64(row["time_updated"]) ?? 0
        let rawTitle = string(row["title"]) ?? ""
        let title = cleanTitle(rawTitle)
        let compactingAt = int64(row["time_compacting"]) ?? 0

        let messages = loadMessages(sessionID: sessionID, db: db)
        let parts = loadParts(sessionID: sessionID, db: db)
        let roleByMessage = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0.role) })
        let lastMessage = messages.first
        let lastUser = messages.first { $0.role == "user" }
        let lastAssistant = messages.first { $0.role == "assistant" }
        let lastUserAt = lastUser?.created

        var lastUserText: String?
        var lastAssistantText: String?
        var actionTool: (String, String?, Int64)?
        var actionDecided = false
        for part in parts {
            let role = roleByMessage[part.messageID] ?? ""
            if part.type == "text", let text = (part.data["text"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                if role == "user", lastUserText == nil {
                    lastUserText = tail(text, 160)
                } else if role == "assistant", lastAssistantText == nil {
                    lastAssistantText = tail(text, 160)
                }
                // The most recent visible part is assistant text: no tool line,
                // but keep scanning for the latest user prompt.
                if !actionDecided, role == "assistant" {
                    actionDecided = true
                }
            }
            if !actionDecided, part.type == "tool", let described = describeTool(part) {
                actionTool = (described.0, described.1, part.created)
                actionDecided = true
            }
        }

        let pendingApproval = parsePermission(
            row["permission"],
            sessionID: sessionID,
            since: Date(ms: updated)
        )

        var turnActive = false
        if pendingApproval != nil {
            turnActive = true
        } else if compactingAt > 0 {
            turnActive = true
        } else if let last = lastMessage {
            if last.role == "assistant" {
                if last.completed == nil {
                    turnActive = true
                } else if last.finish.lowercased().contains("tool") {
                    turnActive = true
                }
            } else if last.role == "user" {
                turnActive = now.timeIntervalSince(Date(ms: last.created)) < 120
            }
        }
        if let toolPart = parts.first(where: { $0.type == "tool" }),
           let state = toolPart.data["state"] as? [String: Any],
           let status = (state["status"] as? String)?.lowercased(),
           status == "running" || status == "pending" {
            turnActive = true
        }

        var lastCompletedAt: Date?
        if pendingApproval == nil, compactingAt == 0,
           lastMessage?.role == "assistant",
           let assistant = lastMessage,
           let completed = assistant.completed,
           !assistant.finish.lowercased().contains("tool") {
            lastCompletedAt = Date(ms: completed)
        }

        var lastErrorAt: Date?
        var lastErrorText: String?
        if let assistant = lastAssistant, lastMessage?.id == assistant.id {
            if let error = assistant.error, !error.isEmpty {
                lastErrorAt = Date(ms: assistant.created)
                lastErrorText = error
                lastCompletedAt = nil
            }
        }

        let tokensThisTurn: Int = {
            guard let lastUserAt else { return 0 }
            return Int(int64(db.rows(
                """
                SELECT COALESCE(SUM(CAST(json_extract(data, '$.tokens.total') AS INTEGER)), 0) AS n
                FROM message
                WHERE session_id = ? AND json_extract(data, '$.role') = 'assistant'
                      AND time_created >= ?
                """,
                [sessionID, lastUserAt]
            ).first?["n"]) ?? 0)
        }()

        let turnNumber = Int(int64(db.rows(
            "SELECT COUNT(*) AS n FROM message WHERE session_id = ? AND json_extract(data, '$.role') = 'user'",
            [sessionID]
        ).first?["n"]) ?? 0)

        let stepNumber: Int = {
            guard let lastUserAt else { return 0 }
            return Int(int64(db.rows(
                """
                SELECT COUNT(*) AS n FROM part
                WHERE session_id = ? AND json_extract(data, '$.type') = 'tool'
                      AND time_created >= ?
                """,
                [sessionID, lastUserAt]
            ).first?["n"]) ?? 0)
        }()

        let todayAggregate = db.rows(
            """
            SELECT COUNT(*) AS calls,
                   COALESCE(SUM(CAST(json_extract(data, '$.tokens.total') AS INTEGER)), 0) AS tokens,
                   COALESCE(SUM(CAST(json_extract(data, '$.cost') AS REAL)), 0) AS cost
            FROM message
            WHERE session_id = ? AND json_extract(data, '$.role') = 'assistant'
                  AND time_created >= ?
            """,
            [sessionID, dayStartMS]
        ).first ?? [:]
        let todayTokensRaw = int64(todayAggregate["tokens"]) ?? 0
        let todayCalls = Int(int64(todayAggregate["calls"]) ?? 0)
        let todayCostRaw = double(todayAggregate["cost"]) ?? 0

        let sessionTokens = (int64(row["tokens_input"]) ?? 0)
            + (int64(row["tokens_output"]) ?? 0)
            + (int64(row["tokens_reasoning"]) ?? 0)
            + (int64(row["tokens_cache_read"]) ?? 0)
            + (int64(row["tokens_cache_write"]) ?? 0)
        let sessionCost = double(row["cost"]) ?? 0
        let createdToday = created >= dayStartMS
        let tokensToday = createdToday ? Int(sessionTokens) : Int(todayTokensRaw)
        let costToday = createdToday ? sessionCost : todayCostRaw

        let cwd = directory
        var snapshot = AgentSession(
            id: sessionID,
            directory: dataDir.path,
            logPath: dbURL.path,
            title: title,
            cwd: cwd,
            workspaceName: cwd.isEmpty ? "OpenCode" : baseName(cwd),
            createdAt: created > 0 ? Date(ms: created) : nil,
            lastEventAt: Date(ms: max(updated, lastMessage?.created ?? 0)),
            fileModifiedAt: Date(ms: updated),
            providerID: id,
            providerName: shortName
        )
        snapshot.turnActive = turnActive
        snapshot.turnStartedAt = lastUserAt.map { Date(ms: $0) }
        snapshot.taskStartedAt = lastUserAt.map { Date(ms: $0) }
        snapshot.turnNumber = turnNumber
        snapshot.stepNumber = stepNumber
        snapshot.lastTurnErrored = lastErrorAt != nil
        snapshot.lastErrorText = lastErrorText
        snapshot.lastCompletedAt = lastCompletedAt
        snapshot.lastErrorAt = lastErrorAt
        snapshot.pendingApproval = pendingApproval
        if let tool = actionTool {
            snapshot.lastToolName = tool.0
            snapshot.lastToolDetail = tool.1
            snapshot.lastToolStartedAt = Date(ms: tool.2)
        }
        snapshot.lastAssistantText = lastAssistantText
        snapshot.lastUserText = lastUserText ?? (title.isEmpty ? nil : rawTitle)
        snapshot.tokensThisTurn = tokensThisTurn
        snapshot.lastEventType = lastMessage.map { "message/\($0.role)" }
            ?? (parts.first.map { "part/\($0.type)" } ?? "session")
        snapshot.derivePhase(now: now)

        log?("opencode session \(sessionID) updated=\(updated) active=\(turnActive) today=\(tokensToday)")
        return CacheEntry(
            updated: updated,
            snapshot: snapshot,
            tokensToday: tokensToday,
            callsToday: todayCalls,
            costToday: costToday
        )
    }

    private func loadMessages(sessionID: String, db: OpenCodeDatabase) -> [MessageInfo] {
        db.rows(
            "SELECT id, data, time_created FROM message WHERE session_id = ? ORDER BY time_created DESC, id DESC LIMIT 8",
            [sessionID]
        ).compactMap { row in
            guard let id = string(row["id"]), let data = jsonObject(row["data"]) else { return nil }
            let time = data["time"] as? [String: Any] ?? [:]
            let tokens = data["tokens"] as? [String: Any] ?? [:]
            let error: String? = {
                if let text = data["error"] as? String, !text.isEmpty { return text }
                if let dict = data["error"] as? [String: Any] {
                    return (dict["message"] as? String) ?? (dict["name"] as? String)
                }
                return nil
            }()
            return MessageInfo(
                id: id,
                role: (data["role"] as? String) ?? "",
                created: int64(time["created"]) ?? int64(row["time_created"]) ?? 0,
                completed: int64(time["completed"]),
                finish: (data["finish"] as? String) ?? "",
                tokens: Int(int64(tokens["total"]) ?? 0),
                cost: double(data["cost"]) ?? 0,
                error: error
            )
        }
    }

    private func loadParts(sessionID: String, db: OpenCodeDatabase) -> [PartInfo] {
        db.rows(
            "SELECT message_id, data, time_created FROM part WHERE session_id = ? ORDER BY time_created DESC, id DESC LIMIT 24",
            [sessionID]
        ).compactMap { row in
            guard let messageID = string(row["message_id"]),
                  let data = jsonObject(row["data"]),
                  let type = data["type"] as? String else { return nil }
            return PartInfo(
                messageID: messageID,
                created: int64(row["time_created"]) ?? 0,
                type: type,
                data: data
            )
        }
    }

    private func describeTool(_ part: PartInfo) -> (String, String?)? {
        let data = part.data
        let name = (data["tool"] as? String)
            ?? (data["name"] as? String)
            ?? "tool"
        let state = data["state"] as? [String: Any] ?? [:]
        let input = (state["input"] as? [String: Any])
            ?? (data["input"] as? [String: Any])
            ?? [:]
        let status = ((state["status"] as? String) ?? (data["status"] as? String) ?? "").lowercased()

        func field(_ keys: String...) -> String? {
            for key in keys {
                if let value = input[key] as? String, !value.isEmpty { return value }
            }
            return nil
        }
        func short(_ value: String, _ limit: Int = 38) -> String {
            tail(value.replacingOccurrences(of: "\n", with: " "), limit)
        }

        let lower = name.lowercased()
        var action = name
        var detail: String?
        switch lower {
        case "bash", "shell":
            action = "跑命令"
            detail = field("description", "command").map { short($0) }
        case "read":
            action = "读文件"
            detail = field("filePath", "file_path", "path").map { baseName($0) }
        case "write":
            action = "写文件"
            detail = field("filePath", "file_path", "path").map { baseName($0) }
        case "edit", "patch":
            action = "改代码"
            detail = field("filePath", "file_path", "path").map { baseName($0) }
        case "grep":
            action = "搜代码"
            detail = field("pattern", "query").map { short($0) }
        case "glob":
            action = "找文件"
            detail = field("pattern").map { short($0) }
        case "webfetch", "web_fetch":
            action = "看网页"
            detail = field("url").flatMap { URL(string: $0)?.host }
        case "task":
            action = "派子代理"
            detail = field("description").map { short($0) }
        case "todowrite", "todo_write":
            action = "写计划"
            detail = field("content").map { short($0) }
        default:
            detail = field("description").map { short($0) }
        }
        if status == "error" || status == "failed" {
            detail = detail.map { "\($0) · 失败" } ?? "失败了"
        }
        return (action, detail)
    }

    // MARK: - Go quota

    private func currentQuotas() -> [UsageQuota] {
        quotaLock.lock()
        defer { quotaLock.unlock() }
        return cachedQuotas
    }

    private func maybeRefreshQuotas(now: Date) {
        guard config.fetchQuotas else { return }
        if UserDefaults.standard.object(forKey: "BlueFish.openCodeQuotas") as? Bool == false {
            return
        }
        quotaLock.lock()
        let shouldStart = !quotaFetchInFlight
            && now.timeIntervalSince(lastQuotaAttempt) >= 120
        if shouldStart {
            quotaFetchInFlight = true
            lastQuotaAttempt = now
        }
        quotaLock.unlock()
        guard shouldStart else { return }

        let reader = OpenCodeQuotaReader(databaseURL: dbURL, log: log)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let quotas = reader.fetchSync(now: Date())
            guard let self else { return }
            self.quotaLock.lock()
            self.cachedQuotas = quotas
            self.quotaFetchInFlight = false
            self.quotaLock.unlock()
        }
    }

    // MARK: - Permission

    private func parsePermission(_ raw: Any?, sessionID: String, since: Date) -> ApprovalRequest? {
        guard !(raw is NSNull) else { return nil }
        var dict: [String: Any]?
        if let text = raw as? String, !text.isEmpty {
            if let data = text.data(using: .utf8) {
                if let object = try? JSONSerialization.jsonObject(with: data) {
                    if let d = object as? [String: Any] {
                        dict = d
                    } else if let list = object as? [[String: Any]] {
                        dict = list.first
                    }
                }
            }
            if dict == nil, !text.isEmpty {
                return ApprovalRequest(id: sessionID, tool: text, reason: "", since: since)
            }
        } else if let d = raw as? [String: Any] {
            dict = d
        }
        guard let dict, !dict.isEmpty else { return nil }
        let tool = (dict["title"] as? String)
            ?? (dict["permission"] as? String)
            ?? (dict["type"] as? String)
            ?? (dict["action"] as? String)
            ?? "操作"
        let reason = (dict["description"] as? String)
            ?? (dict["resource"] as? String)
            ?? (dict["pattern"] as? String)
            ?? ""
        let id = (dict["id"] as? String) ?? sessionID
        return ApprovalRequest(id: id, tool: tool, reason: reason, since: since)
    }

    // MARK: - Helpers

    private func cleanTitle(_ raw: String) -> String {
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { return "" }
        if title.hasPrefix("New session - ") || title == "Untitled" { return "" }
        return title
    }

    private func jsonObject(_ raw: Any?) -> [String: Any]? {
        if let dict = raw as? [String: Any] { return dict }
        guard let text = raw as? String, let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func string(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        return nil
    }

    private func int64(_ value: Any?) -> Int64? {
        if value is NSNull { return nil }
        if let n = value as? Int64 { return n }
        if let n = value as? Int { return Int64(n) }
        if let n = value as? Double { return Int64(n) }
        if let n = value as? NSNumber { return n.int64Value }
        if let s = value as? String { return Int64(s) }
        return nil
    }

    private func double(_ value: Any?) -> Double? {
        if value is NSNull { return nil }
        if let n = value as? Double { return n }
        if let n = value as? Int64 { return Double(n) }
        if let n = value as? Int { return Double(n) }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }
}

// MARK: - Minimal read-only SQLite wrapper

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class OpenCodeDatabase {
    private var handle: OpaquePointer?
    private let log: ((String) -> Void)?

    init?(path: String, log: ((String) -> Void)?) {
        self.log = log
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            log?("opencode db open failed: \(path)")
            if let handle { sqlite3_close(handle) }
            handle = nil
            return nil
        }
        sqlite3_busy_timeout(handle, 150)
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    func rows(_ sql: String, _ bind: [Any] = []) -> [[String: Any]] {
        guard let handle else { return [] }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return [] }
        defer { sqlite3_finalize(statement) }

        for (index, value) in bind.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case let v as Int64:
                sqlite3_bind_int64(statement, position, v)
            case let v as Int:
                sqlite3_bind_int64(statement, position, Int64(v))
            case let v as Double:
                sqlite3_bind_double(statement, position, v)
            case let v as String:
                sqlite3_bind_text(statement, position, v, -1, SQLITE_TRANSIENT)
            default:
                sqlite3_bind_null(statement, position)
            }
        }

        var result: [[String: Any]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String: Any] = [:]
            let count = sqlite3_column_count(statement)
            for index in 0..<count {
                let name = String(cString: sqlite3_column_name(statement, index))
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER:
                    row[name] = sqlite3_column_int64(statement, index)
                case SQLITE_FLOAT:
                    row[name] = sqlite3_column_double(statement, index)
                case SQLITE_TEXT:
                    if let text = sqlite3_column_text(statement, index) {
                        row[name] = String(cString: text)
                    } else {
                        row[name] = ""
                    }
                case SQLITE_NULL:
                    row[name] = NSNull()
                default:
                    row[name] = NSNull()
                }
            }
            result.append(row)
        }
        return result
    }
}


private extension Date {
    init(ms: Int64) {
        self.init(timeIntervalSince1970: Double(ms) / 1000)
    }
}
