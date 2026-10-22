import AppKit
import QuartzCore

// MARK: - Art

enum SpriteArt {
    private static var cache: [String: NSImage] = [:]

    static func image(named name: String) -> NSImage? {
        if let cached = cache[name] { return cached }
        var url = Bundle.main.url(forResource: name, withExtension: "png")
        if url == nil {
            let candidates = [
                URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Assets/\(name).png"),
                URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("project/myself/dshpeg/Assets/\(name).png")
            ]
            url = candidates.first { FileManager.default.fileExists(atPath: $0.path) }
        }
        guard let url, let image = NSImage(contentsOf: url) else { return nil }
        cache[name] = image
        return image
    }

    static func cgImage(_ image: NSImage) -> CGImage? {
        var rect = NSRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    static func bubbleTexture() -> CGImage? {
        let size = NSSize(width: 64, height: 64)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()
        let path = NSBezierPath(ovalIn: NSRect(x: 5, y: 5, width: 54, height: 54))
        NSColor(srgbRed: 0.72, green: 0.94, blue: 1.0, alpha: 0.20).setFill()
        path.fill()
        NSColor(srgbRed: 0.72, green: 0.94, blue: 1.0, alpha: 0.85).setStroke()
        path.lineWidth = 3.0
        path.stroke()
        let shine = NSBezierPath(ovalIn: NSRect(x: 17, y: 31, width: 13, height: 10))
        NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.75).setFill()
        shine.fill()
        let dot = NSBezierPath(ovalIn: NSRect(x: 38, y: 18, width: 6, height: 6))
        NSColor(srgbRed: 0.85, green: 0.98, blue: 1.0, alpha: 0.55).setFill()
        dot.fill()
        image.unlockFocus()
        var rect = NSRect(origin: .zero, size: size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    static func sparkleTexture() -> CGImage? {
        let size = NSSize(width: 64, height: 64)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 32, y: 2))
        path.curve(to: NSPoint(x: 62, y: 32), controlPoint1: NSPoint(x: 40, y: 22), controlPoint2: NSPoint(x: 42, y: 24))
        path.curve(to: NSPoint(x: 32, y: 62), controlPoint1: NSPoint(x: 42, y: 40), controlPoint2: NSPoint(x: 40, y: 42))
        path.curve(to: NSPoint(x: 2, y: 32), controlPoint1: NSPoint(x: 24, y: 42), controlPoint2: NSPoint(x: 22, y: 40))
        path.curve(to: NSPoint(x: 32, y: 2), controlPoint1: NSPoint(x: 22, y: 24), controlPoint2: NSPoint(x: 24, y: 22))
        path.close()
        NSColor.white.setFill()
        path.fill()
        image.unlockFocus()
        var rect = NSRect(origin: .zero, size: size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}

// MARK: - Chip

final class StatusChipView: NSView {
    private(set) var text = ""
    private(set) var accent = Theme.cyan
    var dotPulse = false

    override var isOpaque: Bool { false }

    func update(text: String, accent: NSColor, pulse: Bool) {
        if self.text == text, self.accent == accent, dotPulse == pulse { return }
        self.text = text
        self.accent = accent
        self.dotPulse = pulse
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    func sizeThatFits(_ maxWidth: CGFloat) -> NSSize {
        let font = Theme.rounded(11.5, .medium)
        let width = min(maxWidth, (text as NSString).size(withAttributes: [.font: font]).width + 34)
        return NSSize(width: max(56, ceil(width)), height: 26)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 13, yRadius: 13)
        Theme.panelFill.setFill()
        path.fill()
        accent.withAlphaComponent(0.30).setStroke()
        path.lineWidth = 1
        path.stroke()

        let dotRect = NSRect(x: 11, y: bounds.midY - 3, width: 6, height: 6)
        accent.setFill()
        NSBezierPath(ovalIn: dotRect).fill()
        if dotPulse {
            accent.withAlphaComponent(0.28).setStroke()
            let ring = NSBezierPath(ovalIn: dotRect.insetBy(dx: -3, dy: -3))
            ring.lineWidth = 1
            ring.stroke()
        }

        let font = Theme.rounded(11.5, .medium)
        let ps = NSMutableParagraphStyle()
        ps.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: Theme.ink,
            .paragraphStyle: ps
        ]
        let textRect = NSRect(x: 23, y: (bounds.height - font.ascender + font.descender) / 2 - 1, width: bounds.width - 32, height: 16)
        (text as NSString).draw(in: textRect, withAttributes: attrs)
    }
}

// MARK: - Bubble

final class SpeechBubbleView: NSView {
    private var titleText = ""
    private var detailText = ""
    private var metaText = ""
    private var costText = ""
    private var accent = Theme.cyan

    override var isOpaque: Bool { false }

    func configure(title: String, detail: String, meta: String = "", cost: String = "", accent: NSColor) {
        self.titleText = title
        self.detailText = detail
        self.metaText = meta
        self.costText = cost
        self.accent = accent
        needsDisplay = true
    }

    func sizeThatFits(_ maxWidth: CGFloat) -> NSSize {
        let titleFont = Theme.rounded(12.5, .semibold)
        let detailFont = Theme.rounded(11.5, .regular)
        let inset: CGFloat = 56
        let titleW = ceil((titleText as NSString).size(withAttributes: [.font: titleFont]).width)
        let detailW = detailText.isEmpty ? 0 : ceil((detailText as NSString).size(withAttributes: [.font: detailFont]).width)
        let metaW = metaText.isEmpty ? 0 : ceil((metaText as NSString).size(withAttributes: [.font: Theme.mono(10, .regular)]).width)
        let costW = costText.isEmpty ? 0 : ceil((costText as NSString).size(withAttributes: [.font: Theme.mono(10, .regular)]).width)
        let width = max(150, min(maxWidth, max(titleW, max(detailW, max(metaW, costW))) + inset))
        let textWidth = width - inset
        let titleH = ceil((titleText as NSString).boundingRect(
            with: NSSize(width: textWidth, height: 100),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: titleFont]
        ).height)
        let detailH: CGFloat = detailText.isEmpty ? 0 : ceil((detailText as NSString).boundingRect(
            with: NSSize(width: textWidth, height: 120),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: detailFont]
        ).height)
        let metaFont = Theme.mono(10, .regular)
        let metaH: CGFloat = metaText.isEmpty ? 0 : ceil((metaText as NSString).boundingRect(
            with: NSSize(width: textWidth, height: 60),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: metaFont]
        ).height)
        let costFont = Theme.mono(10, .regular)
        let costH: CGFloat = costText.isEmpty ? 0 : ceil((costText as NSString).boundingRect(
            with: NSSize(width: textWidth, height: 60),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: costFont]
        ).height)
        let height = 10 + titleH + (detailH > 0 ? 3 + detailH : 0) + (metaH > 0 ? 3 + metaH : 0) + (costH > 0 ? 3 + costH : 0) + 11 + 8
        return NSSize(width: width, height: max(48, height))
    }

    override func draw(_ dirtyRect: NSRect) {
        // Bubble body leaves 8 pt at the bottom for the tail.
        let body = NSRect(x: 1, y: 9, width: bounds.width - 2, height: bounds.height - 10)
        let radius: CGFloat = 13
        let path = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
        let tail = NSBezierPath()
        let tailX = bounds.midX
        tail.move(to: NSPoint(x: tailX - 8, y: body.minY + 1))
        tail.line(to: NSPoint(x: tailX, y: 1))
        tail.line(to: NSPoint(x: tailX + 8, y: body.minY + 1))
        tail.close()
        path.append(tail)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 14
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        shadow.set()
        Theme.panelFill.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        accent.withAlphaComponent(0.30).setStroke()
        path.lineWidth = 1
        path.stroke()

        // Accent dot
        accent.setFill()
        NSBezierPath(ovalIn: NSRect(x: 15, y: body.maxY - 20, width: 7, height: 7)).fill()

        let titleFont = Theme.rounded(12.5, .semibold)
        let detailFont = Theme.rounded(11.5, .regular)
        let textX: CGFloat = 28
        let textWidth = bounds.width - textX - 26
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: NSColor.white
        ]
        let titleH = ceil((titleText as NSString).boundingRect(
            with: NSSize(width: textWidth, height: 100),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: titleAttrs
        ).height)
        var y = body.maxY - 10 - titleH
        (titleText as NSString).draw(
            in: NSRect(x: textX, y: y, width: textWidth, height: titleH),
            withAttributes: titleAttrs
        )
        if !detailText.isEmpty {
            y -= 3
            let detailAttrs: [NSAttributedString.Key: Any] = [
                .font: detailFont,
                .foregroundColor: Theme.muted
            ]
            let detailH = ceil((detailText as NSString).boundingRect(
                with: NSSize(width: textWidth, height: 120),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: detailAttrs
            ).height)
            (detailText as NSString).draw(
                in: NSRect(x: textX, y: y - detailH, width: textWidth, height: detailH),
                withAttributes: detailAttrs
            )
            y -= detailH
        }
        // Collapse affordance: a small down chevron in the top-right corner.
        let chevron = NSBezierPath()
        let cx = body.maxX - 14
        let cy = body.maxY - 15
        chevron.move(to: NSPoint(x: cx - 4, y: cy + 2.5))
        chevron.line(to: NSPoint(x: cx, y: cy - 2))
        chevron.line(to: NSPoint(x: cx + 4, y: cy + 2.5))
        chevron.lineWidth = 1.6
        chevron.lineCapStyle = .round
        NSColor.white.withAlphaComponent(0.55).setStroke()
        chevron.stroke()

        if !metaText.isEmpty {
            y -= 3
            let metaFont = Theme.mono(10, .regular)
            let metaAttrs: [NSAttributedString.Key: Any] = [
                .font: metaFont,
                .foregroundColor: Theme.muted.withAlphaComponent(0.9)
            ]
            let metaH = ceil((metaText as NSString).boundingRect(
                with: NSSize(width: textWidth, height: 60),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: metaAttrs
            ).height)
            (metaText as NSString).draw(
                in: NSRect(x: textX, y: y - metaH, width: textWidth, height: metaH),
                withAttributes: metaAttrs
            )
            y -= metaH
        }
        if !costText.isEmpty {
            y -= 3
            let costFont = Theme.mono(10, .regular)
            let costAttrs: [NSAttributedString.Key: Any] = [
                .font: costFont,
                .foregroundColor: Theme.green.withAlphaComponent(0.95)
            ]
            let costH = ceil((costText as NSString).boundingRect(
                with: NSSize(width: textWidth, height: 60),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: costAttrs
            ).height)
            (costText as NSString).draw(
                in: NSRect(x: textX, y: y - costH, width: textWidth, height: costH),
                withAttributes: costAttrs
            )
        }
    }
}

// MARK: - Sprite

final class PetSpriteView: NSView {
    private let glowLayer = CAGradientLayer()
    private let contactShadow = CAGradientLayer()
    private let floatLayer = CALayer()
    private let leanLayer = CALayer()
    private let swayLayer = CALayer()
    private let imageLayer = CALayer()
    private let bubbleEmitter = CAEmitterLayer()
    private let sparkleEmitter = CAEmitterLayer()
    private let badgeLayer = CALayer()
    private let badgeText = CATextLayer()
    private var zzzLayers: [CATextLayer] = []
    private var currentMood: PetMood = .idle
    private var currentImageName: String?
    private var currentScale: CGFloat = 1
    private var lastImageSize: NSSize = .zero
    private var walkFacingLeft = false
    private var walkLean: CGFloat = 0
    private var swayAngle: CGFloat = 0.014
    private var swayDuration: TimeInterval = 4.2
    private lazy var actionManager = PetActionManager(sprite: self)

    private(set) var imageRect: NSRect = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        setupLayers()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let w = bounds.width
        glowLayer.frame = NSRect(x: (w - 220) / 2, y: 30, width: 220, height: 220)
        contactShadow.frame = NSRect(x: w / 2 - 62, y: 2, width: 124, height: 16)
        contactShadow.position = CGPoint(x: w / 2, y: 10)
        floatLayer.position = CGPoint(x: w / 2, y: 18)
        layoutSprite(scale: currentScale)
        bubbleEmitter.emitterPosition = CGPoint(x: w / 2, y: 34)
        sparkleEmitter.emitterPosition = CGPoint(x: w / 2, y: 120)
        positionZzz()
    }

    private func setupLayers() {
        wantsLayer = true
        guard let root = layer else { return }

        glowLayer.type = .radial
        glowLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        glowLayer.endPoint = CGPoint(x: 1.0, y: 1.0)
        glowLayer.opacity = 0.5
        root.addSublayer(glowLayer)

        contactShadow.type = .radial
        contactShadow.startPoint = CGPoint(x: 0.5, y: 0.5)
        contactShadow.endPoint = CGPoint(x: 1.0, y: 1.0)
        contactShadow.colors = [
            NSColor.black.withAlphaComponent(0.42).cgColor,
            NSColor.black.withAlphaComponent(0.0).cgColor
        ]
        contactShadow.opacity = 1
        root.addSublayer(contactShadow)

        floatLayer.anchorPoint = CGPoint(x: 0.5, y: 0)
        floatLayer.bounds = CGRect(x: 0, y: 0, width: 220, height: 230)
        root.addSublayer(floatLayer)

        leanLayer.anchorPoint = CGPoint(x: 0.5, y: 0)
        leanLayer.bounds = CGRect(x: 0, y: 0, width: 220, height: 230)
        leanLayer.position = CGPoint(x: 110, y: 0)
        floatLayer.addSublayer(leanLayer)

        swayLayer.anchorPoint = CGPoint(x: 0.5, y: 0)
        swayLayer.bounds = CGRect(x: 0, y: 0, width: 220, height: 230)
        swayLayer.position = CGPoint(x: 110, y: 0)
        leanLayer.addSublayer(swayLayer)

        imageLayer.contentsGravity = .resizeAspect
        imageLayer.magnificationFilter = .trilinear
        imageLayer.minificationFilter = .trilinear
        imageLayer.shadowColor = NSColor(srgbRed: 0.015, green: 0.04, blue: 0.10, alpha: 1).cgColor
        imageLayer.shadowOpacity = 0.30
        imageLayer.shadowRadius = 9
        imageLayer.shadowOffset = CGSize(width: 0, height: -2)
        swayLayer.addSublayer(imageLayer)

        bubbleEmitter.emitterShape = .line
        bubbleEmitter.emitterMode = .surface
        bubbleEmitter.emitterSize = CGSize(width: 96, height: 1)
        let bubble = CAEmitterCell()
        bubble.contents = SpriteArt.bubbleTexture()
        bubble.birthRate = 1
        bubble.lifetime = 4.2
        bubble.velocity = 15
        bubble.velocityRange = 9
        bubble.yAcceleration = 4
        bubble.emissionLongitude = .pi / 2
        bubble.emissionRange = .pi / 5
        bubble.scale = 0.34
        bubble.scaleRange = 0.16
        bubble.scaleSpeed = 0.05
        bubble.alphaSpeed = -0.24
        bubble.spin = 0.6
        bubble.spinRange = 1.2
        bubble.color = Theme.cyan.withAlphaComponent(0.85).cgColor
        bubbleEmitter.emitterCells = [bubble]
        bubbleEmitter.birthRate = 0
        root.addSublayer(bubbleEmitter)

        sparkleEmitter.emitterShape = .circle
        sparkleEmitter.emitterMode = .surface
        sparkleEmitter.emitterSize = CGSize(width: 170, height: 120)
        sparkleEmitter.renderMode = .additive
        let sparkle = CAEmitterCell()
        sparkle.contents = SpriteArt.sparkleTexture()
        sparkle.birthRate = 1
        sparkle.lifetime = 1.3
        sparkle.velocity = 42
        sparkle.velocityRange = 26
        sparkle.emissionRange = .pi * 2
        sparkle.scale = 0.26
        sparkle.scaleRange = 0.18
        sparkle.scaleSpeed = -0.12
        sparkle.alphaSpeed = -0.9
        sparkle.color = Theme.amber.withAlphaComponent(0.95).cgColor
        sparkleEmitter.emitterCells = [sparkle]
        sparkleEmitter.birthRate = 0
        root.addSublayer(sparkleEmitter)

        badgeLayer.backgroundColor = Theme.amber.cgColor
        badgeLayer.cornerRadius = 12
        badgeLayer.shadowColor = NSColor.black.cgColor
        badgeLayer.shadowOpacity = 0.4
        badgeLayer.shadowRadius = 5
        badgeLayer.shadowOffset = NSSize(width: 0, height: -2)
        badgeLayer.isHidden = true
        badgeText.string = "!"
        badgeText.font = Theme.rounded(14, .bold)
        badgeText.fontSize = 14
        badgeText.alignmentMode = .center
        badgeText.foregroundColor = NSColor.white.cgColor
        badgeText.frame = CGRect(x: 0, y: 4, width: 24, height: 18)
        badgeLayer.addSublayer(badgeText)
        root.addSublayer(badgeLayer)

        // Sprite layers must never animate implicitly: a fading `contents`
        // change is exactly the ghosting/trailing image seen while walking.
        let noImplicit: [String: CAAction] = [
            "contents": NSNull(),
            "transform": NSNull(),
            "frame": NSNull(),
            "bounds": NSNull(),
            "position": NSNull()
        ]
        imageLayer.actions = noImplicit
        floatLayer.actions = noImplicit
        leanLayer.actions = noImplicit
        swayLayer.actions = noImplicit
    }

    private func layoutSprite(scale requestedScale: CGFloat? = nil) {
        guard let name = currentImageName, let image = SpriteArt.image(named: name), image.size.height > 0 else { return }
        let maxH: CGFloat = 224
        let maxW: CGFloat = 310
        let moodScale = requestedScale ?? currentScale
        let scale = min(maxH / image.size.height, maxW / image.size.width) * moodScale
        let width = image.size.width * scale
        let height = image.size.height * scale
        floatLayer.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        leanLayer.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        leanLayer.position = CGPoint(x: width / 2, y: 0)
        swayLayer.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        swayLayer.position = CGPoint(x: width / 2, y: 0)
        imageLayer.frame = CGRect(x: 0, y: 0, width: width, height: height)
        imageRect = NSRect(x: (bounds.width - width) / 2, y: 18, width: width, height: height)
        if let cg = SpriteArt.cgImage(image) {
            imageLayer.contentsScale = window?.backingScaleFactor ?? 2
            imageLayer.contents = cg
        }
        lastImageSize = image.size
        badgeLayer.frame = CGRect(x: bounds.width / 2 + width / 2 - 36, y: 18 + height - 20, width: 24, height: 24)
        badgeText.frame = CGRect(x: 0, y: 4, width: 24, height: 18)
        contactShadow.frame = CGRect(x: bounds.width / 2 - width * 0.33, y: 2, width: width * 0.66, height: 16)
        positionZzz()
    }

    // MARK: - Action rendering (driven by PetActionManager)

    func setMood(_ mood: PetMood, animated: Bool) {
        actionManager.setMood(mood, animated: animated)
    }

    func startWalking() {
        actionManager.startWalking()
    }

    func stopWalking() {
        walkLean = 0
        walkFacingLeft = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        leanLayer.transform = CATransform3DIdentity
        imageLayer.transform = CATransform3DIdentity
        CATransaction.commit()
        actionManager.stopWalking()
    }

    func setWalkDirection(dx: CGFloat, dy: CGFloat = 0) {
        guard actionManager.isWalking else { return }
        let magnitude = max(0.0001, (dx * dx + dy * dy).squareRoot())
        let nx = dx / magnitude
        let ny = dy / magnitude

        if nx > 0.25, walkFacingLeft {
            walkFacingLeft = false
            setFacing(mirrored: false)
        } else if nx < -0.25, !walkFacingLeft {
            walkFacingLeft = true
            setFacing(mirrored: true)
        }

        // Lean into the current movement direction, horizontal first.
        let lean: CGFloat
        if abs(nx) >= abs(ny) {
            lean = max(-0.09, min(0.09, -nx * 0.085))
        } else {
            lean = max(-0.06, min(0.06, -ny * 0.05))
        }
        if abs(lean - walkLean) > 0.002 {
            walkLean = lean
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            leanLayer.transform = CATransform3DMakeRotation(lean, 0, 0, 1)
            CATransaction.commit()
        }
    }

    private func setFacing(mirrored: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.transform = mirrored ? CATransform3DMakeScale(-1, 1, 1) : CATransform3DIdentity
        CATransaction.commit()
    }

    /// Configure the sprite for a new action: frames, motion, badge, particles.
    func applyAction(_ action: PetAction, tintMood: PetMood, animated: Bool) {
        currentMood = tintMood
        imageLayer.opacity = Float(action.opacity)
        let previous = currentImageName
        let first = action.frames.first ?? "pet_idle"
        if animated, previous != nil, previous != first {
            let transition = CATransition()
            transition.type = .fade
            transition.duration = 0.22
            transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
            imageLayer.add(transition, forKey: "contents")
        }
        currentImageName = first
        currentScale = action.scale
        layoutSprite(scale: action.scale)
        applyMoodToLayers(tintMood)
        restartAnimations(
            bobAmplitude: action.bobAmplitude,
            bobDuration: action.bobDuration,
            swayAngle: action.swayAngle,
            swayDuration: action.swayDuration
        )
        setBadge(action.badge)
        setZzz(action.showsZzz)
        setParticles(action.particles)
        bubbleEmitter.opacity = action.showsZzz ? 0.2 : 1
    }

    /// Swap one frame inside the current action. The frame canvases and the
    /// display scale stay identical, so nothing shifts.
    func applyFrame(_ frameName: String, animated: Bool) {
        guard frameName != currentImageName else { return }
        let newImage = SpriteArt.image(named: frameName)
        let sizeChanged = newImage?.size != lastImageSize
        // Aligned frames swap instantly - a cross-fade here would ghost the
        // legs and read as flicker.
        imageLayer.removeAnimation(forKey: "contents")
        currentImageName = frameName
        if sizeChanged {
            layoutSprite(scale: currentScale)
        } else if let cg = newImage.flatMap({ SpriteArt.cgImage($0) }) {
            imageLayer.contents = cg
        }
    }

    private func applyMoodToLayers(_ mood: PetMood) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.45)
        imageLayer.shadowColor = mood.tint.cgColor
        imageLayer.shadowOpacity = mood == .sleeping ? 0.18 : 0.33
        imageLayer.shadowRadius = mood == .waiting ? 26 : 19
        contactShadow.opacity = mood == .happy ? 0.18 : 0.30
        let colors = [
            mood.tint.withAlphaComponent(mood == .working ? 0.22 : 0.14).cgColor,
            mood.tint.withAlphaComponent(0.0).cgColor
        ]
        glowLayer.colors = colors
        CATransaction.commit()
        glowLayer.opacity = mood == .sleeping ? 0.05 : 0.16
    }

    private func restartAnimations(
        bobAmplitude: CGFloat,
        bobDuration: TimeInterval,
        swayAngle: CGFloat,
        swayDuration: TimeInterval
    ) {
        floatLayer.removeAnimation(forKey: "bob")
        let base: CGFloat = 18
        floatLayer.position = CGPoint(x: bounds.midX, y: base)

        let bob = CAKeyframeAnimation(keyPath: "position.y")
        bob.values = [base, base + bobAmplitude, base, base + bobAmplitude * 0.45, base]
        bob.keyTimes = [0, 0.25, 0.5, 0.75, 1]
        bob.duration = bobDuration
        bob.repeatCount = .infinity
        bob.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        floatLayer.add(bob, forKey: "bob")

        self.swayAngle = swayAngle
        self.swayDuration = swayDuration
        applySway()
    }

    /// Sway around a small bias so the pet leans toward the drag direction.
    private func applySway() {
        swayLayer.removeAnimation(forKey: "sway")
        let sway = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        sway.values = [0, swayAngle, 0, -swayAngle, 0]
        sway.keyTimes = [0, 0.25, 0.5, 0.75, 1]
        sway.duration = swayDuration
        sway.repeatCount = .infinity
        sway.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        swayLayer.add(sway, forKey: "sway")
    }

    func bounce() {
        let animation = CAKeyframeAnimation(keyPath: "transform.scale.y")
        animation.values = [1.0, 0.94, 1.035, 1.0]
        animation.keyTimes = [0, 0.25, 0.6, 1]
        animation.duration = 0.42
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        floatLayer.add(animation, forKey: "bounce")
    }

    private func playEntrance() {
        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = [1.0, 0.97, 1.02, 1.0]
        pop.keyTimes = [0, 0.3, 0.7, 1]
        pop.duration = 0.32
        swayLayer.add(pop, forKey: "pop")
    }

    func playJump() {
        let jump = CAKeyframeAnimation(keyPath: "position.y")
        let base = floatLayer.position.y
        jump.values = [base, base + 26, base + 4, base + 12, base]
        jump.keyTimes = [0, 0.3, 0.55, 0.75, 1]
        jump.duration = 0.75
        jump.timingFunction = CAMediaTimingFunction(name: .easeOut)
        floatLayer.add(jump, forKey: "jump")
        sparkleBurst()
    }

    func playShake() {
        let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
        shake.values = [0, -7, 7, -5, 5, -2, 0]
        shake.keyTimes = [0, 0.15, 0.3, 0.45, 0.6, 0.8, 1]
        shake.duration = 0.5
        floatLayer.add(shake, forKey: "shake")
    }

    private func setParticles(_ kind: PetParticleKind) {
        switch kind {
        case .none:
            bubbleEmitter.birthRate = 0
            sparkleEmitter.birthRate = 0
        case .slowBubbles:
            bubbleEmitter.birthRate = 0.35
            sparkleEmitter.birthRate = 0
        case .fastBubbles:
            bubbleEmitter.birthRate = 1.0
            sparkleEmitter.birthRate = 0
        case .sparkles:
            bubbleEmitter.birthRate = 0.35
            sparkleBurst()
        }
    }

    func sparkleBurst() {
        sparkleEmitter.birthRate = 1.4
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            self?.sparkleEmitter.birthRate = 0
        }
    }

    private func setBadge(_ kind: PetBadgeKind) {
        let show: Bool
        let color: NSColor
        let text: String
        let shouldPulse: Bool
        switch kind {
        case .none: show = false; color = Theme.amber; text = "!"; shouldPulse = false
        case .alert: show = true; color = Theme.amber; text = "!"; shouldPulse = true
        case .error: show = true; color = Theme.red; text = "!"; shouldPulse = true
        case .disconnected: show = true; color = Theme.red; text = "!"; shouldPulse = false
        }
        badgeLayer.isHidden = !show
        guard show else { return }
        badgeLayer.backgroundColor = color.cgColor
        badgeText.string = text
        badgeLayer.removeAnimation(forKey: "pulse")
        guard shouldPulse else { return }
        let pulse = CABasicAnimation(keyPath: "transform.scale")
        pulse.fromValue = 0.9
        pulse.toValue = 1.12
        pulse.duration = 0.7
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        badgeLayer.add(pulse, forKey: "pulse")
    }

    private func setZzz(_ on: Bool) {
        if !on {
            zzzLayers.forEach { $0.removeFromSuperlayer() }
            zzzLayers.removeAll()
            return
        }
        guard zzzLayers.isEmpty, let root = layer else { return }
        for i in 0..<3 {
            let layer = CATextLayer()
            layer.string = i == 1 ? "Z" : "z"
            layer.font = Theme.rounded(11 + CGFloat(i) * 3, .bold)
            layer.fontSize = 11 + CGFloat(i) * 3
            layer.foregroundColor = NSColor.white.withAlphaComponent(0.75).cgColor
            layer.alignmentMode = .center
            layer.frame = CGRect(x: 0, y: 0, width: 24, height: 20)
            let start = NSRect(x: bounds.width / 2 + 30 + CGFloat(i) * 13, y: 180 + CGFloat(i) * 8, width: 20, height: 18)
            layer.position = CGPoint(x: start.midX, y: start.midY)
            layer.opacity = 0
            root.addSublayer(layer)
            zzzLayers.append(layer)
        }
        positionZzz()
        animateZzz()
    }

    private func positionZzz() {
        guard !zzzLayers.isEmpty else { return }
        for (i, layer) in zzzLayers.enumerated() {
            let start = NSRect(x: bounds.width / 2 + 28 + CGFloat(i) * 14, y: 176 + CGFloat(i) * 6, width: 20, height: 18)
            layer.position = CGPoint(x: start.midX, y: start.midY)
        }
    }

    private func animateZzz() {
        for (i, layer) in zzzLayers.enumerated() {
            let move = CABasicAnimation(keyPath: "position.y")
            let base = layer.position.y
            move.fromValue = base
            move.toValue = base + 34
            move.duration = 3.6
            move.beginTime = CACurrentMediaTime() + Double(i) * 0.7
            move.repeatCount = .infinity
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 0.9, 0.0]
            fade.keyTimes = [0, 0.3, 1]
            fade.duration = 3.6
            fade.beginTime = move.beginTime
            fade.repeatCount = .infinity
            layer.add(move, forKey: "rise")
            layer.add(fade, forKey: "fade")
        }
    }

    /// A very small cursor-aware lean, so the pet feels present.
    func lean(toward point: NSPoint?) {
        guard let point else {
            swayLayer.removeAnimation(forKey: "lean")
            return
        }
        let center = CGPoint(x: bounds.midX, y: 120)
        let offset = max(-5, min(5, (point.x - center.x) * 0.03))
        let animation = CABasicAnimation(keyPath: "position.x")
        animation.fromValue = (swayLayer.presentation()?.position.x ?? swayLayer.position.x)
        animation.toValue = swayLayer.position.x + offset
        animation.duration = 0.45
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        swayLayer.add(animation, forKey: "lean")
    }
}

// MARK: - Stage

final class PetStageView: NSView {
    let sprite = PetSpriteView(frame: .zero)
    let chip = StatusChipView(frame: .zero)
    let bubble = SpeechBubbleView(frame: .zero)

    var onToggleCard: (() -> Void)?
    var onToggleBubble: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onDragEnded: (() -> Void)?
    var onContextMenu: ((NSEvent) -> Void)?
    private var pendingClick: DispatchWorkItem?

    private var bubbleVisible = false
    private var bubbleHideWork: DispatchWorkItem?
    private var dragStartMouse = NSPoint.zero
    private var dragStartOrigin = NSPoint.zero
    private var dragTarget: NSPoint?
    private var motionTimer: Timer?
    private var isDragging = false
    private var lastDragMouse = NSPoint.zero
    private var smoothedVelocity = NSPoint.zero
    private var didDrag = false
    private var isMouseInside = false
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(sprite)
        addSubview(chip)
        addSubview(bubble)
        bubble.alphaValue = 0
        bubble.isHidden = true
        chip.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let w = bounds.width
        sprite.frame = NSRect(x: (w - 320) / 2, y: 12, width: 320, height: 248)
        layoutChip()
        layoutBubble()
    }

    private func layoutChip() {
        let size = chip.sizeThatFits(320)
        let spriteTop = sprite.convert(sprite.imageRect, to: self).maxY
        let y = min(250, spriteTop + 16)
        let rect = NSRect(x: (bounds.width - size.width) / 2, y: y, width: size.width, height: size.height)
        chip.frame = rect
    }

    private func layoutBubble() {
        let size = bubble.sizeThatFits(356)
        let rect = NSRect(x: (bounds.width - size.width) / 2, y: 252, width: size.width, height: size.height)
        bubble.frame = rect
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let local = convert(point, from: superview)
        if bubbleVisible, bubble.frame.contains(local) { return self }
        if chip.frame.contains(local) { return self }
        let spriteHit = sprite.convert(sprite.imageRect, to: self).insetBy(dx: -8, dy: -6)
        if spriteHit.contains(local) { return self }
        return nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isMouseInside = true
        NSCursor.pointingHand.push()
    }

    override func mouseExited(with event: NSEvent) {
        isMouseInside = false
        NSCursor.pop()
        sprite.lean(toward: nil)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if sprite.imageRect.insetBy(dx: -30, dy: -30).contains(point) {
            sprite.lean(toward: point)
        } else {
            sprite.lean(toward: nil)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.type == .rightMouseDown { return }
        dragStartMouse = NSEvent.mouseLocation
        dragStartOrigin = window?.frame.origin ?? .zero
        dragTarget = nil
        didDrag = false
        isDragging = false
        lastDragMouse = NSEvent.mouseLocation
        smoothedVelocity = .zero
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let now = NSEvent.mouseLocation
        // Per-event movement (smoothed) decides which way the pet faces, so
        // turning around mid-drag flips it immediately even if the pointer is
        // still left of where the drag started.
        let stepX = now.x - lastDragMouse.x
        let stepY = now.y - lastDragMouse.y
        lastDragMouse = now
        smoothedVelocity.x = smoothedVelocity.x * 0.6 + stepX * 0.4
        smoothedVelocity.y = smoothedVelocity.y * 0.6 + stepY * 0.4

        let dx = now.x - dragStartMouse.x
        let dy = now.y - dragStartMouse.y
        if abs(dx) + abs(dy) > 2 {
            if !didDrag {
                NSCursor.closedHand.set()
                sprite.startWalking()
                layoutChip()
            }
            didDrag = true
            isDragging = true
            startMotionTimer()
        }
        sprite.setWalkDirection(dx: smoothedVelocity.x, dy: smoothedVelocity.y)

        var target = NSPoint(x: dragStartOrigin.x + dx, y: dragStartOrigin.y + dy)
        if let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            let size = window.frame.size
            target.x = max(visible.minX - 20, min(target.x, visible.maxX - size.width + 20))
            target.y = max(visible.minY - 20, min(target.y, visible.maxY - size.height + 20))
        }
        dragTarget = target
    }

    // MARK: - Smooth drag motion

    /// The window chases the pointer on a 60 Hz timer instead of jumping on
    /// every mouse event, so the pet glides instead of stuttering.
    private func startMotionTimer() {
        guard motionTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.stepMotion()
        }
        RunLoop.main.add(timer, forMode: .common)
        motionTimer = timer
    }

    private func stepMotion() {
        guard let window, let target = dragTarget else {
            stopMotionTimer()
            return
        }
        var origin = window.frame.origin
        let dx = target.x - origin.x
        let dy = target.y - origin.y
        if abs(dx) < 0.5, abs(dy) < 0.5 {
            window.setFrameOrigin(target)
            if !isDragging {
                stopMotionTimer()
                finishDrag()
            }
            return
        }
        origin.x += dx * 0.22
        origin.y += dy * 0.22
        window.setFrameOrigin(origin)
    }

    private func stopMotionTimer() {
        motionTimer?.invalidate()
        motionTimer = nil
    }

    private func finishDrag() {
        snapToEdge()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.onDragEnded?()
        }
    }

    deinit {
        motionTimer?.invalidate()
    }

    override func mouseUp(with event: NSEvent) {
        if didDrag {
            isDragging = false
            sprite.stopWalking()
            layoutChip()
            // The motion timer keeps gliding to the drop point, then snaps.
            if motionTimer == nil { finishDrag() }
            return
        }
        if event.clickCount >= 2 {
            pendingClick?.cancel()
            pendingClick = nil
            onDoubleClick?()
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let click = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingClick = nil
            if self.bubbleVisible, self.bubble.frame.contains(point) {
                self.onToggleBubble?()
                return
            }
            if !self.chip.isHidden, self.chip.frame.contains(point) {
                self.onToggleBubble?()
                return
            }
            self.onToggleCard?()
        }
        pendingClick?.cancel()
        pendingClick = click
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: click)
    }

    override func rightMouseDown(with event: NSEvent) {
        onContextMenu?(event)
    }

    private func snapToEdge() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var frame = window.frame
        let margin: CGFloat = 16
        if abs(frame.minX - visible.minX) < 30 { frame.origin.x = visible.minX + margin }
        if abs(visible.maxX - frame.maxX) < 30 { frame.origin.x = visible.maxX - frame.width - margin }
        if abs(frame.minY - visible.minY) < 30 { frame.origin.y = visible.minY + margin }
        if abs(visible.maxY - frame.maxY) < 30 { frame.origin.y = visible.maxY - frame.height - margin }
        if frame.origin != window.frame.origin {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().setFrame(frame, display: true)
            }
        }
    }

    func showChip(_ text: String, accent: NSColor, pulse: Bool) {
        chip.update(text: text, accent: accent, pulse: pulse)
        chip.isHidden = bubbleVisible || text.isEmpty
        layoutChip()
    }

    func hideChip() {
        chip.isHidden = true
    }

    func showBubble(title: String, detail: String, meta: String = "", cost: String = "", accent: NSColor, autoHide: TimeInterval?) {
        bubbleHideWork?.cancel()
        bubble.configure(title: title, detail: detail, meta: meta, cost: cost, accent: accent)
        layoutBubble()
        bubble.isHidden = false
        bubbleVisible = true
        chip.isHidden = true
        bubble.alphaValue = 0
        bubble.frame.origin.y = bubble.frame.origin.y - 6
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            bubble.animator().alphaValue = 1
            bubble.animator().setFrameOrigin(NSPoint(x: bubble.frame.origin.x, y: bubble.frame.origin.y + 6))
        }
        if let autoHide {
            let work = DispatchWorkItem { [weak self] in self?.hideBubble() }
            bubbleHideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + autoHide, execute: work)
        }
    }

    /// Update the visible bubble in place (used by the persistent "working"
    /// bubble so the elapsed timer ticks without re-playing the fade-in).
    func updateBubble(title: String, detail: String, meta: String = "", cost: String = "", accent: NSColor) {
        guard bubbleVisible else {
            showBubble(title: title, detail: detail, meta: meta, cost: cost, accent: accent, autoHide: nil)
            return
        }
        bubbleHideWork?.cancel()
        bubbleHideWork = nil
        bubble.configure(title: title, detail: detail, meta: meta, cost: cost, accent: accent)
        layoutBubble()
        bubble.needsDisplay = true
        chip.isHidden = true
    }

    func hideBubble() {
        bubbleHideWork?.cancel()
        bubbleHideWork = nil
        guard bubbleVisible else { return }
        bubbleVisible = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            bubble.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.bubbleVisible else { return }
            self.bubble.isHidden = true
        })
        chip.isHidden = chip.text.isEmpty
    }

    var isBubbleVisible: Bool { bubbleVisible }

    /// Union of the parts that should accept a click, in stage coordinates.
    var interactiveRect: NSRect {
        var rect = sprite.convert(sprite.imageRect, to: self).insetBy(dx: -10, dy: -8)
        if !chip.isHidden {
            rect = rect.union(chip.frame.insetBy(dx: -4, dy: -4))
        }
        if bubbleVisible {
            rect = rect.union(bubble.frame)
        }
        return rect
    }
}
