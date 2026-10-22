import AppKit
import Foundation

let arguments = CommandLine.arguments

if arguments.contains("--dump") {
    var config = DSHMonitor.Config()
    config.log = { text in
        if arguments.contains("--verbose") { FileHandle.standardError.write(("• " + text + "\n").data(using: .utf8)!) }
    }
    let monitor = DSHMonitor(config: config)
    let status = monitor.refreshNow()
    print("dshRunning=\(status.dshRunning) mood=\(status.mood.rawValue) cost=\(status.todayCost.map { String(format: "%.4f", $0) } ?? "-") calls=\(status.todayCalls.map(String.init) ?? "-")")
    let tokens = status.todayTokens.map { compactTokens($0) } ?? "-"
    print("cost: today=\(tokens) tok | \(status.costLine.isEmpty ? "no plan data" : status.costLine)")
    for session in status.recentSessions {
        let elapsed = session.turnActive ? shortDuration(session.elapsed) : "—"
        print("[\(session.phase.rawValue)] \(session.displayTitle) | \(session.workspaceName) | \(session.lastEventType) | age=\(Int(session.age))s | turn=\(elapsed) | tokens=\(compactTokens(session.tokensThisTurn)) | jobs=\(session.runningJobs.count) | approval=\(session.pendingApproval?.tool ?? "-") | \(session.actionLine ?? "-")")
    }
    exit(0)
}


let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let delegate = AppDelegate()
application.delegate = delegate
application.run()
