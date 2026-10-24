import Foundation

// MARK: - Session primitives

struct ApprovalRequest {
    let id: String
    let tool: String
    let reason: String
    let since: Date
}

struct JobInfo {
    let id: String
    let label: String
    let kind: String
    let startedAt: Date
}

/// Provider-neutral view of one agent session.
///
/// The fields mirror what the desktop pet needs to answer three questions:
/// what is running, who is waiting for the user, and how long / how much it
/// has cost. Every adapter (DSH, Claude Code, Codex, …) fills the same shape,
/// so the task board and the bubble do not need to know where it came from.
struct AgentSession: Identifiable {
    /// The agent's own session id (DSH uses `session-…`, Claude a UUID, …).
    let id: String

    /// Which adapter produced this session. `providerName` is the short name
    /// shown in the UI ("DSH", "Claude", "Codex").
    var providerID: String = ""
    var providerName: String = ""

    let directory: String
    let logPath: String

    var title: String
    var cwd: String
    var workspaceName: String
    var createdAt: Date?
    var lastEventAt: Date
    var fileModifiedAt: Date

    var turnActive: Bool = false
    var turnStartedAt: Date?
    var taskStartedAt: Date?
    var turnNumber: Int = 0
    var stepNumber: Int = 0
    var lastTurnErrored: Bool = false
    var lastErrorText: String?
    var lastCompletedAt: Date?
    var lastErrorAt: Date?
    var pendingApproval: ApprovalRequest?
    var lastToolName: String?
    var lastToolDetail: String?
    var lastToolStartedAt: Date?
    var lastAssistantText: String?
    var lastUserText: String?
    var tokensThisTurn: Int = 0
    var runningJobs: [JobInfo] = []
    var deliverables: [String] = []
    var lastEventType: String = ""
    var isArchived: Bool = false
    var phase: SessionPhase = .idle

    init(
        id: String,
        directory: String,
        logPath: String,
        title: String,
        cwd: String,
        workspaceName: String,
        createdAt: Date?,
        lastEventAt: Date,
        fileModifiedAt: Date,
        providerID: String = "",
        providerName: String = ""
    ) {
        self.id = id
        self.providerID = providerID
        self.providerName = providerName
        self.directory = directory
        self.logPath = logPath
        self.title = title
        self.cwd = cwd
        self.workspaceName = workspaceName
        self.createdAt = createdAt
        self.lastEventAt = lastEventAt
        self.fileModifiedAt = fileModifiedAt
    }

    /// Provider-scoped identity. Raw ids can collide across agents.
    var uid: String { "\(providerID)/\(id)" }

    var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        if let text = lastUserText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return tail(text.replacingOccurrences(of: "\n", with: " "), 42)
        }
        return workspaceName
    }

    var shortID: String { String(id.replacingOccurrences(of: "session-", with: "").prefix(8)) }

    var isLive: Bool { Date().timeIntervalSince(lastEventAt) < 120 }

    var elapsed: TimeInterval {
        if turnActive {
            if let task = taskStartedAt, task <= lastEventAt {
                return max(0, Date().timeIntervalSince(task))
            }
            if let started = turnStartedAt { return max(0, Date().timeIntervalSince(started)) }
            return 0
        }
        if let ended = lastCompletedAt {
            let start = taskStartedAt ?? turnStartedAt ?? ended
            return max(0, ended.timeIntervalSince(start))
        }
        return 0
    }

    var age: TimeInterval { Date().timeIntervalSince(lastEventAt) }

    var actionLine: String? {
        if let approval = pendingApproval { return "等待确认 \(approval.tool)" }
        if let tool = lastToolName {
            if let detail = lastToolDetail, !detail.isEmpty { return "\(tool) · \(detail)" }
            return tool
        }
        return lastAssistantText
    }

    mutating func derivePhase(now: Date = Date()) {
        if pendingApproval != nil, turnActive {
            phase = .waiting
            return
        }
        if turnActive {
            if !runningJobs.isEmpty {
                phase = .working
            } else {
                phase = now.timeIntervalSince(lastEventAt) > 360 ? .stalled : .working
            }
            return
        }
        if let errorAt = lastErrorAt, now.timeIntervalSince(errorAt) < 180 {
            phase = .error
            return
        }
        if let doneAt = lastCompletedAt,
           now.timeIntervalSince(doneAt) < 120,
           now.timeIntervalSince(lastEventAt) > 1.6 {
            phase = .done
            return
        }
        phase = .idle
    }
}

// MARK: - Usage / cost

/// The unit every adapter reports its spend in. Agents that only expose token
/// counts leave `costCNY` empty; the task board then shows tokens instead of
/// pretending to know a price.
struct UsageTotals {
    var costCNY: Double?
    var costUSD: Double? = nil
    var calls: Int?
    var tokens: Int?

    var isEmpty: Bool {
        costCNY == nil && costUSD == nil && calls == nil && tokens == nil
    }
}

/// One quota window reported by an agent or by a metering plugin.
struct UsageQuota {
    /// Display label of the quota's owner, e.g. "Go".
    var provider: String
    /// "5h" / "周" / "月".
    var window: String
    var percent: Int
    var resetsAt: Date?
    var sampledAt: Date?

    var label: String { "\(provider) \(window) \(percent)%" }
}

/// Everything one adapter knows about cost / quota right now.
struct ProviderUsage {
    var providerID: String
    var providerName: String
    var today: UsageTotals?
    var quotas: [UsageQuota] = []
    /// Human-readable data source, e.g. "dsh-cost-meter".
    var sourceLabel: String?

    var isEmpty: Bool {
        (today?.isEmpty ?? true) && quotas.isEmpty
    }
}

// MARK: - Provider status

/// One adapter's contribution to the fleet snapshot.
struct ProviderStatus: Identifiable {
    let id: String
    var name: String
    var shortName: String
    var running: Bool
    var sessions: [AgentSession] = []
    var usage: ProviderUsage?
    var watchPath: String?
    var capabilities: AgentCapabilities = [.sessions]
    var updatedAt: Date = Date()
    /// Optional diagnostic shown by `--dump` / future settings UI.
    var note: String?

    var isAvailable: Bool { running || !sessions.isEmpty }
}

// MARK: - Fleet snapshot

/// Aggregate of every registered adapter. The UI only consumes this type.
struct FleetStatus {
    var providers: [ProviderStatus] = []
    var updatedAt: Date = .distantPast

    var sessions: [AgentSession] { providers.flatMap(\.sessions) }
    var runningProviders: [ProviderStatus] { providers.filter(\.running) }
    var anyRunning: Bool { providers.contains(where: \.running) }

    var primaryProvider: ProviderStatus? { runningProviders.first ?? providers.first }

    /// Name used in copy such as "DSH 断连了".
    var watchTargetName: String {
        if providers.count == 1 { return providers[0].shortName }
        if runningProviders.count == 1 { return runningProviders[0].shortName }
        return "本地代理"
    }

    var usageSources: [ProviderUsage] {
        providers.compactMap(\.usage).filter { !$0.isEmpty }
    }

    var planQuotas: [UsageQuota] { usageSources.flatMap(\.quotas) }

    var todayCost: Double? {
        let values = usageSources.compactMap { $0.today?.costCNY }
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    var todayCostUSD: Double? {
        let values = usageSources.compactMap { $0.today?.costUSD }
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    var todayCalls: Int? {
        let values = usageSources.compactMap { $0.today?.calls }
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    var todayTokens: Int? {
        let values = usageSources.compactMap { $0.today?.tokens }
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    /// "Go 5h 7% · Go 周 11% · Go 月 5% · 今日 83.9M tok"
    var costLine: String {
        let sources = usageSources
        let multiSource = sources.count > 1
        // Round-robin across providers so one agent with three windows does not
        // hide another agent's quota in the shared bubble.
        var quotas: [(UsageQuota, ProviderUsage)] = []
        let depth = sources.map(\.quotas.count).max() ?? 0
        for index in 0..<depth {
            for usage in sources where index < usage.quotas.count {
                quotas.append((usage.quotas[index], usage))
            }
        }
        var parts = quotas.map { quota, usage in
            multiSource ? "\(usage.providerName) \(quota.label)" : quota.label
        }
        if parts.count > 3 { parts = Array(parts.prefix(3)) }
        if let tokens = todayTokens, tokens > 0 {
            parts.append("今日 \(compactTokens(tokens)) tok")
        }
        return parts.joined(separator: " · ")
    }

    var visibleSessions: [AgentSession] {
        sessions
            .filter { !$0.isArchived }
            .sorted { a, b in
                if a.phase.rank != b.phase.rank { return a.phase.rank < b.phase.rank }
                return a.lastEventAt > b.lastEventAt
            }
    }

    var recentSessions: [AgentSession] {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        return visibleSessions.filter { $0.lastEventAt > cutoff }
    }

    /// Sessions whose adapter is currently alive. Mood / headline should not
    /// celebrate a task owned by an agent that has quit.
    var activeSessions: [AgentSession] {
        let running = Set(runningProviders.map(\.id))
        return recentSessions.filter { running.contains($0.providerID) }
    }

    var attentionSessions: [AgentSession] { activeSessions.filter { $0.phase == .waiting } }
    var workingSessions: [AgentSession] {
        recentSessions.filter {
            ($0.phase == .working || $0.phase == .stalled) && $0.age < 1800
        }
    }
    var errorSessions: [AgentSession] { recentSessions.filter { $0.phase == .error } }
    var doneSessions: [AgentSession] { recentSessions.filter { $0.phase == .done } }

    var primary: AgentSession? {
        activeSessions.max { $0.lastEventAt < $1.lastEventAt }
    }

    /// "dshpeg" for a single agent, "Claude · dshpeg" when several are watched.
    func sessionContext(_ session: AgentSession) -> String {
        if providers.count > 1, !session.providerName.isEmpty {
            return "\(session.providerName) · \(session.workspaceName)"
        }
        return session.workspaceName
    }

    var mood: PetMood {
        // No adapter alive: say so, even if sessions from earlier are cached.
        if !anyRunning { return .offline }
        let live = activeSessions
        if live.contains(where: { $0.phase == .waiting }) { return .waiting }
        if let err = live.first(where: { $0.phase == .error }),
           Date().timeIntervalSince(err.lastErrorAt ?? err.lastEventAt) < 45 {
            return .panic
        }
        if live.contains(where: { ($0.phase == .working || $0.phase == .stalled) && $0.age < 1800 }) {
            return .working
        }
        if let done = live.first(where: { $0.phase == .done }),
           Date().timeIntervalSince(done.lastCompletedAt ?? done.lastEventAt) < 25 {
            return .happy
        }
        if let latest = live.max(by: { $0.lastEventAt < $1.lastEventAt }) {
            if Date().timeIntervalSince(latest.lastEventAt) > 20 * 60 { return .sleeping }
            return .idle
        }
        return .idle
    }

    /// Mood with the agent's name attached ("DSH 断连" / "Codex 断连").
    var moodText: String {
        mood == .offline ? "\(watchTargetName) 断连" : mood.title
    }

    var headline: String {
        if let approval = attentionSessions.first {
            return "\(sessionContext(approval)) 在等你确认"
        }
        if let err = errorSessions.first, Date().timeIntervalSince(err.lastErrorAt ?? err.lastEventAt) < 300 {
            return "\(sessionContext(err)) 出错了"
        }
        if workingSessions.count > 1 { return "\(workingSessions.count) 个任务一起游着" }
        if let working = workingSessions.first {
            return working.actionLine.map { "\(sessionContext(working))：\($0)" } ?? "\(sessionContext(working)) 干饭中"
        }
        if let done = doneSessions.first {
            return "\(sessionContext(done)) 完成啦"
        }
        if !anyRunning { return "\(watchTargetName) 断连了" }
        return "在海底待命"
    }

    // MARK: Card copy

    var subtitle: String {
        if providers.isEmpty { return "本地监控" }
        if providers.count == 1 {
            let p = providers[0]
            return "\(p.name) · \(p.running ? "本地监控" : "已断连")"
        }
        let online = runningProviders.count
        if online == 0 { return "全部代理已断连" }
        // The channel tabs carry per-provider counts; keep the header compact.
        return "\(online)/\(providers.count) 个代理在线"
    }

    var footerText: String {
        let jumpProviders = providers.filter { $0.capabilities.contains(.sessionJump) }
        if !providers.isEmpty, jumpProviders.count == providers.count {
            let names = jumpProviders.map(\.shortName).joined(separator: " / ")
            return "点击会话跳到 \(names) · 仅读取本地日志"
        }
        return "仅读取本地日志 · 每 1.5s 刷新"
    }

    var revealPath: String? {
        primaryProvider?.watchPath ?? providers.compactMap(\.watchPath).first
    }

    /// Narrow the whole snapshot to one channel. `nil` keeps every provider.
    /// Computed properties (stats, usage, mood, copy) automatically follow.
    func filtered(to providerID: String?) -> FleetStatus {
        guard let providerID else { return self }
        var copy = self
        copy.providers = providers.filter { $0.id == providerID }
        return copy
    }
}

extension SessionPhase {
    var isAttention: Bool { self == .waiting || self == .error || self == .stalled }

    /// Lower rank sorts first on the task board.
    var rank: Int {
        switch self {
        case .waiting: return 0
        case .working: return 1
        case .stalled: return 2
        case .error: return 3
        case .done: return 4
        case .idle: return 5
        }
    }
}
