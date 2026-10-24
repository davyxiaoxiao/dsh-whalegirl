import AppKit
import Foundation

let arguments = CommandLine.arguments

if arguments.contains("--check-update") {
    var finished = false
    UpdateChecker.diagnose { line in
        print(line)
        finished = true
    }
    let deadline = Date().addingTimeInterval(15)
    while !finished, Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }
    if !finished { print("error=timeout") }
    exit(0)
}

if arguments.contains("--dump-codex") {
    guard let index = arguments.firstIndex(of: "--dump-codex"),
          arguments.count > index + 1 else {
        print("usage: WhaleGirl --dump-codex <sessions-dir>")
        exit(2)
    }
    let root = URL(fileURLWithPath: arguments[index + 1])
    let provider = CodexProvider(config: CodexProvider.Config(rootURL: root))
    let status = provider.refresh(now: Date())
    print("provider=\(status.id) running=\(status.running) sessions=\(status.sessions.count)")
    if let usage = status.usage {
        let today = usage.today
        print("usage: tokens=\(today?.tokens.map(compactTokens) ?? "-") calls=\(today?.calls.map(String.init) ?? "-") quotas=\(usage.quotas.count)")
    } else {
        print("usage: -")
    }
    for session in status.sessions {
        let elapsed = session.turnActive ? shortDuration(session.elapsed) : "—"
        print("[\(session.phase.rawValue)] \(session.displayTitle) | \(session.workspaceName) | \(session.lastEventType) | age=\(Int(session.age))s | turn=\(elapsed) | tokens=\(compactTokens(session.tokensThisTurn)) | step=\(session.stepNumber) | \(session.actionLine ?? "-")")
    }
    exit(0)
}

if arguments.contains("--dump-opencode-quota") {
    let index = arguments.firstIndex(of: "--dump-opencode-quota")
    let db: URL
    if let index, arguments.count > index + 1, !arguments[index + 1].hasPrefix("-") {
        db = URL(fileURLWithPath: arguments[index + 1])
    } else {
        db = OpenCodeProvider.defaultDatabaseURL
    }
    let reader = OpenCodeQuotaReader(databaseURL: db, log: { text in
        if arguments.contains("--verbose") {
            FileHandle.standardError.write(("• " + text + "\n").data(using: .utf8)!)
        }
    })
    let quotas = reader.fetchSync(now: Date())
    if quotas.isEmpty {
        print("no OpenCode Go quota data")
    } else {
        for quota in quotas {
            print("\(quota.label) | reset=\(quota.resetsAt.map { ISO8601DateFormatter().string(from: $0) } ?? "-")")
        }
    }
    exit(0)
}

if arguments.contains("--dump-opencode") {
    let index = arguments.firstIndex(of: "--dump-opencode")
    let config: OpenCodeProvider.Config
    if let index, arguments.count > index + 1, !arguments[index + 1].hasPrefix("-") {
        config = OpenCodeProvider.Config(databaseURL: URL(fileURLWithPath: arguments[index + 1]))
    } else {
        config = OpenCodeProvider.Config()
    }
    let provider = OpenCodeProvider(config: config)
    let status = provider.refresh(now: Date())
    print("provider=\(status.id) running=\(status.running) sessions=\(status.sessions.count)")
    if let usage = status.usage {
        print("usage: tokens=\(usage.today?.tokens.map(compactTokens) ?? "-") calls=\(usage.today?.calls.map(String.init) ?? "-") costUSD=\(usage.today?.costUSD.map { String(format: "%.4f", $0) } ?? "-") quotas=\(usage.quotas.map(\.label).joined(separator: ", "))")
    } else {
        print("usage: -")
    }
    for session in status.sessions {
        let elapsed = session.turnActive ? shortDuration(session.elapsed) : "—"
        print("[\(session.phase.rawValue)] \(session.displayTitle) | \(session.workspaceName) | \(session.lastEventType) | age=\(Int(session.age))s | turn=\(elapsed) | tokens=\(compactTokens(session.tokensThisTurn)) | step=\(session.stepNumber) | \(session.actionLine ?? "-")")
    }
    exit(0)
}

if arguments.contains("--dump") {
    var config = AgentMonitor.Config()
    config.log = { text in
        if arguments.contains("--verbose") {
            FileHandle.standardError.write(("• " + text + "\n").data(using: .utf8)!)
        }
    }
    let monitor = AgentMonitor(
        config: config,
        providers: AgentProviderRegistry.makeDefaultProviders(log: config.log)
    )
    let status = monitor.refreshNow()
    let providerList = status.providers
        .map { "\($0.id):\($0.running ? "on" : "off")" }
        .joined(separator: ",")
    print("providers=\(providerList) mood=\(status.mood.rawValue) cost=\(status.todayCost.map { String(format: "%.4f", $0) } ?? "-") calls=\(status.todayCalls.map(String.init) ?? "-")")
    let tokens = status.todayTokens.map { compactTokens($0) } ?? "-"
    print("cost: today=\(tokens) tok | \(status.costLine.isEmpty ? "no usage data" : status.costLine)")

    for provider in status.providers {
        let usage = provider.usage.map { usage -> String in
            let today = usage.today.map { totals in
                "cost=\(totals.costCNY.map { String(format: "%.2f", $0) } ?? "-") tokens=\(totals.tokens.map(compactTokens) ?? "-") calls=\(totals.calls.map(String.init) ?? "-")"
            } ?? "-"
            return "today[\(today)] quotas=\(usage.quotas.count) source=\(usage.sourceLabel ?? "-")"
        } ?? "-"
        print("[provider] \(provider.id) \(provider.shortName) running=\(provider.running) sessions=\(provider.sessions.count) usage=\(usage)")
    }

    for session in status.recentSessions {
        let elapsed = session.turnActive ? shortDuration(session.elapsed) : "—"
        print("[\(session.phase.rawValue)] \(session.providerName) | \(session.displayTitle) | \(session.workspaceName) | \(session.lastEventType) | age=\(Int(session.age))s | turn=\(elapsed) | tokens=\(compactTokens(session.tokensThisTurn)) | jobs=\(session.runningJobs.count) | approval=\(session.pendingApproval?.tool ?? "-") | \(session.actionLine ?? "-")")
    }
    exit(0)
}


let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let delegate = AppDelegate()
application.delegate = delegate
application.run()
