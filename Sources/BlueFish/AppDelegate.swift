import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: PetWindowController?
    private var pendingURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"),
           CommandLine.arguments.count > index + 1 {
            SnapshotRunner.run(directory: CommandLine.arguments[index + 1], scale: snapshotScale())
            return
        }
        let controller = PetWindowController()
        self.controller = controller
        controller.start()
        for url in pendingURLs { controller.handle(url: url) }
        pendingURLs.removeAll()
    }

    /// `--snapshot <dir> --scale 0.75` renders the pet at another size, which is
    /// handy for checking the small / large layouts without changing settings.
    private func snapshotScale() -> CGFloat {
        guard let index = CommandLine.arguments.firstIndex(of: "--scale"),
              CommandLine.arguments.count > index + 1,
              let value = Double(CommandLine.arguments[index + 1]) else { return 1 }
        return PetLayout.clampScale(CGFloat(value))
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let controller else {
            pendingURLs.append(contentsOf: urls)
            return
        }
        for url in urls { controller.handle(url: url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
    }
}
