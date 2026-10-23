import AppKit

// MARK: - Size presets

/// User-selectable pet size. Only the sprite and the layout around it scale;
/// the speech bubble keeps its font size so the task text stays readable.
enum PetSizePreset: String, CaseIterable {
    case tiny
    case small
    case standard
    case large

    var scale: CGFloat {
        switch self {
        case .tiny: return 0.6
        case .small: return 0.75
        case .standard: return 1.0
        case .large: return 1.2
        }
    }

    var name: String {
        switch self {
        case .tiny: return "迷你"
        case .small: return "小"
        case .standard: return "标准"
        case .large: return "大"
        }
    }

    var percentText: String {
        "\(Int((scale * 100).rounded()))%"
    }

    var title: String {
        "\(name) · \(percentText)"
    }

    static func nearest(to scale: CGFloat) -> PetSizePreset {
        allCases.min {
            abs($0.scale - scale) < abs($1.scale - scale)
        } ?? .standard
    }
}

// MARK: - Geometry

enum PetLayout {
    static let designWidth: CGFloat = 360
    static let designHeight: CGFloat = 400
    /// The sprite is fitted to this height at 100%.
    static let baseSpriteHeight: CGFloat = 224
    static let minimumScale: CGFloat = 0.55
    static let maximumScale: CGFloat = 1.25
    static let scaleDefaultsKey = "BlueFish.petScale"

    static func clampScale(_ scale: CGFloat) -> CGFloat {
        guard scale.isFinite, scale > 0 else { return 1 }
        return min(max(scale, minimumScale), maximumScale)
    }

    /// The window grows / shrinks by exactly the amount the sprite does, so the
    /// status chip and the speech bubble keep their usual spacing above the
    /// pet's head instead of drifting away from it.
    static func panelHeight(for scale: CGFloat) -> CGFloat {
        designHeight + baseSpriteHeight * (clampScale(scale) - 1)
    }

    static func panelSize(for scale: CGFloat) -> NSSize {
        NSSize(width: designWidth, height: panelHeight(for: scale))
    }

    static func storedScale(in defaults: UserDefaults = .standard) -> CGFloat {
        guard defaults.object(forKey: scaleDefaultsKey) != nil else { return 1 }
        return clampScale(CGFloat(defaults.double(forKey: scaleDefaultsKey)))
    }
}

// MARK: - Menu

/// Shared by the pet's context menu and the menu-bar menu so both always show
/// the same checked option.
func makePetSizeMenu(target: AnyObject, action: Selector, selected: PetSizePreset) -> NSMenuItem {
    let item = NSMenuItem(title: "宠物大小", action: nil, keyEquivalent: "")
    let submenu = NSMenu(title: "宠物大小")
    submenu.autoenablesItems = false
    for preset in PetSizePreset.allCases {
        let entry = NSMenuItem(title: preset.title, action: action, keyEquivalent: "")
        entry.target = target
        entry.representedObject = preset.rawValue
        entry.state = preset == selected ? .on : .off
        submenu.addItem(entry)
    }
    item.submenu = submenu
    return item
}
