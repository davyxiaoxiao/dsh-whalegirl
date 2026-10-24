import Foundation

/// What an adapter is able to do. The UI uses this to decide whether to offer
/// "jump to session", "reveal log folder", and similar actions.
struct AgentCapabilities: OptionSet {
    let rawValue: Int

    static let sessions = AgentCapabilities(rawValue: 1 << 0)
    static let usage = AgentCapabilities(rawValue: 1 << 1)
    static let sessionJump = AgentCapabilities(rawValue: 1 << 2)
    static let reveal = AgentCapabilities(rawValue: 1 << 3)

    static let all: AgentCapabilities = [.sessions, .usage, .sessionJump, .reveal]
}

struct SessionOpenResult {
    let ok: Bool
    let message: String
}

/// One monitored coding agent.
///
/// An adapter owns everything agent-specific: where logs live, how to detect a
/// running app, how to translate its events into `AgentSession`, where its
/// cost data comes from, and how to open one of its sessions. The rest of the
/// app only talks to this protocol and to `FleetStatus`.
///
/// `refresh(now:)` is called on the monitor's serial queue and must be
/// synchronous and thread-confined to that queue. `openSession` is UI-facing
/// and may hop to the main queue itself.
protocol AgentProvider: AnyObject {
    /// Stable machine id, e.g. "dsh", "claude-code", "codex".
    var id: String { get }
    /// Full product name for headers ("DeepSeek Harness").
    var displayName: String { get }
    /// Compact name for rows and copy ("DSH").
    var shortName: String { get }
    /// Folder exposed by the "打开目录" button.
    var watchPath: String? { get }
    var capabilities: AgentCapabilities { get }

    func refresh(now: Date) -> ProviderStatus

    func openSession(
        _ session: AgentSession,
        currentWorkspace: String?,
        completion: @escaping (SessionOpenResult) -> Void
    )
}

extension AgentProvider {
    var watchPath: String? { nil }
    var capabilities: AgentCapabilities { [.sessions] }

    func openSession(
        _ session: AgentSession,
        currentWorkspace: String?,
        completion: @escaping (SessionOpenResult) -> Void
    ) {
        completion(SessionOpenResult(
            ok: false,
            message: "\(displayName) 暂不支持跳转到会话"
        ))
    }
}

enum AgentProviderID {
    static let dsh = "dsh"
    static let claudeCode = "claude-code"
    static let codex = "codex"
    static let openCode = "opencode"
}

/// The single place to plug a new agent in.
///
/// To watch Claude Code / Codex later, implement `AgentProvider` in a new file
/// and append it here. Keep DSH first: the pet's copy and the "jump" action use
/// the first provider as the primary target.
enum AgentProviderRegistry {
    static func makeDefaultProviders(log: ((String) -> Void)? = nil) -> [AgentProvider] {
        [
            DSHProvider(log: log),
            CodexProvider(log: log),
            OpenCodeProvider(log: log)

            // AgentProviderID.claudeCode:
            // ClaudeCodeProvider(log: log)
        ]
    }
}
