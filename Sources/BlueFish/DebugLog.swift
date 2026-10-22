import Foundation

enum DebugLog {
    static let enabled = CommandLine.arguments.contains("--log")
    static let path: String = {
        let logs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        return logs.appendingPathComponent("whalegirl.log").path
    }()

    static func write(_ text: String) {
        guard enabled else { return }
        let line = "\(Date().timeIntervalSince1970) \(text)\n"
        guard let data = line.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: path) {
            try? data.write(to: URL(fileURLWithPath: path))
            return
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        handle.seekToEndOfFile()
        try? handle.write(contentsOf: data)
        try? handle.close()
    }
}
