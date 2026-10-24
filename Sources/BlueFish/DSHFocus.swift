import AppKit
import ApplicationServices

/// Jumps to a session inside the running DeepSeek Harness desktop app.
///
/// The desktop shell only handles `dsh://open` (focus the window); it has no
/// public deep link for a specific session and the web GUI keeps its selection
/// in memory. So we bring the app forward and use the macOS Accessibility API
/// to find the session entry in its sidebar and click it. The first use asks
/// for Accessibility permission; without it we fall back to copying the
/// session name and focusing the app.
enum DSHFocus {
    struct Outcome {
        let ok: Bool
        let message: String
    }

    static func jump(to session: AgentSession, currentWorkspace: String?, completion: @escaping (Outcome) -> Void) {
        DispatchQueue.main.async {
            guard let app = NSRunningApplication
                .runningApplications(withBundleIdentifier: "com.deepseek.dsh")
                .first(where: { !$0.isTerminated }) else {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.deepseek.dsh") {
                    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
                    completion(Outcome(ok: false, message: "DSH 桌面版没开着，先帮你打开"))
                } else {
                    completion(Outcome(ok: false, message: "没找到 DSH 桌面版"))
                }
                return
            }

            bringToFront(pid: app.processIdentifier)

            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.4) {
                let outcome = focus(session, pid: app.processIdentifier, currentWorkspace: currentWorkspace)
                DispatchQueue.main.async { completion(outcome) }
            }
        }
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Ask macOS for Accessibility permission (shows the system prompt once).
    static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Make sure DSH is actually visible, not just running in the background.
    private static func bringToFront(pid: pid_t) {
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.unhide()
            app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        for window in allWindows(element) {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
    }

    /// Dump the DSH window's AX tree (no menu bar) for diagnosing the sidebar.
    static func dumpAXTree() {
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.deepseek.dsh")
            .first(where: { !$0.isTerminated }) else {
            return
        }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        enableAccessibility(appElement)
        let window = allWindows(appElement).first ?? appElement
        let windowFrame = frame(of: window) ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        var lines = ["window=\(windowFrame)"]
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 9000, lines.count < 1200 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            guard depth <= 36 else { continue }
            let role = string(element, kAXRoleAttribute) ?? "?"
            let text = textOf(element)
            let f = frame(of: element).map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "-"
            if !text.isEmpty {
                lines.append("\(role) | \(f) | \(text)")
            }
            for child in children(element) {
                queue.append((child, depth + 1))
            }
        }
        try? lines.joined(separator: "\n").write(
            toFile: NSHomeDirectory() + "/.dsh/storages/bluefish-ax.txt",
            atomically: true,
            encoding: .utf8
        )
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Accessibility walk

    /// Chromium/Electron does not publish the web content's AX tree until an
    /// assistive client asks for it. This attribute flips that switch.
    private static func enableAccessibility(_ app: AXUIElement) {
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        Thread.sleep(forTimeInterval: 0.7)
    }

    private static func focus(_ session: AgentSession, pid: pid_t, currentWorkspace: String?) -> Outcome {
        guard AXIsProcessTrusted() else {
            DispatchQueue.main.async { requestPermission() }
            copyToPasteboard(session.displayTitle)
            return Outcome(ok: false, message: "跳转需要「辅助功能」权限；会话名已复制，授权后重试")
        }

        bringToFront(pid: pid)
        let appElement = AXUIElementCreateApplication(pid)
        enableAccessibility(appElement)
        let keys = searchKeys(session)
        var windows = allWindows(appElement)
        if windows.isEmpty { windows = [appElement] }
        let window = windows[0]
        let windowFrame = frame(of: window) ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)

        // The task board spans every workspace, but the DSH sidebar only lists
        // sessions of the workspace it currently has open. Switch first, then
        // look for the session; otherwise the lookup can never succeed.
        let crossWorkspace = (currentWorkspace ?? "").isEmpty == false
            && !session.workspaceName.isEmpty
            && currentWorkspace != session.workspaceName
        var switched = false
        if crossWorkspace {
            switched = switchWorkspace(
                target: session.workspaceName,
                current: currentWorkspace ?? "",
                app: appElement,
                windowFrame: windowFrame
            )
            if switched {
                Thread.sleep(forTimeInterval: 0.9)
                windows = allWindows(appElement)
                if windows.isEmpty { windows = [appElement] }
            }
        }

        if let match = searchWindows(windows, keys: keys, windowFrame: windowFrame) {
            if press(match.element) || click(match.element) {
                Thread.sleep(forTimeInterval: 0.35)
                bringToFront(pid: pid)
                return Outcome(ok: true, message: "跳到「\(tail(session.displayTitle, 12))」啦")
            }
            copyToPasteboard(session.displayTitle)
            return Outcome(ok: false, message: "找到了会话但没能点开；名字已复制")
        }

        copyToPasteboard(session.displayTitle)
        dumpAX(appElement, windowFrame: windowFrame, target: session.displayTitle,
               current: currentWorkspace, wanted: session.workspaceName)
        if crossWorkspace {
            if switched {
                return Outcome(ok: false, message: "已切到「\(session.workspaceName)」工作区，但没找到会话；名字已复制")
            }
            return Outcome(ok: false, message: "这个会话在「\(session.workspaceName)」工作区；名字已复制，先在 DSH 切过去")
        }
        return Outcome(ok: false, message: "侧栏里没找到这个会话；名字已复制")
    }

    private static func searchKeys(_ session: AgentSession) -> [String] {
        var keys: [String] = []
        let title = session.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.count >= 4 { keys.append(String(title.prefix(14))) }
        if title.count >= 4 { keys.append(title) }
        keys.append(session.shortID)
        return keys
    }

    private static func searchWindows(_ windows: [AXUIElement], keys: [String], windowFrame: CGRect) -> Match? {
        var best: Match?
        for window in windows {
            if let found = search(window, keys: keys, windowFrame: windowFrame) {
                if found.score > (best?.score ?? Int.min) { best = found }
            }
        }
        return best
    }

    private static func allWindows(_ app: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement] else { return [] }
        return list
    }

    /// Press the target workspace inside DSH's workspace switcher. The switcher
    /// lives in the top-left of the sidebar; its menu items appear after opening.
    private static func switchWorkspace(target: String, current: String, app: AXUIElement, windowFrame: CGRect) -> Bool {
        if let direct = topPressableText(app, needle: target, windowFrame: windowFrame, maxTop: 280) {
            return press(direct)
        }
        guard let switcher =
                topPressableText(app, needle: current, windowFrame: windowFrame, maxTop: 170)
                ?? topPressableText(app, needle: "workspace", windowFrame: windowFrame, maxTop: 170)
                ?? topPressableText(app, needle: "工作区", windowFrame: windowFrame, maxTop: 170)
        else { return false }
        guard press(switcher) else { return false }
        Thread.sleep(forTimeInterval: 0.5)
        if let item = topPressableText(app, needle: target, windowFrame: windowFrame, maxTop: 900) {
            return press(item)
        }
        return false
    }

    private static func topPressableText(_ root: AXUIElement, needle: String, windowFrame: CGRect, maxTop: CGFloat) -> AXUIElement? {
        let wanted = normalized(needle)
        guard wanted.count >= 3 else { return nil }
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 7000 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            guard depth <= 30 else { continue }
            if pressable(element), let elementFrame = frame(of: element),
               elementFrame.minX < windowFrame.minX + windowFrame.width * 0.46,
               elementFrame.minY <= windowFrame.minY + maxTop,
               elementFrame.width > 2, elementFrame.height > 2, elementFrame.height < 120,
               normalized(textOf(element)).contains(wanted) {
                return element
            }
            for child in children(element) {
                queue.append((child, depth + 1))
            }
        }
        return nil
    }

    private static func textOf(_ element: AXUIElement) -> String {
        let attributes = [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute, kAXHelpAttribute]
        return attributes.compactMap { string(element, $0) }.joined(separator: " ")
    }

    private static func normalized(_ text: String) -> String {
        let scalars = text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func dumpAX(_ app: AXUIElement, windowFrame: CGRect, target: String, current: String?, wanted: String) {
        var lines = ["target=\(target)", "current=\(current ?? "-")", "wanted=\(wanted)"]
        let root = allWindows(app).first ?? app
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 2500, lines.count < 500 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            guard depth <= 22 else { continue }
            if let elementFrame = frame(of: element),
               elementFrame.minX < windowFrame.minX + windowFrame.width * 0.5 {
                let role = string(element, kAXRoleAttribute) ?? "?"
                let text = textOf(element)
                if !text.isEmpty || depth < 4 {
                    lines.append("\(role) | \(Int(elementFrame.minX)),\(Int(elementFrame.minY)) \(Int(elementFrame.width))x\(Int(elementFrame.height)) | \(text)")
                }
            }
            for child in children(element) {
                queue.append((child, depth + 1))
            }
        }
        try? lines.joined(separator: "\n").write(
            toFile: NSHomeDirectory() + "/.dsh/storages/bluefish-ax.txt",
            atomically: true,
            encoding: .utf8
        )
    }

    private struct Match {
        let element: AXUIElement
        let score: Int
    }

    private static func search(_ root: AXUIElement, keys: [String], windowFrame: CGRect) -> Match? {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var best: Match?
        var visited = 0

        while !queue.isEmpty, visited < 7000 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            guard depth <= 30 else { continue }

            if matches(element, keys: keys) {
                var score = 0
                if pressable(element) { score += 4 }
                if let parent = parent(of: element), pressable(parent) { score += 3 }
                if let elementFrame = frame(of: element) {
                    let inLeftPane = elementFrame.midX < windowFrame.minX + windowFrame.width * 0.42
                    if inLeftPane { score += 3 }
                    if elementFrame.height > 0, elementFrame.height < 90 { score += 1 }
                }
                if score > (best?.score ?? Int.min) {
                    best = Match(element: element, score: score)
                }
            }

            for child in children(element) {
                queue.append((child, depth + 1))
            }
        }
        return best
    }

    private static func matches(_ element: AXUIElement, keys: [String]) -> Bool {
        let haystack = normalized(textOf(element))
        guard haystack.count >= 4 else { return false }
        for key in keys {
            let needle = normalized(key)
            guard needle.count >= 4 else { continue }
            if haystack.contains(needle) { return true }
            // AX labels are often truncated ("把首页动画接进…"); allow the
            // visible label to be a prefix of the full title.
            if needle.contains(haystack), haystack.count >= 6 { return true }
        }
        return false
    }

    private static func pressable(_ element: AXUIElement) -> Bool {
        var actions: CFArray?
        guard AXUIElementCopyActionNames(element, &actions) == .success,
              let list = actions as? [String] else { return false }
        return list.contains(kAXPressAction as String)
    }

    private static func press(_ element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    private static func click(_ element: AXUIElement) -> Bool {
        guard let elementFrame = frame(of: element), elementFrame.width > 1, elementFrame.height > 1 else { return false }
        let center = CGPoint(x: elementFrame.midX, y: elementFrame.midY)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: center, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.07)
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: center, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: center, mouseButton: .left) else {
            return false
        }
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.08)
        up.post(tap: .cghidEventTap)
        return true
    }

    // MARK: - AX helpers

    private static func firstWindow(_ app: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        return windows.first
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement] else { return [] }
        return list
    }

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success,
              let raw = value, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let position = positionValue, let size = sizeValue else { return nil }
        guard CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private static func copyToPasteboard(_ text: String) {
        DispatchQueue.main.async {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
}
