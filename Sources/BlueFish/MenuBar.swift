import AppKit

final class MenuBarController: NSObject, NSMenuDelegate {
    private var item: NSStatusItem?
    private var status = FleetStatus()
    private var paused = false
    private var soundsEnabled = true
    private var recentSessions: [AgentSession] = []

    var onToggleCard: (() -> Void)?
    var onTogglePet: (() -> Void)?
    var onTogglePause: (() -> Void)?
    var onToggleSound: (() -> Void)?
    var onResetPosition: (() -> Void)?
    var onQuit: (() -> Void)?
    var onOpenSession: ((AgentSession) -> Void)?
    var currentSize: (() -> PetSizePreset)?
    var onSelectSize: ((PetSizePreset) -> Void)?
    var updateVersion: (() -> String?)?
    var onCheckUpdate: (() -> Void)?
    var isPetVisible: (() -> Bool)?
    var isCardVisible: (() -> Bool)?

    func install() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = icon()
            button.imagePosition = .imageOnly
            button.toolTip = "鲸鱼娘 · 本地代理桌宠"
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        item = statusItem
    }

    func update(status: FleetStatus, paused: Bool, sounds: Bool) {
        self.status = status
        self.paused = paused
        self.soundsEnabled = sounds
        recentSessions = status.recentSessions
        guard let button = item?.button else { return }
        button.image = icon()
        button.contentTintColor = nil
        button.toolTip = "鲸鱼娘 · \(paused ? "已暂停" : status.moodText) · \(status.headline)"
    }

    private func icon() -> NSImage? {
        let size = NSSize(width: 22, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        if let symbol = NSImage(systemSymbolName: "fish.fill", accessibilityDescription: "鲸鱼娘")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium)) {
            let tinted = NSImage(size: symbol.size)
            tinted.lockFocus()
            symbol.draw(in: NSRect(origin: .zero, size: symbol.size))
            NSColor.labelColor.setFill()
            NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop)
            tinted.unlockFocus()
            tinted.draw(in: NSRect(x: 0, y: 1, width: 18, height: 16))
        }
        let dot = NSRect(x: 15, y: 0, width: 6, height: 6)
        let color = paused ? Theme.muted : status.mood.tint
        color.setFill()
        NSBezierPath(ovalIn: dot).fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild(menu)
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = NSMenuItem(title: "鲸鱼娘", action: nil, keyEquivalent: "")
        header.isEnabled = false
        let title = NSMutableAttributedString(
            string: "鲸鱼娘",
            attributes: [
                .font: Theme.rounded(12.5, .semibold),
                .foregroundColor: NSColor.labelColor
            ]
        )
        let stateText = paused ? " · 监控暂停" : " · \(status.moodText)"
        title.append(NSAttributedString(
            string: stateText,
            attributes: [
                .font: Theme.rounded(11, .regular),
                .foregroundColor: paused ? NSColor.secondaryLabelColor : status.mood.tint
            ]
        ))
        header.attributedTitle = title
        menu.addItem(header)

        if !paused {
            let headline = NSMenuItem(title: status.headline, action: nil, keyEquivalent: "")
            headline.isEnabled = false
            headline.attributedTitle = NSAttributedString(
                string: tail(status.headline, 34),
                attributes: [
                    .font: Theme.rounded(10.5, .regular),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            )
            menu.addItem(headline)
        }

        menu.addItem(.separator())

        let cardItem = actionItem(
            (isCardVisible?() ?? false) ? "收起任务面板" : "打开任务面板",
            action: #selector(openCard),
            key: "t"
        )
        menu.addItem(cardItem)

        menu.addItem(actionItem(
            (isPetVisible?() ?? true) ? "隐藏桌宠" : "显示桌宠",
            action: #selector(togglePet),
            key: ""
        ))

        let pauseItem = actionItem(paused ? "恢复监控" : "暂停监控", action: #selector(togglePause), key: "")
        pauseItem.state = paused ? .on : .off
        menu.addItem(pauseItem)

        let soundItem = actionItem("提示音", action: #selector(toggleSound), key: "")
        soundItem.state = soundsEnabled ? .on : .off
        menu.addItem(soundItem)

        menu.addItem(makePetSizeMenu(
            target: self,
            action: #selector(selectSize(_:)),
            selected: currentSize?() ?? .standard
        ))

        let updateTitle = updateVersion?().map { "可更新 v\($0)…" } ?? "检查更新…"
        menu.addItem(actionItem(updateTitle, action: #selector(checkUpdate), key: ""))

        if !recentSessions.isEmpty {
            menu.addItem(.separator())
            let section = NSMenuItem(title: "最近任务", action: nil, keyEquivalent: "")
            section.isEnabled = false
            section.attributedTitle = NSAttributedString(
                string: "最近任务",
                attributes: [
                    .font: Theme.rounded(10.5, .semibold),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            )
            menu.addItem(section)
            let multiProvider = status.providers.count > 1
            for session in recentSessions.prefix(4) {
                let providerPrefix = multiProvider && !session.providerName.isEmpty
                    ? "\(session.providerName) · "
                    : ""
                let title = "\(session.phase.label) · \(providerPrefix)\(tail(session.displayTitle, 24))"
                let item = NSMenuItem(title: title, action: #selector(openSession(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = session.uid
                item.image = dotImage(color: session.phase.color)
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        menu.addItem(actionItem("回到右下角", action: #selector(resetPosition), key: ""))
        menu.addItem(actionItem("退出鲸鱼娘", action: #selector(quit), key: "q"))
    }

    private func actionItem(_ title: String, action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func dotImage(color: NSColor) -> NSImage {
        let size = NSSize(width: 9, height: 9)
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
        return image
    }

    @objc private func openCard() { onToggleCard?() }
    @objc private func togglePet() { onTogglePet?() }
    @objc private func togglePause() { onTogglePause?() }
    @objc private func toggleSound() { onToggleSound?() }
    @objc private func resetPosition() { onResetPosition?() }
    @objc private func quit() { onQuit?() }
    @objc private func checkUpdate() { onCheckUpdate?() }
    @objc private func selectSize(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let preset = PetSizePreset(rawValue: raw) else { return }
        onSelectSize?(preset)
    }

    @objc private func openSession(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String,
              let session = recentSessions.first(where: { $0.uid == uid }) else { return }
        onOpenSession?(session)
    }
}
