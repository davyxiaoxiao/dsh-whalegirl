import Foundation

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

struct SessionSnapshot: Identifiable {
    let id: String
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

struct PlanQuota {
    let provider: String   // display name, e.g. "Go"
    let window: String     // "5h" / "周" / "月"
    let percent: Int
    let resetsAt: Date?
    let sampledAt: Date?

    var label: String { "\(provider) \(window) \(percent)%" }
}

struct DSHStatus {
    var sessions: [SessionSnapshot] = []
    var dshRunning: Bool = false
    var todayCost: Double?
    var todayCalls: Int?
    var todayTokens: Int?
    var planQuotas: [PlanQuota] = []
    var updatedAt: Date = .distantPast

    /// "Go 5h 7% · Go 周 11% · Go 月 5% · 今日 83.9M tok"
    var costLine: String {
        var parts = planQuotas.prefix(3).map(\.label)
        if let tokens = todayTokens, tokens > 0 {
            parts.append("今日 \(compactTokens(tokens)) tok")
        }
        return parts.joined(separator: " · ")
    }

    var visibleSessions: [SessionSnapshot] {
        sessions
            .filter { !$0.isArchived }
            .sorted { a, b in
                if a.phase.rank != b.phase.rank { return a.phase.rank < b.phase.rank }
                return a.lastEventAt > b.lastEventAt
            }
    }

    var recentSessions: [SessionSnapshot] {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        return visibleSessions.filter { $0.lastEventAt > cutoff }
    }

    var attentionSessions: [SessionSnapshot] { recentSessions.filter { $0.phase == .waiting } }
    var workingSessions: [SessionSnapshot] {
        recentSessions.filter {
            ($0.phase == .working || $0.phase == .stalled) && $0.age < 1800
        }
    }
    var errorSessions: [SessionSnapshot] { recentSessions.filter { $0.phase == .error } }
    var doneSessions: [SessionSnapshot] { recentSessions.filter { $0.phase == .done } }

    var primary: SessionSnapshot? {
        recentSessions.max { $0.lastEventAt < $1.lastEventAt }
    }

    var mood: PetMood {
        // No DSH backend: say so, even if the pet still remembers old sessions.
        if !dshRunning { return .offline }
        if !attentionSessions.isEmpty { return .waiting }
        if let err = errorSessions.first, Date().timeIntervalSince(err.lastErrorAt ?? err.lastEventAt) < 45 {
            return .panic
        }
        if !workingSessions.isEmpty { return .working }
        if let done = doneSessions.first, Date().timeIntervalSince(done.lastCompletedAt ?? done.lastEventAt) < 25 {
            return .happy
        }
        if let latest = primary {
            if Date().timeIntervalSince(latest.lastEventAt) > 20 * 60 { return .sleeping }
            return .idle
        }
        return .idle
    }

    var headline: String {
        if let approval = attentionSessions.first {
            return "\(approval.workspaceName) 在等你确认"
        }
        if let err = errorSessions.first, Date().timeIntervalSince(err.lastErrorAt ?? err.lastEventAt) < 300 {
            return "\(err.workspaceName) 出错了"
        }
        if workingSessions.count > 1 { return "\(workingSessions.count) 个任务一起游着" }
        if let working = workingSessions.first {
            return working.actionLine.map { "\(working.workspaceName)：\($0)" } ?? "\(working.workspaceName) 干饭中"
        }
        if let done = doneSessions.first {
            return "\(done.workspaceName) 完成啦"
        }
        if !dshRunning { return "DSH 断连了" }
        return "在海底待命"
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
