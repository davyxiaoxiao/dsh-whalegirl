import Foundation

struct UsageReading {
    var today: UsageTotals
    var quotas: [UsageQuota]
    var sourceLabel: String

    var isEmpty: Bool {
        today.isEmpty && quotas.isEmpty
    }
}

/// One source of cost / quota data. Adapters can read a ledger, an API dump,
/// or sum token usage from their own logs; the task board only sees the
/// normalized `UsageReading`.
protocol UsageReader: AnyObject {
    var sourceLabel: String { get }
    func read(now: Date) -> UsageReading?
}

/// Reads `dsh-cost-meter`'s local ledger. This is DSH-specific data, but the
/// reader is a standalone component so a future adapter can reuse it or swap
/// in its own reader without touching the UI.
final class CostMeterLedgerReader: UsageReader {
    let sourceLabel = "dsh-cost-meter"

    private let url: URL
    private let refreshInterval: TimeInterval
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    private var lastReadAt: Date = .distantPast
    private var hasLoaded = false
    private var cached: UsageReading?

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

    init(
        url: URL? = nil,
        refreshInterval: TimeInterval = 20
    ) {
        self.url = url ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh/storages/cost-meter/ledger.json")
        self.refreshInterval = refreshInterval
    }

    func read(now: Date) -> UsageReading? {
        if hasLoaded, now.timeIntervalSince(lastReadAt) < refreshInterval {
            return cached
        }
        hasLoaded = true
        lastReadAt = now
        cached = load(now: now)
        return cached
    }

    private func load(now: Date) -> UsageReading? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        var today = UsageTotals()
        if let days = obj["days"] as? [String: Any],
           let day = days[dateFormatter.string(from: now)] as? [String: Any] {
            today.costCNY = (day["costCny"] as? NSNumber)?.doubleValue ?? (day["costCny"] as? Double)
            today.calls = (day["calls"] as? NSNumber)?.intValue ?? (day["calls"] as? Int)
            let fields = ["input", "output", "cacheRead", "cacheWrite", "reasoning"]
            today.tokens = fields.reduce(0) { partial, key in
                partial + ((day[key] as? NSNumber)?.intValue ?? 0)
            }
        }

        return UsageReading(
            today: today,
            quotas: parsePlanQuotas(obj["planSamples"]),
            sourceLabel: sourceLabel
        )
    }

    /// dsh-cost-meter keeps one sample per quota window:
    ///   planSamples.go.fiveHour[] = { t, p, lt, lc, r, s }
    /// where p is the provider-reported percentage, r the reset time and
    /// lt / lc the locally counted tokens / cost at sample time.
    private func parsePlanQuotas(_ raw: Any?) -> [UsageQuota] {
        guard let providers = raw as? [String: Any] else { return [] }
        let keys = providers.keys.sorted { a, b in
            if a == "go" { return true }
            if b == "go" { return false }
            return a < b
        }
        let windowNames: [(String, String)] = [("fiveHour", "5h"), ("weekly", "周"), ("monthly", "月")]
        var quotas: [UsageQuota] = []
        for providerKey in keys {
            guard let windows = providers[providerKey] as? [String: Any] else { continue }
            let provider = planProviderLabel(providerKey)
            var providerQuotas: [UsageQuota] = []
            for (name, label) in windowNames {
                guard let samples = windows[name] as? [[String: Any]] else { continue }
                guard let latest = samples.last(where: { ($0["p"] as? NSNumber) != nil }) ?? samples.last else { continue }
                let percent = (latest["p"] as? NSNumber)?.intValue ?? 0
                let resetRaw = latest["r"] as? String
                let reset = resetRaw.flatMap { Self.isoFractional.date(from: $0) ?? Self.isoPlain.date(from: $0) }
                providerQuotas.append(UsageQuota(
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

    private func dateFromMS(_ v: Any?) -> Date? {
        if let n = v as? NSNumber { return Date(timeIntervalSince1970: n.doubleValue / 1000) }
        if let n = v as? Double { return Date(timeIntervalSince1970: n / 1000) }
        if let n = v as? Int { return Date(timeIntervalSince1970: Double(n) / 1000) }
        if let s = v as? String, let n = Double(s) { return Date(timeIntervalSince1970: n / 1000) }
        return nil
    }
}
