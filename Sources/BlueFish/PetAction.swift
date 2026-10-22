import AppKit

// MARK: - Action model

enum PetBadgeKind {
    case none
    case alert
    case error
    case disconnected
}

enum PetParticleKind {
    case none
    case slowBubbles
    case fastBubbles
    case sparkles
}

/// One named animation the pet can play. The action table is the single place
/// that describes frames, timing, motion and decorations, so adding a new
/// animation only means adding one entry here.
struct PetAction {
    let id: String
    let frames: [String]
    let frameInterval: TimeInterval
    let scale: CGFloat
    let bobAmplitude: CGFloat
    let bobDuration: TimeInterval
    let swayAngle: CGFloat
    let swayDuration: TimeInterval
    let badge: PetBadgeKind
    let particles: PetParticleKind
    let showsZzz: Bool
    let mood: PetMood
    var opacity: CGFloat = 1

    static func mood(_ mood: PetMood) -> PetAction {
        switch mood {
        case .idle:
            return PetAction(id: "idle", frames: ["pet_idle"], frameInterval: 0, scale: 1,
                             bobAmplitude: 5, bobDuration: 3.0,
                             swayAngle: 0.014, swayDuration: 4.2,
                             badge: .none, particles: .slowBubbles, showsZzz: false, mood: .idle)
        case .working:
            return PetAction(id: "work", frames: ["pet_work"], frameInterval: 0, scale: 0.85,
                             bobAmplitude: 3.5, bobDuration: 1.45,
                             swayAngle: 0.020, swayDuration: 2.4,
                             badge: .none, particles: .fastBubbles, showsZzz: false, mood: .working)
        case .waiting:
            return PetAction(id: "wait", frames: ["pet_idle"], frameInterval: 0, scale: 1,
                             bobAmplitude: 2.5, bobDuration: 2.2,
                             swayAngle: 0.014, swayDuration: 4.2,
                             badge: .alert, particles: .none, showsZzz: false, mood: .waiting)
        case .happy:
            return PetAction(id: "happy", frames: ["pet_happy"], frameInterval: 0, scale: 1,
                             bobAmplitude: 6, bobDuration: 1.1,
                             swayAngle: 0.014, swayDuration: 4.2,
                             badge: .none, particles: .sparkles, showsZzz: false, mood: .happy)
        case .panic:
            return PetAction(id: "panic", frames: ["pet_panic"], frameInterval: 0, scale: 1,
                             bobAmplitude: 4, bobDuration: 0.55,
                             swayAngle: 0.030, swayDuration: 2.4,
                             badge: .error, particles: .none, showsZzz: false, mood: .panic)
        case .sleeping:
            return PetAction(id: "sleep", frames: ["pet_idle"], frameInterval: 0, scale: 1,
                             bobAmplitude: 7, bobDuration: 4.4,
                             swayAngle: 0.012, swayDuration: 4.2,
                             badge: .none, particles: .slowBubbles, showsZzz: true, mood: .sleeping)
        case .offline:
            return PetAction(id: "offline", frames: ["pet_idle"], frameInterval: 0, scale: 1,
                             bobAmplitude: 2, bobDuration: 4.2,
                             swayAngle: 0.010, swayDuration: 5.0,
                             badge: .disconnected, particles: .none, showsZzz: false, mood: .offline,
                             opacity: 0.72)
        }
    }

    /// Three-frame drag walk: contact left / passing / contact right.
    static let walk = PetAction(
        id: "walk",
        frames: ["pet_walk_a", "pet_walk_b", "pet_walk_c"],
        frameInterval: 0.2,
        scale: 1.0,
        bobAmplitude: 2.2,
        bobDuration: 0.3,
        swayAngle: 0.02,
        swayDuration: 0.6,
        badge: .none,
        particles: .slowBubbles,
        showsZzz: false,
        mood: .idle
    )
}

// MARK: - Manager

/// Drives which action is playing and steps through its frames. The sprite view
/// stays a dumb renderer: `applyAction` configures it, `applyFrame` swaps one
/// frame. While the pet is being dragged the walk action wins; mood updates are
/// remembered and restored when the drag ends.
final class PetActionManager {
    private weak var sprite: PetSpriteView?
    private(set) var current: PetAction = PetAction.mood(.idle)
    private(set) var isWalking = false
    private var pendingMood: PetMood = .idle
    private var frameIndex = 0
    private var frameTimer: Timer?

    init(sprite: PetSpriteView) {
        self.sprite = sprite
    }

    deinit {
        frameTimer?.invalidate()
    }

    func setMood(_ mood: PetMood, animated: Bool) {
        pendingMood = mood
        guard !isWalking else { return }
        play(PetAction.mood(mood), animated: animated)
    }

    func startWalking() {
        guard !isWalking else { return }
        isWalking = true
        play(.walk, animated: false, tintMood: pendingMood)
    }

    func stopWalking() {
        guard isWalking else { return }
        isWalking = false
        play(PetAction.mood(pendingMood), animated: false)
    }

    private func play(_ action: PetAction, animated: Bool, tintMood: PetMood? = nil) {
        current = action
        frameIndex = 0
        frameTimer?.invalidate()
        frameTimer = nil
        sprite?.applyAction(action, tintMood: tintMood ?? action.mood, animated: animated)
        guard action.frames.count > 1, action.frameInterval > 0 else { return }
        let timer = Timer(timeInterval: action.frameInterval, repeats: true) { [weak self] _ in
            self?.advanceFrame()
        }
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
    }

    private func advanceFrame() {
        guard current.frames.count > 1 else { return }
        frameIndex = (frameIndex + 1) % current.frames.count
        sprite?.applyFrame(current.frames[frameIndex], animated: true)
    }
}
