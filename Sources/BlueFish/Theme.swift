import AppKit

// MARK: - Colors & fonts

enum Theme {
    static let ink = NSColor(srgbRed: 0.79, green: 0.90, blue: 1.00, alpha: 1.0)
    static let muted = NSColor(srgbRed: 0.58, green: 0.70, blue: 0.86, alpha: 1.0)
    static let deep = NSColor(srgbRed: 0.035, green: 0.075, blue: 0.18, alpha: 1.0)
    static let navy = NSColor(srgbRed: 0.05, green: 0.12, blue: 0.27, alpha: 1.0)
    static let cyan = NSColor(srgbRed: 0.36, green: 0.85, blue: 1.00, alpha: 1.0)
    static let blue = NSColor(srgbRed: 0.35, green: 0.60, blue: 1.00, alpha: 1.0)
    static let amber = NSColor(srgbRed: 1.00, green: 0.76, blue: 0.32, alpha: 1.0)
    static let red = NSColor(srgbRed: 1.00, green: 0.42, blue: 0.48, alpha: 1.0)
    static let green = NSColor(srgbRed: 0.45, green: 0.93, blue: 0.68, alpha: 1.0)
    static let violet = NSColor(srgbRed: 0.70, green: 0.62, blue: 1.00, alpha: 1.0)

    static let panelFill = NSColor(srgbRed: 0.045, green: 0.10, blue: 0.22, alpha: 0.94)
    static let panelStroke = NSColor(srgbRed: 0.36, green: 0.72, blue: 1.00, alpha: 0.22)
    static let rowFill = NSColor(srgbRed: 0.10, green: 0.20, blue: 0.38, alpha: 0.42)

    static func rounded(_ size: CGFloat, _ weight: NSFont.Weight = .medium) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if let desc = base.fontDescriptor.withDesign(.rounded),
           let font = NSFont(descriptor: desc, size: size) {
            return font
        }
        return base
    }

    static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .medium) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    /// One accent per monitored channel, used by the task-board filter.
    static func providerAccent(_ id: String?) -> NSColor {
        switch id {
        case nil, AgentProviderID.dsh: return cyan
        case AgentProviderID.codex: return violet
        case AgentProviderID.claudeCode: return amber
        case AgentProviderID.openCode: return blue
        default: return cyan
        }
    }
}

// MARK: - Mood

enum PetMood: String {
    case offline
    case sleeping
    case idle
    case working
    case waiting
    case happy
    case panic

    var spriteName: String? {
        switch self {
        case .working: return "pet_work"
        case .waiting: return "pet_idle"
        case .happy: return "pet_happy"
        case .panic: return "pet_panic"
        case .idle, .sleeping, .offline: return "pet_idle"
        }
    }

    var tint: NSColor {
        switch self {
        case .offline: return Theme.muted
        case .sleeping: return Theme.violet
        case .idle: return Theme.cyan
        case .working: return Theme.blue
        case .waiting: return Theme.amber
        case .happy: return Theme.green
        case .panic: return Theme.red
        }
    }

    var title: String {
        switch self {
        case .offline: return "断连"
        case .sleeping: return "呼呼大睡"
        case .idle: return "待命中"
        case .working: return "干饭中"
        case .waiting: return "等你确认"
        case .happy: return "完成啦"
        case .panic: return "出错了"
        }
    }

    var symbol: String {
        switch self {
        case .offline: return "wifi.slash"
        case .sleeping: return "moon.zzz.fill"
        case .idle: return "cup.and.saucer.fill"
        case .working: return "gearshape.2.fill"
        case .waiting: return "hand.raised.fill"
        case .happy: return "sparkles"
        case .panic: return "exclamationmark.triangle.fill"
        }
    }
}

enum SessionPhase: String {
    case idle
    case working
    case waiting
    case stalled
    case done
    case error

    var label: String {
        switch self {
        case .idle: return "空闲"
        case .working: return "干饭中"
        case .waiting: return "待确认"
        case .stalled: return "疑似卡住"
        case .done: return "已完成"
        case .error: return "失败"
        }
    }

    var color: NSColor {
        switch self {
        case .idle: return Theme.muted
        case .working: return Theme.cyan
        case .waiting: return Theme.amber
        case .stalled: return Theme.amber
        case .done: return Theme.green
        case .error: return Theme.red
        }
    }

    var symbol: String {
        switch self {
        case .idle: return "moon.fill"
        case .working: return "waveform.path.ecg"
        case .waiting: return "hand.raised.fill"
        case .stalled: return "hourglass"
        case .done: return "checkmark.circle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    var mood: PetMood {
        switch self {
        case .working, .stalled: return .working
        case .waiting: return .waiting
        case .done: return .happy
        case .error: return .panic
        case .idle: return .idle
        }
    }
}

// MARK: - Formatting

func shortDuration(_ interval: TimeInterval) -> String {
    if interval < 0 { return "0s" }
    let s = Int(interval.rounded())
    if s < 60 { return "\(s)s" }
    let m = s / 60
    if m < 60 { return "\(m)m\(s % 60 < 10 ? "0" : "")\(s % 60)s" }
    let h = m / 60
    return "\(h)h\(m % 60 < 10 ? "0" : "")\(m % 60)m"
}

func clockString(_ date: Date?) -> String {
    guard let date else { return "—" }
    let f = DateFormatter()
    f.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm:ss" : "MM-dd HH:mm"
    return f.string(from: date)
}

func compactTokens(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
    if n >= 1000 { return String(format: "%.1fk", Double(n) / 1000) }
    return "\(n)"
}

func relativeAge(_ date: Date) -> String {
    let delta = Date().timeIntervalSince(date)
    if delta < 60 { return "刚刚" }
    if delta < 3600 { return "\(Int(delta / 60)) 分钟前" }
    if delta < 86400 { return "\(Int(delta / 3600)) 小时前" }
    return "\(Int(delta / 86400)) 天前"
}

func tail(_ s: String, _ count: Int) -> String {
    guard s.count > count else { return s }
    return String(s.prefix(count - 1)) + "…"
}

func baseName(_ path: String) -> String {
    let name = (path as NSString).lastPathComponent
    return name.isEmpty ? path : name
}

func shortenPath(_ path: String) -> String {
    let home = NSHomeDirectory()
    if path.hasPrefix(home) {
        return "~" + path.dropFirst(home.count)
    }
    return path
}
