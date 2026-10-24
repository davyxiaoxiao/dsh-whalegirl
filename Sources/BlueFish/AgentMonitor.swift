import Foundation

/// Polls every registered adapter on one serial queue and publishes a single
/// `FleetStatus`. Adapters never own timers, so adding one is just a matter of
/// implementing `AgentProvider` and registering it.
final class AgentMonitor {
    struct Config {
        var pollInterval: TimeInterval = 1.5
        var maxSessions = 80
        var log: ((String) -> Void)?
    }

    let providers: [AgentProvider]

    private let config: Config
    private let queue = DispatchQueue(label: "bluefish.agent-monitor", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var isPaused = false

    var onUpdate: ((FleetStatus) -> Void)?

    init(config: Config = Config(), providers: [AgentProvider]? = nil) {
        self.config = config
        self.providers = providers ?? AgentProviderRegistry.makeDefaultProviders(log: config.log)
        self.config.log?("providers=\(self.providers.map(\.id).joined(separator: ","))")
    }

    /// Name used before the first snapshot arrives.
    var watchTargetName: String {
        if providers.count == 1 { return providers[0].shortName }
        return "本地代理"
    }

    func start() {
        queue.async { [weak self] in
            self?.refreshLocked()
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(
            deadline: .now() + config.pollInterval,
            repeating: config.pollInterval,
            leeway: .milliseconds(300)
        )
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
    func refreshNow() -> FleetStatus {
        queue.sync { self.scanLocked() }
    }

    /// Route a session click to the adapter that owns it.
    func openSession(
        _ session: AgentSession,
        currentWorkspace: String?,
        completion: @escaping (SessionOpenResult) -> Void
    ) {
        guard let provider = providers.first(where: { $0.id == session.providerID }) else {
            completion(SessionOpenResult(
                ok: false,
                message: "找不到 \(session.providerName) 的监控器"
            ))
            return
        }
        provider.openSession(session, currentWorkspace: currentWorkspace, completion: completion)
    }

    // MARK: - Queue

    private func refreshLocked() {
        guard !isPaused else { return }
        let status = scanLocked()
        DispatchQueue.main.async { [weak self] in
            self?.onUpdate?(status)
        }
    }

    private func scanLocked() -> FleetStatus {
        let now = Date()
        var status = FleetStatus()
        status.providers = providers.map { provider in
            var result = provider.refresh(now: now)
            // Adapters only need to fill the session fields they know about;
            // stamp the provider identity once here so grouping / jump routing
            // cannot be forgotten by a new adapter.
            for index in result.sessions.indices {
                if result.sessions[index].providerID.isEmpty {
                    result.sessions[index].providerID = provider.id
                }
                if result.sessions[index].providerName.isEmpty {
                    result.sessions[index].providerName = provider.shortName
                }
            }
            return result
        }
        if status.sessions.count > config.maxSessions {
            // Providers already cap themselves; this is a final guard against a
            // future adapter that forgets to.
            for index in status.providers.indices {
                let overflow = max(0, status.sessions.count - config.maxSessions)
                if overflow == 0 { break }
                let keep = max(0, status.providers[index].sessions.count - overflow)
                status.providers[index].sessions = Array(
                    status.providers[index].sessions.sorted { $0.lastEventAt > $1.lastEventAt }.prefix(keep)
                )
            }
        }
        status.updatedAt = now
        return status
    }
}
