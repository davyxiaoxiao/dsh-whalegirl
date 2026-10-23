import AppKit
import QuartzCore

// MARK: - Reusable pieces

private final class StatTileView: NSView {
    private var value = "—"
    private var label = ""
    private var accent = Theme.cyan

    override var isOpaque: Bool { false }

    func update(value: String, label: String, accent: NSColor) {
        if self.value == value, self.label == label, self.accent == accent { return }
        self.value = value
        self.label = label
        self.accent = accent
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
        Theme.rowFill.setFill()
        path.fill()
        accent.withAlphaComponent(0.16).setStroke()
        path.lineWidth = 1
        path.stroke()

        let valueFont = Theme.rounded(21, .bold)
        let labelFont = Theme.rounded(9.5, .medium)
        let valueAttrs: [NSAttributedString.Key: Any] = [.font: valueFont, .foregroundColor: accent]
        let labelAttrs: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: Theme.muted]
        (value as NSString).draw(at: NSPoint(x: 12, y: bounds.height - 36), withAttributes: valueAttrs)
        (label as NSString).draw(in: NSRect(x: 12, y: 8, width: bounds.width - 24, height: 14), withAttributes: labelAttrs)
    }
}

private final class UsageStripView: NSView {
    private var items: [(value: String, label: String, accent: NSColor)] = []

    override var isOpaque: Bool { false }

    func update(_ items: [(value: String, label: String, accent: NSColor)]) {
        self.items = items
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
        Theme.rowFill.setFill()
        path.fill()
        Theme.panelStroke.withAlphaComponent(0.55).setStroke()
        path.lineWidth = 1
        path.stroke()
        guard !items.isEmpty else {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: Theme.rounded(10.5, .regular),
                .foregroundColor: Theme.muted
            ]
            let text = "未读取到 dsh-cost-meter 用量"
            let size = (text as NSString).size(withAttributes: attrs)
            (text as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
            return
        }
        let columnW = bounds.width / CGFloat(items.count)
        let valueFont = Theme.rounded(15, .bold)
        let labelFont = Theme.rounded(9.5, .medium)
        for (index, item) in items.enumerated() {
            let x = CGFloat(index) * columnW
            if index > 0 {
                Theme.panelStroke.withAlphaComponent(0.35).setStroke()
                let separator = NSBezierPath()
                separator.move(to: NSPoint(x: x, y: 10))
                separator.line(to: NSPoint(x: x, y: bounds.height - 10))
                separator.lineWidth = 1
                separator.stroke()
            }
            let valueAttrs: [NSAttributedString.Key: Any] = [.font: valueFont, .foregroundColor: item.accent]
            let labelAttrs: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: Theme.muted]
            let valueSize = (item.value as NSString).size(withAttributes: valueAttrs)
            let labelSize = (item.label as NSString).size(withAttributes: labelAttrs)
            let centerX = x + columnW / 2
            (item.value as NSString).draw(
                at: NSPoint(x: centerX - valueSize.width / 2, y: bounds.height - 27),
                withAttributes: valueAttrs
            )
            (item.label as NSString).draw(
                at: NSPoint(x: centerX - labelSize.width / 2, y: 9),
                withAttributes: labelAttrs
            )
        }
    }
}

private final class SessionRowView: NSView {
    var onOpen: (() -> Void)?
    var onMenu: ((NSEvent) -> Void)?
    private var session: SessionSnapshot?
    private var hovered = false
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    func update(session: SessionSnapshot) {
        self.session = session
        toolTip = session.cwd
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        NSCursor.pointingHand.push()
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        NSCursor.pop()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        onOpen?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onMenu?(event)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let session else { return }
        let rect = bounds.insetBy(dx: 0, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 13, yRadius: 13)
        (hovered ? Theme.rowFill.withAlphaComponent(0.85) : Theme.rowFill).setFill()
        path.fill()
        if hovered {
            session.phase.color.withAlphaComponent(0.22).setStroke()
            path.lineWidth = 1
            path.stroke()
        }

        let accent = session.phase.color
        let dot = NSRect(x: 13, y: 17, width: 8, height: 8)
        accent.withAlphaComponent(0.22).setFill()
        NSBezierPath(ovalIn: dot.insetBy(dx: -4, dy: -4)).fill()
        accent.setFill()
        NSBezierPath(ovalIn: dot).fill()

        let rightWidth: CGFloat = 88
        let rightInset: CGFloat = 20
        let titleRect = NSRect(x: 29, y: 10, width: bounds.width - 29 - rightWidth - 12, height: 18)
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: Theme.rounded(12.5, .semibold),
            .foregroundColor: NSColor.white
        ]
        (session.displayTitle as NSString).draw(in: titleRect, withAttributes: titleAttrs)

        let meta = "\(session.workspaceName) · \(session.actionLine ?? "暂无动作")"
        let metaAttrs: [NSAttributedString.Key: Any] = [
            .font: Theme.rounded(10.5, .regular),
            .foregroundColor: Theme.muted
        ]
        (meta as NSString).draw(in: NSRect(x: 29, y: 29, width: bounds.width - 29 - rightWidth - 12, height: 16), withAttributes: metaAttrs)

        let phaseText = session.phase.label
        let phaseAttrs: [NSAttributedString.Key: Any] = [
            .font: Theme.rounded(10, .semibold),
            .foregroundColor: accent
        ]
        let ps = NSMutableParagraphStyle()
        ps.alignment = .right
        var rightAttrs = phaseAttrs
        rightAttrs[.paragraphStyle] = ps
        (phaseText as NSString).draw(in: NSRect(x: bounds.width - rightWidth - rightInset, y: 10, width: rightWidth, height: 14), withAttributes: rightAttrs)

        var sub = "—"
        if session.turnActive {
            sub = shortDuration(session.elapsed)
        } else if let done = session.lastCompletedAt {
            sub = "完成 \(clockString(done))"
        } else {
            sub = relativeAge(session.lastEventAt)
        }
        var subAttrs: [NSAttributedString.Key: Any] = [
            .font: Theme.mono(9.5, .regular),
            .foregroundColor: Theme.muted
        ]
        subAttrs[.paragraphStyle] = ps
        (sub as NSString).draw(in: NSRect(x: bounds.width - rightWidth - rightInset, y: 28, width: rightWidth, height: 14), withAttributes: subAttrs)
    }
}

private final class SessionListView: NSView {
    var onOpen: ((SessionSnapshot) -> Void)?
    var onMenu: ((SessionSnapshot, NSEvent) -> Void)?
    private var rows: [SessionRowView] = []
    private var sessions: [SessionSnapshot] = []
    private var order: [String] = []

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    func update(_ sessions: [SessionSnapshot]) {
        let newOrder = sessions.map(\.id)
        self.sessions = sessions
        if newOrder == order, rows.count == sessions.count {
            for (row, session) in zip(rows, sessions) {
                row.update(session: session)
            }
            needsLayout = true
            needsDisplay = true
            return
        }
        order = newOrder
        for row in rows { row.removeFromSuperview() }
        rows.removeAll()
        for session in sessions {
            let row = SessionRowView(frame: .zero)
            let id = session.id
            row.onOpen = { [weak self] in
                guard let self, let s = self.sessions.first(where: { $0.id == id }) else { return }
                self.onOpen?(s)
            }
            row.onMenu = { [weak self] event in
                guard let self, let s = self.sessions.first(where: { $0.id == id }) else { return }
                self.onMenu?(s, event)
            }
            addSubview(row)
            rows.append(row)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h: CGFloat = 64
        let gap: CGFloat = 7
        for (i, row) in rows.enumerated() {
            row.frame = NSRect(x: 0, y: CGFloat(i) * (h + gap), width: bounds.width, height: h)
            row.update(session: sessions[i])
        }
        let height = rows.isEmpty ? 120 : CGFloat(rows.count) * (h + gap)
        if abs(frame.height - height) > 0.5 {
            setFrameSize(NSSize(width: bounds.width, height: height))
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard sessions.isEmpty else { return }
        let font = Theme.rounded(12, .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.muted]
        let text = "海底很安静 · DSH 还没开工"
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: 36), withAttributes: attrs)
        if let image = NSImage(systemSymbolName: "fish", accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 26, weight: .light)
            let temp = image.withSymbolConfiguration(config)
            temp?.isTemplate = true
            temp?.draw(in: NSRect(x: (bounds.width - 30) / 2, y: 66, width: 30, height: 26))
        }
    }
}

// MARK: - Background

private final class CardBackgroundView: NSView {
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 20, yRadius: 20)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = 22
        shadow.shadowOffset = NSSize(width: 0, height: -8)
        shadow.set()
        NSColor(srgbRed: 0.03, green: 0.07, blue: 0.16, alpha: 0.98).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        let gradient = NSGradient(colors: [
            NSColor(srgbRed: 0.075, green: 0.16, blue: 0.33, alpha: 0.98),
            NSColor(srgbRed: 0.025, green: 0.06, blue: 0.14, alpha: 0.99)
        ])
        gradient?.draw(in: path, angle: -90)

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        // A soft cyan halo near the top and a few rising bubbles.
        let halo = NSGradient(colors: [
            Theme.cyan.withAlphaComponent(0.16),
            Theme.cyan.withAlphaComponent(0.0)
        ])
        halo?.draw(in: NSRect(x: bounds.midX - 180, y: bounds.height - 220, width: 360, height: 260), relativeCenterPosition: NSPoint(x: 0, y: 0.2))
        for (x, y, r, a) in [
            (36.0, 432.0, 5.0, 0.10), (70.0, 396.0, 2.5, 0.08), (330.0, 448.0, 3.0, 0.09),
            (356.0, 380.0, 5.5, 0.07), (300.0, 500.0, 2.0, 0.10), (48.0, 300.0, 2.0, 0.06),
            (365.0, 250.0, 3.0, 0.05), (24.0, 190.0, 3.5, 0.05)
        ] {
            NSColor(srgbRed: 0.65, green: 0.9, blue: 1.0, alpha: a).setStroke()
            let bubble = NSBezierPath(ovalIn: NSRect(x: x, y: y, width: r * 2, height: r * 2))
            bubble.lineWidth = 1
            bubble.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()

        Theme.panelStroke.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

// MARK: - Update pill

private final class UpdatePillView: NSView {
    enum Style: Equatable {
        case available(String)
        case downloading(String, Double)
        case ready(String)
    }

    var onTap: (() -> Void)?
    private var style: Style?
    private var hovered = false
    private var tracking: NSTrackingArea?

    override var isOpaque: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func update(_ style: Style?) {
        self.style = style
        if style == nil {
            if hovered { NSCursor.arrow.set() }
            hovered = false
            toolTip = nil
        } else {
            toolTip = tooltip(for: style!)
        }
        isHidden = style == nil
        needsDisplay = true
    }

    private func tooltip(for style: Style) -> String {
        switch style {
        case .available(let version): return "发现新版本 \(version)，点击下载并安装"
        case .downloading(let version, _): return "正在下载 \(version)…"
        case .ready: return "安装包已下载，点击打开"
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard style != nil else { return }
        hovered = true
        NSCursor.pointingHand.push()
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        guard hovered else { return }
        hovered = false
        NSCursor.pop()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard style != nil else { return }
        onTap?()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let style else { return }
        let accent: NSColor
        let text: String
        let symbol: String
        var progress: Double?
        switch style {
        case .available(let version):
            accent = Theme.amber
            text = "可更新 \(version)"
            symbol = "arrow.up.circle.fill"
        case .downloading(let version, let value):
            accent = Theme.amber
            text = "下载中 \(Int(value * 100))%"
            symbol = "arrow.down.circle.fill"
            progress = value
            _ = version
        case .ready:
            accent = Theme.green
            text = "打开安装包"
            symbol = "shippingbox.fill"
        }

        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        accent.withAlphaComponent(hovered ? 0.26 : 0.14).setFill()
        path.fill()
        accent.withAlphaComponent(hovered ? 0.85 : 0.55).setStroke()
        path.lineWidth = 1
        path.stroke()

        if let progress {
            let width = max(0, min(1, progress)) * (rect.width - 2)
            if width > 2 {
                NSGraphicsContext.saveGraphicsState()
                path.addClip()
                accent.withAlphaComponent(0.18).setFill()
                NSRect(x: rect.minX + 1, y: rect.minY + 1, width: width, height: rect.height - 2).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
        }

        let icon = tintedSymbol(symbol, color: accent)
        let iconWidth = icon?.size.width ?? 0
        let gap: CGFloat = iconWidth > 0 ? 4 : 0
        let font = Theme.rounded(9.5, .semibold)
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: accent
        ]
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = .left
        attrs[.paragraphStyle] = paragraph
        let textWidth = min(
            (text as NSString).size(withAttributes: attrs).width,
            bounds.width - 18 - iconWidth - gap
        )
        let total = iconWidth + gap + textWidth
        let startX = max(8, (bounds.width - total) / 2)
        if let icon {
            icon.draw(
                in: NSRect(
                    x: startX,
                    y: (bounds.height - icon.size.height) / 2,
                    width: icon.size.width,
                    height: icon.size.height
                )
            )
        }
        (text as NSString).draw(
            in: NSRect(
                x: startX + iconWidth + gap,
                y: (bounds.height - 13) / 2,
                width: max(0, textWidth + 1),
                height: 13
            ),
            withAttributes: attrs
        )
    }

    private func tintedSymbol(_ name: String, color: NSColor) -> NSImage? {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9.5, weight: .semibold)) else { return nil }
        let image = NSImage(size: symbol.size)
        image.lockFocus()
        symbol.draw(in: NSRect(origin: .zero, size: symbol.size))
        color.setFill()
        NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}

// MARK: - Card

final class StatusCardController: NSObject {
    let panel: CardPanel
    private let root = CardBackgroundView(frame: .zero)
    private let iconView = NSImageView(frame: .zero)
    private let iconBox = NSView(frame: .zero)
    private let titleLabel = NSTextField(labelWithString: "深海任务台")
    private let subtitleLabel = NSTextField(labelWithString: "DeepSeek Harness · 本地监控")
    private let closeButton = NSButton(frame: .zero)
    private let workTile = StatTileView(frame: .zero)
    private let waitTile = StatTileView(frame: .zero)
    private let costTile = StatTileView(frame: .zero)
    private let usageStrip = UsageStripView(frame: .zero)
    private let sectionLabel = NSTextField(labelWithString: "最近任务")
    private let refreshButton = NSButton(frame: .zero)
    private let scrollView = NSScrollView(frame: .zero)
    private let listView = SessionListView(frame: .zero)
    private let footerLabel = NSTextField(labelWithString: "仅读取 ~/.dsh/sessions · 每 1.5s 刷新")
    private let revealButton = NSButton(frame: .zero)
    private let updatePill = UpdatePillView(frame: .zero)

    private var status = DSHStatus()
    private var currentSessions: [SessionSnapshot] = []
    private var isVisible = false
    private var updateState: PetUpdateState = .idle

    var onClose: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onReveal: ((String) -> Void)?
    var onOpenSession: ((SessionSnapshot) -> Void)?
    var onUpdate: (() -> Void)?

    final class CardPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    override init() {
        panel = CardPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 544),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 544))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = container

        root.frame = NSRect(x: 14, y: 14, width: 392, height: 516)
        container.addSubview(root)

        iconBox.frame = NSRect(x: 20, y: 456, width: 42, height: 42)
        iconBox.wantsLayer = true
        iconBox.layer?.cornerRadius = 12
        iconBox.layer?.backgroundColor = NSColor(srgbRed: 0.15, green: 0.34, blue: 0.62, alpha: 0.65).cgColor
        iconBox.layer?.borderColor = Theme.cyan.withAlphaComponent(0.28).cgColor
        iconBox.layer?.borderWidth = 1
        root.addSubview(iconBox)

        iconView.frame = NSRect(x: 8, y: 8, width: 26, height: 26)
        if let image = NSImage(systemSymbolName: "fish.fill", accessibilityDescription: nil) {
            iconView.image = image.withSymbolConfiguration(.init(pointSize: 18, weight: .semibold))
        }
        iconView.contentTintColor = Theme.cyan
        iconBox.addSubview(iconView)

        titleLabel.frame = NSRect(x: 74, y: 472, width: 144, height: 22)
        titleLabel.font = Theme.rounded(17, .bold)
        titleLabel.textColor = .white
        root.addSubview(titleLabel)

        subtitleLabel.frame = NSRect(x: 75, y: 454, width: 148, height: 15)
        subtitleLabel.font = Theme.rounded(10, .regular)
        subtitleLabel.textColor = Theme.muted
        root.addSubview(subtitleLabel)

        closeButton.frame = NSRect(x: 348, y: 466, width: 26, height: 26)
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .bold))
        closeButton.contentTintColor = Theme.muted
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        root.addSubview(closeButton)

        updatePill.frame = NSRect(x: 224, y: 466, width: 114, height: 24)
        updatePill.isHidden = true
        updatePill.onTap = { [weak self] in self?.onUpdate?() }
        root.addSubview(updatePill)

        workTile.frame = NSRect(x: 20, y: 374, width: 113, height: 62)
        waitTile.frame = NSRect(x: 139, y: 374, width: 113, height: 62)
        costTile.frame = NSRect(x: 258, y: 374, width: 113, height: 62)
        root.addSubview(workTile)
        root.addSubview(waitTile)
        root.addSubview(costTile)

        usageStrip.frame = NSRect(x: 20, y: 314, width: 352, height: 48)
        root.addSubview(usageStrip)

        sectionLabel.frame = NSRect(x: 20, y: 288, width: 200, height: 18)
        sectionLabel.font = Theme.rounded(12, .semibold)
        sectionLabel.textColor = Theme.ink
        root.addSubview(sectionLabel)

        refreshButton.frame = NSRect(x: 340, y: 284, width: 28, height: 24)
        refreshButton.bezelStyle = .inline
        refreshButton.isBordered = false
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        refreshButton.contentTintColor = Theme.muted
        refreshButton.target = self
        refreshButton.action = #selector(refreshTapped)
        root.addSubview(refreshButton)

        scrollView.frame = NSRect(x: 18, y: 50, width: 356, height: 232)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = listView
        listView.frame = NSRect(x: 4, y: 0, width: 344, height: 200)
        root.addSubview(scrollView)
        listView.onOpen = { [weak self] session in
            self?.onOpenSession?(session)
        }
        listView.onMenu = { [weak self] session, event in
            self?.showRowMenu(session: session, event: event)
        }

        footerLabel.frame = NSRect(x: 20, y: 20, width: 250, height: 14)
        footerLabel.font = Theme.rounded(9.5, .regular)
        footerLabel.textColor = Theme.muted.withAlphaComponent(0.85)
        root.addSubview(footerLabel)


        revealButton.frame = NSRect(x: 310, y: 14, width: 64, height: 24)
        revealButton.bezelStyle = .inline
        revealButton.isBordered = false
        revealButton.title = "打开目录"
        revealButton.font = Theme.rounded(10, .medium)
        revealButton.contentTintColor = Theme.cyan
        revealButton.target = self
        revealButton.action = #selector(revealTapped)
        root.addSubview(revealButton)

        root.alphaValue = 0
    }

    // MARK: API

    func update(_ status: DSHStatus) {
        self.status = status
        subtitleLabel.stringValue = status.dshRunning
            ? "DeepSeek Harness · 本地监控"
            : "DeepSeek Harness · 已断连"
        subtitleLabel.textColor = status.dshRunning ? Theme.muted : Theme.red
        let visible = status.recentSessions
        workTile.update(value: "\(status.workingSessions.count)", label: "干饭中的鱼", accent: Theme.cyan)
        waitTile.update(value: "\(status.attentionSessions.count)", label: "等你确认", accent: status.attentionSessions.isEmpty ? Theme.muted : Theme.amber)
        let cost: String
        if let c = status.todayCost {
            cost = String(format: "¥%.2f", c)
        } else {
            cost = "—"
        }
        let costLabel = status.todayCalls.map { "今日消耗 · \($0) 次" } ?? "今日消耗"
        costTile.update(value: cost, label: costLabel, accent: Theme.green)

        var items: [(value: String, label: String, accent: NSColor)] = []
        for quota in status.planQuotas.prefix(3) {
            let accent = quota.percent >= 80 ? Theme.red : (quota.percent >= 60 ? Theme.amber : Theme.cyan)
            items.append(("\(quota.percent)%", "\(quota.provider) \(quota.window)", accent))
        }
        if let tokens = status.todayTokens, tokens > 0 {
            items.append((compactTokens(tokens), "今日 tokens", Theme.green))
        } else if let todayCost = status.todayCost {
            items.append((String(format: "¥%.2f", todayCost), "今日花费", Theme.green))
        }
        usageStrip.update(items)
        listView.update(Array(visible.prefix(12)))
        currentSessions = visible
        footerLabel.stringValue = "点击会话跳到 DSH · 仅读取 ~/.dsh"
        if isVisible { layoutList() }
    }

    /// Called by the update checker; the pill is the only visible surface.
    func updateUpdateState(_ state: PetUpdateState) {
        updateState = state
        switch state {
        case .available(let release):
            updatePill.update(.available("v\(release.version)"))
        case .downloading(let version, let progress):
            updatePill.update(.downloading("v\(version)", progress))
        case .ready(let version, _):
            updatePill.update(.ready("v\(version)"))
        default:
            updatePill.update(nil)
        }
    }

    func show(relativeTo petFrame: NSRect) {
        position(near: petFrame)
        DebugLog.write("card show pet=\(petFrame) panel=\(panel.frame) screen=\(NSScreen.main?.visibleFrame ?? .zero)")
        isVisible = true
        panel.orderFrontRegardless()
        panel.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            root.animator().alphaValue = 1
        }
        layoutList()
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: 0))
        scrollView.reflectScrolledClipView(clip)
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
            self?.panel.alphaValue = 1
        })
    }

    var visible: Bool { isVisible }

    func reposition(relativeTo petFrame: NSRect) {
        guard isVisible else { return }
        position(near: petFrame)
    }

    // MARK: Layout / position

    private func layoutList() {
        listView.frame = NSRect(x: 4, y: 0, width: max(120, scrollView.contentView.bounds.width - 8), height: listView.frame.height)
        listView.needsLayout = true
        listView.layoutSubtreeIfNeeded()
    }

    private func position(near petFrame: NSRect) {
        let size = panel.frame.size
        let screen = NSScreen.screens.first { $0.frame.intersects(petFrame) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        var x = petFrame.maxX - size.width + 14
        var y = petFrame.maxY - size.height + 30
        let leftX = petFrame.minX - size.width - 10
        if leftX >= visible.minX + 12 {
            x = leftX
        } else if petFrame.maxY + size.height + 6 <= visible.maxY - 8 {
            y = petFrame.maxY + 6
        } else if petFrame.minY - size.height - 10 >= visible.minY + 8 {
            y = petFrame.minY - size.height - 10
        }
        y = max(visible.minY + 10, min(y, visible.maxY - size.height - 8))
        x = max(visible.minX + 8, min(x, visible.maxX - size.width - 8))
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: Actions

    @objc private func closeTapped() {
        onClose?()
    }

    @objc private func refreshTapped() {
        onRefresh?()
    }

    @objc private func revealTapped() {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dsh/sessions")
        NSWorkspace.shared.open(url)
    }

    private func showRowMenu(session: SessionSnapshot, event: NSEvent) {
        let menu = NSMenu()
        let jump = NSMenuItem(title: "跳到 DSH 会话", action: nil, keyEquivalent: "")
        jump.representedObject = session.id
        jump.target = self
        jump.action = #selector(menuJump(_:))
        menu.addItem(jump)
        let open = NSMenuItem(title: "在 Finder 中打开工作区", action: nil, keyEquivalent: "")
        open.representedObject = session.cwd
        open.target = self
        open.action = #selector(menuOpen(_:))
        menu.addItem(open)
        let copyID = NSMenuItem(title: "复制会话 ID", action: nil, keyEquivalent: "")
        copyID.representedObject = session.shortID
        copyID.target = self
        copyID.action = #selector(menuCopy(_:))
        menu.addItem(copyID)
        let copyLog = NSMenuItem(title: "复制日志路径", action: nil, keyEquivalent: "")
        copyLog.representedObject = session.logPath
        copyLog.target = self
        copyLog.action = #selector(menuCopy(_:))
        menu.addItem(copyLog)
        guard let view = panel.contentView else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    @objc private func menuJump(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let session = currentSessions.first(where: { $0.id == id }) else { return }
        onOpenSession?(session)
    }

    @objc private func menuOpen(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func menuCopy(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
