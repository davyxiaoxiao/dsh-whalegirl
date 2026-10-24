import Foundation

/// Fetches OpenCode Go plan usage.
///
/// OpenCode stores the Go subscription flag and session cost locally, but the
/// 5h / week / month meters are only rendered by the web console. The console
/// exposes a read-only usage endpoint that accepts the same account token the
/// CLI already stores in `opencode.db`. We use it at most once every two
/// minutes, and only when the account is actually on a Go plan.
///
/// The 5h window is a rolling window here (OpenCode measures from first use),
/// and the month window is the last 30 days (the paid period can start on any
/// day). They are intentionally labelled as approximate; the week window uses
/// the UTC calendar week, which matches OpenCode's `utcCalendarWeek`.
final class OpenCodeQuotaReader {
    private let databaseURL: URL
    private let log: ((String) -> Void)?
    private let session: URLSession
    private let iso: ISO8601DateFormatter

    private static let microCentsPerDollar: Int64 = 100_000_000

    init(databaseURL: URL = OpenCodeProvider.defaultDatabaseURL, log: ((String) -> Void)? = nil) {
        self.databaseURL = databaseURL
        self.log = log
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        config.httpAdditionalHeaders = ["Accept": "application/json"]
        self.session = URLSession(configuration: config)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.iso = formatter
    }

    deinit {
        session.invalidateAndCancel()
    }

    /// Blocking variant, used by the provider's background queue and
    /// `--dump-opencode-quota`.
    func fetchSync(now: Date = Date()) -> [UsageQuota] {
        guard let db = OpenCodeDatabase(path: databaseURL.path, log: log) else { return [] }
        let credentialRows = db.rows(
            """
            SELECT a.access_token AS token, s.active_org_id AS org
            FROM account_state s
            JOIN account a ON a.id = s.active_account_id
            LIMIT 1
            """
        )
        guard let credentials = credentialRows.first,
              let token = credentials["token"] as? String, !token.isEmpty,
              let org = credentials["org"] as? String, !org.isEmpty else {
            log?("opencode quota: no active account")
            return []
        }

        let base = "https://opencode.ai/console/api"
        guard let currentURL = URL(string: "\(base)/orgs/current"),
              let current = getJSON(currentURL, token: token, org: org),
              (current["hasGoSubscription"] as? Bool) == true else {
            log?("opencode quota: no Go subscription")
            return []
        }

        let plan = goPlan()
        let weekStart = utcWeekStart(now)
        let windows: [(String, Date, Int64)] = [
            ("5h", now.addingTimeInterval(-5 * 3600), plan.fiveHour),
            ("周", weekStart, plan.week),
            ("月", now.addingTimeInterval(-30 * 24 * 3600), plan.month)
        ]

        var quotas: [UsageQuota] = []
        for (label, since, limit) in windows {
            guard let used = usedMicroCents(since: since, token: token, org: org) else { continue }
            log?("opencode quota \(label) used=\(used) limit=\(limit)")
            let percent = limit > 0
                ? min(999, max(0, Int((Double(used) / Double(limit) * 100).rounded())))
                : 0
            let resetsAt: Date?
            switch label {
            case "5h": resetsAt = now.addingTimeInterval(5 * 3600)
            case "周": resetsAt = Calendar.utc.date(byAdding: .day, value: 7, to: weekStart)
            default: resetsAt = now.addingTimeInterval(30 * 24 * 3600)
            }
            quotas.append(UsageQuota(
                provider: plan.label,
                window: label,
                percent: percent,
                resetsAt: resetsAt,
                sampledAt: now
            ))
        }
        log?("opencode quota: \(quotas.map(\.label).joined(separator: ", "))")
        return quotas
    }

    // MARK: - HTTP

    private func usedMicroCents(since: Date, token: String, org: String) -> Int64? {
        var components = URLComponents(string: "https://opencode.ai/console/api/usage/summary")
        components?.queryItems = [URLQueryItem(name: "since", value: iso.string(from: since))]
        guard let url = components?.url,
              let json = getJSON(url, token: token, org: org) else { return nil }
        return int64(json["totalCostMicroCents"])
    }

    private func getJSON(_ url: URL, token: String, org: String) -> [String: Any]? {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(org, forHTTPHeaderField: "x-org-id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("whalegirl-openquote/1.0", forHTTPHeaderField: "User-Agent")

        let semaphore = DispatchSemaphore(value: 0)
        var result: [String: Any]?
        var status = 0
        let task = session.dataTask(with: request) { data, response, error in
            if let http = response as? HTTPURLResponse {
                status = http.statusCode
            }
            if error == nil, status == 200, let data {
                result = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
            semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout: .now() + 10) == .timedOut {
            task.cancel()
            log?("opencode quota: request timed out")
        }
        return result
    }

    // MARK: - Plan

    private struct Plan {
        let label: String
        let fiveHour: Int64
        let week: Int64
        let month: Int64
    }

    private func goPlan() -> Plan {
        let raw = (UserDefaults.standard.string(forKey: "BlueFish.openCodePlan")
            ?? ProcessInfo.processInfo.environment["BLUEFISH_OPENCODE_PLAN"]
            ?? "go").lowercased()
        if raw.contains("plus") {
            return Plan(
                label: "Go+",
                fiveHour: 48 * Self.microCentsPerDollar,
                week: 120 * Self.microCentsPerDollar,
                month: 240 * Self.microCentsPerDollar
            )
        }
        return Plan(
            label: "Go",
            fiveHour: 12 * Self.microCentsPerDollar,
            week: 30 * Self.microCentsPerDollar,
            month: 60 * Self.microCentsPerDollar
        )
    }

    private func utcWeekStart(_ date: Date) -> Date {
        let calendar = Calendar.utc
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return calendar.date(from: components) ?? date
    }

    private func int64(_ value: Any?) -> Int64? {
        if let n = value as? Int64 { return n }
        if let n = value as? Int { return Int64(n) }
        if let n = value as? NSNumber { return n.int64Value }
        if let s = value as? String { return Int64(s) }
        return nil
    }
}

private extension Calendar {
    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        calendar.firstWeekday = 2
        return calendar
    }
}
