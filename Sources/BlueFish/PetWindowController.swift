import AppKit
import QuartzCore

final class PetWindowController: NSObject, NSMenuDelegate {
    private let monitor: DSHMonitor
    private let card = StatusCardController()
    private let panel: NSPanel
    private let stage: PetStageView
    private let menuBar: MenuBarController
    private let controlServer = PetControlServer()
    private let updater = UpdateChecker()

    private var status = DSHStatus()
    private var hasLoaded = false
    private var hasSetMood = false
    private var didGreet = false
    private var waitingBubbleActive = false
    private var bubbleHoldUntil: Date = .distantPast
    private var bubbleCollapsed = false
    private var paused = false
    private var soundsEnabled = true
    private var petScale: CGFloat = 1
    private var currentMood: PetMood = .offline
    private var lastPhases: [String: SessionPhase] = [:]
    private var transientMood: PetMood?
    private var transientUntil: Date = .distantPast
    private var lastInteractionAt: Date = .distantPast
    private var lastChatterAt: Date = .distantPast
    private var tickTimer: Timer?
    private var clickThroughTimer: Timer?
    private var manualUpdateCheck = false

    private let defaults = UserDefaults.standard
    private static let originKey = "BlueFish.petOrigin"

    override init() {
        let scale = PetLayout.storedScale()
        let size = PetLayout.panelSize(for: scale)
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        stage = PetStageView(frame: NSRect(origin: .zero, size: size))
        menuBar = MenuBarController()
        monitor = DSHMonitor()

        super.init()

        petScale = scale
        stage.setSizeScale(scale)

        panel.contentView = stage
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none

        soundsEnabled = defaults.object(forKey: "BlueFish.sounds") as? Bool ?? true

        stage.onToggleCard = { [weak self] in self?.toggleCard() }
        stage.onToggleBubble = { [weak self] in self?.toggleBubble() }
        stage.onDragEnded = { [weak self] in self?.rememberPosition() }
        stage.onContextMenu = { [weak self] event in self?.showContextMenu(event) }
        stage.onDoubleClick = { [weak self] in self?.reactToPoke() }

        card.onClose = { [weak self] in self?.card.hide() }
        card.onRefresh = { [weak self] in self?.forceRefresh() }
        card.onReveal = { path in
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
        card.onOpenSession = { [weak self] session in
            self?.jumpToSession(session)
        }
        card.onUpdate = { [weak self] in
            self?.updater.performUpdate()
        }
        updater.onStateChange = { [weak self] state in
            self?.handleUpdateState(state)
        }
        updater.onError = { [weak self] message in
            self?.showBubble(
                title: "更新下载失败",
                detail: message,
                autoHide: 6,
                accent: Theme.red
            )
        }

        menuBar.onToggleCard = { [weak self] in self?.toggleCard() }
        menuBar.onTogglePet = { [weak self] in self?.togglePetVisibility() }
        menuBar.onTogglePause = { [weak self] in self?.togglePause() }
        menuBar.onToggleSound = { [weak self] in self?.toggleSound() }
        menuBar.onResetPosition = { [weak self] in self?.resetPosition() }
        menuBar.onQuit = { NSApp.terminate(nil) }
        menuBar.onOpenSession = { [weak self] session in
            self?.jumpToSession(session)
        }
        menuBar.currentSize = { [weak self] in
            guard let self else { return .standard }
            return PetSizePreset.nearest(to: self.petScale)
        }
        menuBar.onSelectSize = { [weak self] preset in
            self?.setPetScale(preset.scale)
        }
        menuBar.onCheckUpdate = { [weak self] in
            self?.checkForUpdates()
        }
        menuBar.updateVersion = { [weak self] in
            guard let self, case .available(let release) = self.updater.state else { return nil }
            return release.version
        }
        menuBar.isPetVisible = { [weak self] in self?.panel.isVisible ?? false }
        menuBar.isCardVisible = { [weak self] in self?.card.visible ?? false }

        monitor.onUpdate = { [weak self] status in
            self?.apply(status)
        }
        restorePosition()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func start() {
        windowReady()
        panel.orderFrontRegardless()
        monitor.start()
        updater.start()
        writeState()
        controlServer.statusProvider = { [weak self] in self?.panel.isVisible ?? false }
        controlServer.actionHandler = { [weak self] action in self?.handleControl(action) }
        controlServer.start()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(tickTimer!, forMode: .common)
        clickThroughTimer = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { [weak self] _ in
            self?.updateClickThrough()
        }
        RunLoop.main.add(clickThroughTimer!, forMode: .common)
        menuBar.install()
        menuBar.update(status: status, paused: paused, sounds: soundsEnabled)
        updatePet(force: true, announce: false)
        stage.showChip("正在连接 DSH…", accent: Theme.muted, pulse: false)
        // First run greeting (replaced by a task announcement if one is pending).
        DebugLog.write("controller start frame=\(panel.frame) visible=\(panel.isVisible) args=\(CommandLine.arguments)")
        if CommandLine.arguments.contains("--bubble-demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.toggleBubble()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 7.0) { [weak self] in
                self?.toggleBubble()
            }
        }
        if CommandLine.arguments.contains("--walk-demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.stage.sprite.startWalking()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 12.0) { [weak self] in
                self?.stage.sprite.stopWalking()
            }
        }
        if CommandLine.arguments.contains("--open-card") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self, !self.card.visible else { return }
                self.card.update(self.status)
                self.card.show(relativeTo: self.panel.frame)
                DebugLog.write("open-card visible=\(self.card.visible) panel=\(self.card.panel.frame) alpha=\(self.card.panel.alphaValue)")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, !self.didGreet else { return }
            // If DSH is already working, the task bubble is more useful than
            // the introduction.
            guard self.status.workingSessions.isEmpty else { return }
            self.didGreet = true
            self.showBubble(
                title: "咕噜…我是鲸鱼娘",
                detail: "帮你盯着 DSH 的任务 · 点我打开面板，拖我换位置",
                autoHide: 7
            )
        }
    }

    func stop() {
        tickTimer?.invalidate()
        monitor.stop()
        clickThroughTimer?.invalidate()
        updater.stop()
    }

    /// The pet window is mostly transparent; let clicks fall through unless the
    /// cursor is actually on the pet, a chip, or a bubble. Without this the
    /// invisible margins would block the DSH window underneath.
    private func updateClickThrough() {
        guard panel.isVisible else {
            panel.ignoresMouseEvents = true
            return
        }
        if NSEvent.pressedMouseButtons != 0, !panel.ignoresMouseEvents { return }
        let hit = panel.convertToScreen(stage.convert(stage.interactiveRect, to: nil))
        let inside = hit.contains(NSEvent.mouseLocation)
        if panel.ignoresMouseEvents == inside {
            panel.ignoresMouseEvents = !inside
            DebugLog.write("clickthrough inside=\(inside) ignore=\(panel.ignoresMouseEvents) mouse=\(NSEvent.mouseLocation)")
        }
    }

    // MARK: - Window

    private func windowReady() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let frame = panel.frame
        if defaults.string(forKey: Self.originKey) == nil {
            panel.setFrameOrigin(NSPoint(x: visible.maxX - frame.width - 20, y: visible.minY + 12))
        }
        clampToScreen()
    }

    private func restorePosition() {
        if let stored = defaults.string(forKey: Self.originKey) {
            let point = NSPointFromString(stored)
            if point.x.isFinite, point.y.isFinite, point != .zero {
                panel.setFrameOrigin(point)
            }
        }
        // A position saved on a display that no longer exists must not leave
        // the pet off-screen after the user switches to one monitor.
        clampToScreen()
    }

    private func rememberPosition() {
        defaults.set(NSStringFromPoint(panel.frame.origin), forKey: Self.originKey)
        if card.visible { card.reposition(relativeTo: panel.frame) }
    }

    private func resetPosition() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        // Move directly: NSAnimationContext on a borderless nonactivating panel
        // can be dropped while the app is in the background.
        panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 20, y: visible.minY + 12))
        rememberPosition()
        if card.visible { card.reposition(relativeTo: panel.frame) }
    }

    private func clampToScreen() {
        let intersecting = NSScreen.screens.first { $0.visibleFrame.intersects(panel.frame) }
        guard let screen = intersecting ?? panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var frame = panel.frame
        frame.origin.x = max(visible.minX + 8, min(frame.origin.x, visible.maxX - frame.width - 8))
        frame.origin.y = max(visible.minY + 8, min(frame.origin.y, visible.maxY - frame.height - 8))
        if frame.origin != panel.frame.origin {
            panel.setFrameOrigin(frame.origin)
        }
    }

    @objc private func screenParametersChanged() {
        clampToScreen()
        if card.visible { card.reposition(relativeTo: panel.frame) }
    }

    private func handleControl(_ action: String) {
        switch action {
        case "toggle": togglePetVisibility()
        case "show": showPet()
        case "hide": hidePet()
        case "quit": NSApp.terminate(nil)
        case "recenter": resetPosition()
        case "axdump": DSHFocus.dumpAXTree()
        default: break
        }
    }

    private func togglePetVisibility() {
        if panel.isVisible { hidePet() } else { showPet() }
    }

    private func showPet() {
        panel.orderFrontRegardless()
        menuBar.update(status: status, paused: paused, sounds: soundsEnabled)
        writeState()
    }

    private func hidePet() {
        panel.orderOut(nil)
        card.hide()
        menuBar.update(status: status, paused: paused, sounds: soundsEnabled)
        writeState()
    }

    /// `bluefish://toggle | show | hide | quit` — used by the DSH plugin and
    /// any other launcher. `bluefish://size/0.75` (or `/75`) changes the pet
    /// size without opening the menu.
    func handle(url: URL) {
        guard url.scheme?.lowercased() == "bluefish" else { return }
        switch (url.host ?? url.path.replacingOccurrences(of: "/", with: "")).lowercased() {
        case "toggle": togglePetVisibility()
        case "show": showPet()
        case "hide": hidePet()
        case "quit": NSApp.terminate(nil)
        case "recenter": resetPosition()
        case "axdump": DSHFocus.dumpAXTree()
        case "size": applySizeURL(url)
        case "check-update": checkForUpdates()
        case "update": updater.performUpdate()
        default: break
        }
    }

    private func applySizeURL(_ url: URL) {
        guard let raw = url.pathComponents.last, let value = Double(raw) else { return }
        setPetScale(CGFloat(value > 2 ? value / 100 : value))
    }

    /// A tiny state file so the DSH plugin can report running/visible state.
    private func writeState() {
        let payload: [String: Any] = [
            "visible": panel.isVisible,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "updatedAt": Date().timeIntervalSince1970
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) else { return }
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh/storages/bluefish-pet.json")
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Status pipeline

    private func apply(_ newStatus: DSHStatus) {
        let previous = status
        status = newStatus
        card.update(newStatus)
        if card.visible { card.reposition(relativeTo: panel.frame) }

        if !hasLoaded {
            hasLoaded = true
            seedPhases(newStatus)
            updatePet(force: true, announce: false)
            if !newStatus.workingSessions.isEmpty {
                // A greeting may already be on screen from launch; hand the
                // bubble over to the live task in place.
                bubbleHoldUntil = .distantPast
                updateBubbleLayer()
            }
            if let waiting = newStatus.attentionSessions.first, let approval = waiting.pendingApproval {
                announceWaiting(waiting, approval: approval)
            } else if newStatus.recentSessions.isEmpty {
                showBubble(
                    title: "DSH 好像没开工",
                    detail: "等你打开 DSH，我会自己醒过来",
                    autoHide: 6
                )
            } else if !didGreet, newStatus.workingSessions.isEmpty {
                didGreet = true
                showBubble(
                    title: "咕噜…我是鲸鱼娘",
                    detail: "帮你盯着 DSH 的任务 · 点我打开面板，拖我换位置",
                    autoHide: 9
                )
            }
            menuBar.update(status: status, paused: paused, sounds: soundsEnabled)
            return
        }

        announceTransitions(from: previous, to: newStatus)
        announceConnectionChange(from: previous, to: newStatus)
        updatePet(force: true, announce: true)
        menuBar.update(status: status, paused: paused, sounds: soundsEnabled)
    }

    private func seedPhases(_ status: DSHStatus) {
        lastPhases = Dictionary(uniqueKeysWithValues: status.recentSessions.map { ($0.id, $0.phase) })
    }

    private func announceTransitions(from old: DSHStatus, to new: DSHStatus) {
        guard !paused else {
            seedPhases(new)
            return
        }
        var waiting: [SessionSnapshot] = []
        var errors: [SessionSnapshot] = []
        var dones: [SessionSnapshot] = []
        for session in new.recentSessions {
            let previous = lastPhases[session.id]
            if previous != session.phase {
                switch session.phase {
                case .waiting: waiting.append(session)
                case .error: errors.append(session)
                case .done: dones.append(session)
                default: break
                }
            }
        }
        for session in new.recentSessions {
            lastPhases[session.id] = session.phase
        }

        if let first = waiting.first {
            announceWaiting(first, approval: first.pendingApproval)
            return
        }
        if waitingBubbleActive, new.attentionSessions.isEmpty {
            waitingBubbleActive = false
            if !stage.isBubbleVisible {
                showBubble(title: "确认好了，继续～", detail: "我接着盯任务", autoHide: 3.5)
            } else {
                stage.hideBubble()
            }
        }
        if let session = errors.first {
            let detail = session.lastErrorText.map { tail($0.replacingOccurrences(of: "\n", with: " "), 90) } ?? "这轮没有跑完"
            showBubble(
                title: "呜…出事了",
                detail: "\(session.workspaceName)：\(detail)",
                autoHide: 9,
                accent: Theme.red,
                cost: status.costLine
            )
            playSound("Basso")
            stage.sprite.playShake()
            transientMood = .panic
            transientUntil = Date().addingTimeInterval(4)
            return
        }
        if !dones.isEmpty {
            let first = dones[0]
            let title = dones.count > 1 ? "\(dones.count) 个任务搞定啦！" : "搞定啦！"
            let detail = dones.count > 1
                ? "海底今天也很努力"
                : "\(first.workspaceName) · 用了 \(shortDuration(first.elapsed))"
            showBubble(title: title, detail: detail, autoHide: 8, accent: Theme.green, cost: status.costLine)
            playSound("Glass")
            stage.sprite.playJump()
            transientMood = .happy
            transientUntil = Date().addingTimeInterval(4.5)
        }
    }

    private func announceConnectionChange(from old: DSHStatus, to new: DSHStatus) {
        if old.dshRunning, !new.dshRunning {
            showBubble(
                title: "DSH 断连了",
                detail: "后端退出了 · 桌宠会在这里等你",
                autoHide: 9,
                accent: Theme.muted
            )
            playSound("Basso")
        } else if !old.dshRunning, new.dshRunning {
            showBubble(
                title: "重新连上啦",
                detail: "继续帮你盯任务",
                autoHide: 4,
                accent: Theme.green
            )
            playSound("Glass")
            stage.sprite.playJump()
        }
    }

    private func announceWaiting(_ session: SessionSnapshot, approval: ApprovalRequest?) {
        let tool = approval?.tool ?? "操作"
        let reason = approval?.reason.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let detail: String
        if reason.isEmpty {
            detail = "\(session.workspaceName) · 需要你放行 \(tool)"
        } else {
            detail = "\(session.workspaceName) · \(tail(reason.replacingOccurrences(of: "\n", with: " "), 78))"
        }
        showBubble(
            title: "有任务在等你确认",
            detail: detail,
            autoHide: nil,
            accent: Theme.amber,
            meta: "已等 0s · \(tool)",
            cost: status.costLine
        )
        waitingBubbleActive = true
        playSound("Tink")
        transientMood = .waiting
        transientUntil = Date().addingTimeInterval(3)
    }

    private func updatePet(force: Bool, announce: Bool) {
        let mood = desiredMood()
        if !hasSetMood || mood != currentMood {
            stage.sprite.setMood(mood, animated: hasLoaded)
            currentMood = mood
            hasSetMood = true
        }
        if bubbleCollapsed, !hasBubbleContent() {
            bubbleCollapsed = false
        }
        let info = chipInfo()
        stage.showChip(info.text, accent: info.accent, pulse: info.pulse)
        updateBubbleLayer()
        if card.visible { card.reposition(relativeTo: panel.frame) }
    }

    /// While DSH is working, keep a persistent bubble above the pet with the
    /// current task, action and elapsed time. Transient bubbles (done / error /
    /// chatter) win for their display window.
    private func updateBubbleLayer() {
        if paused || bubbleCollapsed { return }

        if let waiting = status.attentionSessions.first, let approval = waiting.pendingApproval {
            let waited = shortDuration(Date().timeIntervalSince(approval.since))
            let reason = approval.reason.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = reason.isEmpty
                ? "\(waiting.workspaceName) 需要放行 \(approval.tool)"
                : "\(waiting.workspaceName) · \(tail(reason.replacingOccurrences(of: "\n", with: " "), 54))"
            stage.updateBubble(
                title: "有任务在等你确认",
                detail: detail,
                meta: "已等 \(waited) · \(approval.tool)",
                cost: status.costLine,
                accent: Theme.amber
            )
            waitingBubbleActive = true
            return
        }

        if Date() < bubbleHoldUntil { return }

        let working = status.workingSessions
        if let first = working.first {
            let stalled = first.phase == .stalled
            let name = first.displayTitle.isEmpty ? first.workspaceName : first.displayTitle
            let title = stalled ? "好像卡住了 · \(tail(name, 13))" : tail(name, 16)
            let detail = tail(first.actionLine ?? "在思考…", 26)
            var meta: [String] = ["已跑 \(shortDuration(first.elapsed))"]
            if first.stepNumber > 0 { meta.append("第 \(first.stepNumber) 步") }
            if !first.runningJobs.isEmpty { meta.append("后台 \(first.runningJobs.count) 个") }
            if working.count > 1 { meta.append("另有 \(working.count - 1) 个任务") }
            stage.updateBubble(
                title: title,
                detail: detail,
                meta: meta.joined(separator: " · "),
                cost: status.costLine,
                accent: stalled ? Theme.amber : Theme.cyan
            )
            return
        }

        if stage.isBubbleVisible { stage.hideBubble() }
    }

    private func desiredMood() -> PetMood {
        if paused { return .idle }
        if let transient = transientMood, Date() < transientUntil {
            // A live approval always wins over a click reaction.
            if transient == .waiting, !status.attentionSessions.isEmpty { return .waiting }
            return transient
        }
        transientMood = nil
        var mood = status.mood
        if mood == .sleeping, Date().timeIntervalSince(lastInteractionAt) < 18 { mood = .idle }
        if mood == .offline, status.dshRunning { mood = .idle }
        return mood
    }

    private func toggleBubble() {
        if bubbleCollapsed {
            bubbleCollapsed = false
            bubbleHoldUntil = .distantPast
            updatePet(force: false, announce: false)
            updateBubbleLayer()
        } else if stage.isBubbleVisible {
            bubbleCollapsed = true
            stage.hideBubble()
            updatePet(force: false, announce: false)
        } else {
            toggleCard()
        }
    }

    private func hasBubbleContent() -> Bool {
        !status.attentionSessions.isEmpty ||
        !status.workingSessions.isEmpty ||
        stage.isBubbleVisible ||
        Date() < bubbleHoldUntil
    }

    private func chipInfo() -> (text: String, accent: NSColor, pulse: Bool) {
        let info = chipInfoBase()
        if bubbleCollapsed, hasBubbleContent() {
            return ("▸ 任务", info.accent, info.pulse)
        }
        return info
    }

    private func chipInfoBase() -> (text: String, accent: NSColor, pulse: Bool) {
        if paused { return ("监控已暂停", Theme.muted, false) }
        if let waiting = status.attentionSessions.first, let approval = waiting.pendingApproval {
            return ("等你确认：\(approval.tool)", Theme.amber, true)
        }
        if let error = status.errorSessions.first,
           Date().timeIntervalSince(error.lastErrorAt ?? error.lastEventAt) < 180 {
            return ("出错了 · \(error.workspaceName)", Theme.red, true)
        }
        let working = status.workingSessions
        if let first = working.first {
            let prefix = working.count > 1 ? "\(working.count)× " : ""
            let raw = first.actionLine ?? "在思考"
            let pieces = raw.split(separator: "·", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            let action: String
            if pieces.count > 1 {
                action = "\(pieces[0]) · \(tail(pieces[1], 11))"
            } else {
                action = tail(raw, 17)
            }
            let stalled = first.phase == .stalled
            let elapsed = first.turnActive ? shortDuration(first.elapsed) : ""
            let text = stalled ? "\(prefix)可能卡住了 · \(elapsed)" : "\(prefix)\(action) · \(elapsed)"
            return (tail(text, 30), stalled ? Theme.amber : Theme.cyan, stalled)
        }
        if let done = status.doneSessions.first,
           Date().timeIntervalSince(done.lastCompletedAt ?? done.lastEventAt) < 120 {
            return ("搞定 · \(shortDuration(done.elapsed))", Theme.green, false)
        }
        switch status.mood {
        case .sleeping: return ("呼…呼…", Theme.violet, false)
        case .offline: return ("DSH 断连", Theme.muted, false)
        case .happy: return ("搞定！", Theme.green, false)
        case .panic: return ("出错了", Theme.red, false)
        case .waiting: return ("等你确认", Theme.amber, true)
        default: return ("待命中", Theme.cyan, false)
        }
    }

    // MARK: - Tick

    private func tick() {
        updatePet(force: false, announce: false)
        if !hasLoaded { return }
        if transientMood != nil, Date() >= transientUntil {
            transientMood = nil
            updatePet(force: true, announce: false)
        }
        maybeChatter()
    }

    private func maybeChatter() {
        guard !paused, hasLoaded, currentMood == .idle else { return }
        guard !stage.isBubbleVisible else { return }
        guard Date().timeIntervalSince(lastChatterAt) > 240 else { return }
        guard Double.random(in: 0...1) < 0.25 else { return }
        lastChatterAt = Date()
        let lines = [
            ("咕噜…", "有事就叫我，我盯着任务呢"),
            ("深海今天很安静", "点我看看最近的任务吧"),
            ("我在摸鱼", "啊不，我在待命"),
            ("任务面板在这", "点一下我，就能看到所有会话"),
            ("尾巴…啊不", "脚麻了，换个姿势")
        ]
        guard let line = lines.randomElement() else { return }
        showBubble(title: line.0, detail: line.1, autoHide: 6)
    }

    private func showBubble(
        title: String,
        detail: String,
        autoHide: TimeInterval?,
        accent: NSColor? = nil,
        meta: String = "",
        cost: String = ""
    ) {
        stage.showBubble(
            title: title,
            detail: detail,
            meta: meta,
            cost: cost,
            accent: accent ?? currentMood.tint,
            autoHide: autoHide
        )
        lastInteractionAt = Date()
        bubbleHoldUntil = autoHide.map { Date().addingTimeInterval($0) } ?? .distantPast
    }

    private func playSound(_ name: String) {
        guard soundsEnabled else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }

    // MARK: - Actions

    private func jumpToSession(_ session: SessionSnapshot) {
        card.hide()
        showBubble(
            title: "去 DSH 找会话…",
            detail: tail(session.displayTitle, 24),
            autoHide: 2.5
        )
        let activeWorkspace = status.sessions
            .max(by: { $0.lastEventAt < $1.lastEventAt })?
            .workspaceName
        DSHFocus.jump(to: session, currentWorkspace: activeWorkspace) { [weak self] outcome in
            guard let self else { return }
            self.showBubble(
                title: outcome.ok ? "跳过去啦" : "跳转没成功",
                detail: outcome.message,
                autoHide: outcome.ok ? 3.5 : 6,
                accent: outcome.ok ? Theme.green : Theme.amber
            )
        }
    }

    private func requestJumpPermission() {
        DSHFocus.requestPermission()
        DSHFocus.openAccessibilitySettings()
        showBubble(
            title: "开启「辅助功能」权限",
            detail: "系统设置 → 隐私与安全性 → 辅助功能 → 勾选鲸鱼娘",
            autoHide: 8
        )
    }

    private func toggleCard() {
        lastInteractionAt = Date()
        if card.visible {
            card.hide()
        } else {
            card.update(status)
            card.show(relativeTo: panel.frame)
        }
    }

    private func forceRefresh() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let status = self.monitor.refreshNow()
            DispatchQueue.main.async {
                self.apply(status)
            }
        }
    }

    private func togglePause() {
        paused.toggle()
        monitor.setPaused(paused)
        if paused {
            showBubble(title: "好，我先睡会儿", detail: "监控已暂停 · 点菜单栏的鱼恢复", autoHide: 5)
            transientMood = nil
        } else {
            showBubble(title: "醒了！", detail: "继续帮你盯着 DSH", autoHide: 4)
            forceRefresh()
        }
        updatePet(force: true, announce: false)
        menuBar.update(status: status, paused: paused, sounds: soundsEnabled)
    }

    private func toggleSound() {
        soundsEnabled.toggle()
        defaults.set(soundsEnabled, forKey: "BlueFish.sounds")
        if soundsEnabled { playSound("Pop") }
        menuBar.update(status: status, paused: paused, sounds: soundsEnabled)
    }

    /// Resize the whole pet window in place. The bottom edge keeps its screen
    /// position, so the pet grows/shrinks from its feet instead of jumping.
    private func setPetScale(_ scale: CGFloat) {
        let target = PetLayout.clampScale(scale)
        guard abs(target - petScale) > 0.001 else { return }
        let oldFrame = panel.frame
        petScale = target
        defaults.set(Double(target), forKey: PetLayout.scaleDefaultsKey)

        var frame = oldFrame
        frame.size = PetLayout.panelSize(for: target)
        panel.setFrame(frame, display: true)
        stage.setSizeScale(target)
        stage.layoutSubtreeIfNeeded()
        clampToScreen()
        rememberPosition()
        menuBar.update(status: status, paused: paused, sounds: soundsEnabled)
        DebugLog.write("pet size=\(target) frame=\(panel.frame)")
    }

    private var updateMenuTitle: String {
        if case .available(let release) = updater.state {
            return "可更新 v\(release.version)…"
        }
        return "检查更新…"
    }

    private func checkForUpdates() {
        if case .available(let release) = updater.state {
            if !card.visible {
                card.update(status)
                card.show(relativeTo: panel.frame)
            }
            showBubble(
                title: "发现新版本 v\(release.version)",
                detail: "在任务面板点「可更新」就能安装",
                autoHide: 7,
                accent: Theme.amber
            )
            return
        }
        if case .downloading = updater.state { return }
        manualUpdateCheck = true
        updater.check(force: true)
    }

    private func handleUpdateState(_ state: PetUpdateState) {
        card.updateUpdateState(state)
        switch state {
        case .upToDate(let version):
            guard manualUpdateCheck else { return }
            manualUpdateCheck = false
            showBubble(
                title: "已是最新版本",
                detail: "v\(version) · 海底没有新东西",
                autoHide: 4,
                accent: Theme.green
            )
        case .available(let release):
            guard manualUpdateCheck else { return }
            manualUpdateCheck = false
            if !card.visible {
                card.update(status)
                card.show(relativeTo: panel.frame)
            }
            showBubble(
                title: "发现新版本 v\(release.version)",
                detail: "在任务面板点「可更新」就能安装",
                autoHide: 8,
                accent: Theme.amber
            )
        case .failed(let message):
            guard manualUpdateCheck else { return }
            manualUpdateCheck = false
            showBubble(title: "检查更新失败", detail: message, autoHide: 6, accent: Theme.red)
        case .ready(let version, _):
            manualUpdateCheck = false
            showBubble(
                title: "v\(version) 安装包已就绪",
                detail: "按安装器提示安装 · 装完重新打开鲸鱼娘",
                autoHide: 10,
                accent: Theme.green
            )
        default:
            break
        }
    }

    private func reactToPoke() {
        lastInteractionAt = Date()
        transientMood = .happy
        transientUntil = Date().addingTimeInterval(2.2)
        stage.sprite.playJump()
        let line = currentMood == .working
            ? ("别戳啦", "我在认真吃…啊不，干活")
            : ("咕噜咕噜～", "被你戳到痒痒的地方了")
        showBubble(title: line.0, detail: line.1, autoHide: 3.5)
        playSound("Pop")
        updatePet(force: true, announce: false)
    }

    private func showContextMenu(_ event: NSEvent) {
        let menu = NSMenu()
        let cardItem = NSMenuItem(
            title: card.visible ? "收起任务面板" : "打开任务面板",
            action: #selector(menuToggleCard),
            keyEquivalent: ""
        )
        cardItem.target = self
        menu.addItem(cardItem)

        let pauseItem = NSMenuItem(title: "暂停监控", action: #selector(menuTogglePause), keyEquivalent: "")
        pauseItem.target = self
        pauseItem.state = paused ? .on : .off
        menu.addItem(pauseItem)

        let soundItem = NSMenuItem(title: "提示音", action: #selector(menuToggleSound), keyEquivalent: "")
        soundItem.target = self
        soundItem.state = soundsEnabled ? .on : .off
        menu.addItem(soundItem)

        menu.addItem(makePetSizeMenu(
            target: self,
            action: #selector(menuSelectSize(_:)),
            selected: PetSizePreset.nearest(to: petScale)
        ))

        let updateItem = NSMenuItem(title: updateMenuTitle, action: #selector(menuCheckUpdate), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(.separator())

        let permission = NSMenuItem(title: "授权跳转（辅助功能）…", action: #selector(menuPermission), keyEquivalent: "")
        permission.target = self
        menu.addItem(permission)

        let reset = NSMenuItem(title: "回到右下角", action: #selector(menuReset), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)

        let hide = NSMenuItem(title: "隐藏桌宠", action: #selector(menuHidePet), keyEquivalent: "")
        hide.target = self
        menu.addItem(hide)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出鲸鱼娘", action: #selector(menuQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        NSMenu.popUpContextMenu(menu, with: event, for: stage)
    }

    @objc private func menuToggleCard() { toggleCard() }
    @objc private func menuTogglePause() { togglePause() }
    @objc private func menuToggleSound() { toggleSound() }
    @objc private func menuSelectSize(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let preset = PetSizePreset(rawValue: raw) else { return }
        setPetScale(preset.scale)
    }
    @objc private func menuCheckUpdate() { checkForUpdates() }
    @objc private func menuPermission() { requestJumpPermission() }
    @objc private func menuReset() { resetPosition() }
    @objc private func menuHidePet() { togglePetVisibility() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    // MARK: - Menu delegate

    func menuNeedsUpdate(_ menu: NSMenu) {}

    var petFrame: NSRect { panel.frame }
    var currentState: DSHStatus { status }
    var isPaused: Bool { paused }
    var petVisible: Bool { panel.isVisible }
}
