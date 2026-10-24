import AppKit

enum SnapshotRunner {
    private static var window: NSWindow?
    private static var card: StatusCardController?

    static func run(directory: String, scale: CGFloat = 1) {
        let url = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        let size = PetLayout.panelSize(for: scale)
        let stage = PetStageView(frame: NSRect(origin: .zero, size: size))
        stage.setSizeScale(scale)
        let w = NSWindow(
            contentRect: stage.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.contentView = stage
        w.setFrameOrigin(NSPoint(x: 80, y: 80))
        w.orderFrontRegardless()
        window = w

        let cardController = StatusCardController()
        card = cardController
        cardController.update(mockStatus())
        if let fake = UpdateChecker.fakeVersion() {
            cardController.updateUpdateState(.available(.fake(version: fake)))
        }
        cardController.show(relativeTo: NSRect(x: 100, y: 100, width: size.width, height: size.height))

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            let shots: [(String, PetMood, String, String, NSColor, Bool)] = [
                ("01_idle", .idle, "待命中", "DSH 在海底待命", Theme.cyan, false),
                ("02_working", .working, "跑命令 · npm test", "dshpeg · 已经游了 2m14s", Theme.cyan, false),
                ("03_waiting", .waiting, "有任务在等你确认", "dshpeg · 需要你放行 bash 命令", Theme.amber, true),
                ("04_happy", .happy, "搞定啦！", "小红书文案 · 用了 1m42s", Theme.green, true),
                ("05_panic", .panic, "呜…出事了", "saas-cloud：连接超时，这轮没有跑完", Theme.red, true),
                ("06_sleeping", .sleeping, "呼…呼…", "两个小时没有新任务了", Theme.violet, false),
                ("07_offline", .offline, "DSH 断连", "后端退出了 · 桌宠会在这里等你", Theme.muted, false)
            ]

            for (name, mood, chipText, detail, accent, bubble) in shots {
                stage.sprite.setMood(mood, animated: false)
                if bubble {
                    stage.showBubble(title: chipText, detail: detail, accent: accent, autoHide: nil)
                    stage.bubble.alphaValue = 1
                    stage.bubble.isHidden = false
                } else {
                    stage.hideBubble()
                    stage.showChip(chipText, accent: accent, pulse: mood == .waiting)
                }
                stage.layoutSubtreeIfNeeded()
                render(stage, to: url.appendingPathComponent("\(name).png"))
            }

            stage.showChip("走路中 · 放开我就停下", accent: Theme.cyan, pulse: false)
            stage.sprite.startWalking()
            stage.layoutSubtreeIfNeeded()
            render(stage, to: url.appendingPathComponent("09_walk.png"))
            stage.sprite.stopWalking()

            stage.showBubble(
                title: "蓝色肥鱼桌面任务监控",
                detail: "跑命令 · swift build",
                meta: "已跑 2m15s · 第 4 步 · 后台 1 个",
                cost: "Go 5h 7% · Go 周 11% · Go 月 5% · 今日 85.9M tok",
                accent: Theme.cyan,
                autoHide: nil
            )
            stage.bubble.alphaValue = 1
            stage.bubble.isHidden = false
            stage.layoutSubtreeIfNeeded()
            render(stage, to: url.appendingPathComponent("10_working_bubble.png"))

            if let content = cardController.panel.contentView {
                content.layoutSubtreeIfNeeded()
                render(content, to: url.appendingPathComponent("08_card.png"), scale: 2)

                cardController.selectProvider(AgentProviderID.codex)
                content.layoutSubtreeIfNeeded()
                render(content, to: url.appendingPathComponent("08b_card_codex.png"), scale: 2)

                cardController.selectProvider(AgentProviderID.openCode)
                content.layoutSubtreeIfNeeded()
                render(content, to: url.appendingPathComponent("08c_card_opencode.png"), scale: 2)
                cardController.selectProvider(nil)
            }
            print("snapshots written to \(url.path)")
            NSApp.terminate(nil)
        }
    }

    private static func render(_ view: NSView, to url: URL, scale: CGFloat = 2) {
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(bounds.width * scale),
                pixelsHigh: Int(bounds.height * scale),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
              ) else { return }
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }

    private static func mockStatus() -> FleetStatus {
        var dshUsage = ProviderUsage(
            providerID: AgentProviderID.dsh,
            providerName: "DSH",
            today: UsageTotals(costCNY: 4.53, calls: 116, tokens: 85_900_000),
            quotas: [
                UsageQuota(provider: "Go", window: "5h", percent: 7, resetsAt: nil, sampledAt: Date()),
                UsageQuota(provider: "Go", window: "周", percent: 11, resetsAt: nil, sampledAt: Date()),
                UsageQuota(provider: "Go", window: "月", percent: 5, resetsAt: nil, sampledAt: Date())
            ],
            sourceLabel: "dsh-cost-meter"
        )
        dshUsage.providerName = "DSH"

        var working = mockSession(
            id: "session-aaaa1111",
            title: "为桌面宠物接入 DSH 会话监控",
            workspace: "dshpeg",
            cwd: "/Users/example/projects/dshpeg"
        )
        working.turnActive = true
        working.turnStartedAt = Date().addingTimeInterval(-134)
        working.turnNumber = 12
        working.stepNumber = 4
        working.lastToolName = "跑命令"
        working.lastToolDetail = "swift build"
        working.tokensThisTurn = 128_400
        working.phase = .working

        var waiting = mockSession(
            id: "session-bbbb2222",
            title: "把首页动画接进侧栏",
            workspace: "slowfish",
            cwd: "/Users/example/projects/slowfish"
        )
        waiting.turnActive = true
        waiting.turnStartedAt = Date().addingTimeInterval(-320)
        waiting.pendingApproval = ApprovalRequest(
            id: "approval-1",
            tool: "bash",
            reason: "需要把构建产物写到项目目录之外",
            since: Date().addingTimeInterval(-40)
        )
        waiting.phase = .waiting

        var done = mockSession(
            id: "session-cccc3333",
            title: "写一份小红书宣传文案",
            workspace: "slowfish",
            cwd: "/Users/example/projects/slowfish"
        )
        done.turnActive = false
        done.turnStartedAt = Date().addingTimeInterval(-600)
        done.lastCompletedAt = Date().addingTimeInterval(-100)
        done.phase = .done

        var error = mockSession(
            id: "session-dddd4444",
            title: "排查计费报表接口",
            workspace: "saas-cloud",
            cwd: "/Users/example/projects/saas-cloud"
        )
        error.turnActive = false
        error.lastErrorAt = Date().addingTimeInterval(-500)
        error.lastErrorText = "503: Upstream request failed: Endpoint is unavailable."
        error.phase = .error

        var codexWorking = mockSession(
            id: "019f0a2b-1111-2222-3333-444455556666",
            title: "给设置页补上暗色模式",
            workspace: "oa",
            cwd: "/Users/example/projects/oa",
            providerID: AgentProviderID.codex,
            providerName: "Codex"
        )
        codexWorking.turnActive = true
        codexWorking.turnStartedAt = Date().addingTimeInterval(-72)
        codexWorking.lastToolName = "改代码"
        codexWorking.lastToolDetail = "SettingsView.swift"
        codexWorking.tokensThisTurn = 42_300
        codexWorking.phase = .working

        var openCodeWorking = mockSession(
            id: "ses_demo_opencode",
            title: "把语音玩具接上大模型",
            workspace: "ai-voice-toy",
            cwd: "/Users/example/projects/ai-voice-toy",
            providerID: AgentProviderID.openCode,
            providerName: "OpenCode"
        )
        openCodeWorking.turnActive = true
        openCodeWorking.turnStartedAt = Date().addingTimeInterval(-95)
        openCodeWorking.lastToolName = "跑命令"
        openCodeWorking.lastToolDetail = "npm run dev"
        openCodeWorking.tokensThisTurn = 38_200
        openCodeWorking.phase = .working

        let dsh = ProviderStatus(
            id: AgentProviderID.dsh,
            name: "DeepSeek Harness",
            shortName: "DSH",
            running: true,
            sessions: [working, waiting, done, error],
            usage: dshUsage,
            watchPath: "/Users/example/.dsh/sessions",
            capabilities: .all,
            updatedAt: Date()
        )
        let codex = ProviderStatus(
            id: AgentProviderID.codex,
            name: "Codex",
            shortName: "Codex",
            running: true,
            sessions: [codexWorking],
            usage: ProviderUsage(
                providerID: AgentProviderID.codex,
                providerName: "Codex",
                today: UsageTotals(costCNY: nil, calls: 37, tokens: 1_200_000),
                quotas: [],
                sourceLabel: "~/.codex/sessions"
            ),
            watchPath: "/Users/example/.codex/sessions",
            capabilities: [.sessions, .usage, .reveal],
            updatedAt: Date()
        )

        let openCode = ProviderStatus(
            id: AgentProviderID.openCode,
            name: "OpenCode",
            shortName: "OpenCode",
            running: true,
            sessions: [openCodeWorking],
            usage: ProviderUsage(
                providerID: AgentProviderID.openCode,
                providerName: "OpenCode",
                today: UsageTotals(costCNY: nil, costUSD: 0.42, calls: 18, tokens: 620_000),
                quotas: [
                    UsageQuota(provider: "Go", window: "5h", percent: 11, resetsAt: nil, sampledAt: Date()),
                    UsageQuota(provider: "Go", window: "周", percent: 29, resetsAt: nil, sampledAt: Date()),
                    UsageQuota(provider: "Go", window: "月", percent: 14, resetsAt: nil, sampledAt: Date())
                ],
                sourceLabel: "~/.local/share/opencode/opencode.db"
            ),
            watchPath: "/Users/example/.local/share/opencode",
            capabilities: [.sessions, .usage, .reveal],
            updatedAt: Date()
        )

        var status = FleetStatus()
        status.providers = [dsh, codex, openCode]
        status.updatedAt = Date()
        return status
    }

    private static func mockSession(
        id: String,
        title: String,
        workspace: String,
        cwd: String,
        providerID: String = AgentProviderID.dsh,
        providerName: String = "DSH"
    ) -> AgentSession {
        AgentSession(
            id: id,
            directory: "/tmp/\(id)",
            logPath: "/tmp/\(id)/session.v4.jsonl.zstd",
            title: title,
            cwd: cwd,
            workspaceName: workspace,
            createdAt: Date().addingTimeInterval(-3600),
            lastEventAt: Date().addingTimeInterval(-12),
            fileModifiedAt: Date(),
            providerID: providerID,
            providerName: providerName
        )
    }
}
