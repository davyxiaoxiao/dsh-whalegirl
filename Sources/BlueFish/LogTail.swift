import Foundation

/// Locates and runs the bundled zstd helper. DSH compresses its session logs;
/// future adapters that use plain JSONL can ignore this and use `LogTail`.
enum ZstdTool {
    static let executablePath: String? = findExecutable()

    static func decompress(_ data: Data) -> Data? {
        guard let zstd = executablePath else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: zstd)
        process.arguments = ["-dc", "-q"]
        let inPipe = Pipe()
        let outPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        DispatchQueue.global(qos: .utility).async {
            do {
                try inPipe.fileHandleForWriting.write(contentsOf: data)
                try inPipe.fileHandleForWriting.close()
            } catch {
                try? inPipe.fileHandleForWriting.close()
            }
        }
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return out.isEmpty ? nil : out
    }

    private static func findExecutable() -> String? {
        var candidates: [String] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("zstd-helper").path)
        }
        if let executable = Bundle.main.executableURL {
            candidates.append(executable.deletingLastPathComponent().appendingPathComponent("zstd-helper").path)
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        candidates.append(cwd.appendingPathComponent("build/zstd-helper").path)
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/zstd",
            "/usr/local/bin/zstd",
            "/usr/bin/zstd",
            "/opt/local/bin/zstd"
        ])
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// Small tail-reading helpers shared by log-based adapters.
///
/// Reading only the tail keeps a poll at a few milliseconds even when the log
/// is tens of megabytes: callers pass the file size they already stat'ed.
enum LogTail {
    static func readTail(url: URL, size: UInt64, limit: Int) -> Data {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? fh.close() }
        let start = size > UInt64(limit) ? size - UInt64(limit) : 0
        do {
            try fh.seek(toOffset: start)
            return fh.readDataToEndOfFile()
        } catch {
            return Data()
        }
    }

    /// Byte offsets of zstd frame magic numbers (28 B5 2F FD) in `data`.
    static func frameOffsets(in data: Data) -> [Int] {
        guard data.count >= 4 else { return [] }
        var offsets: [Int] = []
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let n = data.count - 3
            var i = 0
            while i < n {
                if base[i] == 0x28, base[i + 1] == 0xB5, base[i + 2] == 0x2F, base[i + 3] == 0xFD {
                    offsets.append(i)
                    i += 4
                } else {
                    i += 1
                }
            }
        }
        return offsets
    }

    /// Parse one JSON object per line from decompressed zstd output.
    static func jsonObjects(fromDecompressed data: Data, maxEvents: Int = 800) -> [[String: Any]] {
        var events: [[String: Any]] = []
        for line in data.split(separator: 0x0A) where line.count > 8 {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            events.append(obj)
        }
        if events.count > maxEvents { return Array(events.suffix(maxEvents)) }
        return events
    }

    /// Read the tail of a plain (uncompressed) JSONL log. The first partial line
    /// is dropped when the read starts mid-file.
    static func readJSONLines(
        url: URL,
        size: UInt64,
        limit: Int = 256 * 1024,
        maxEvents: Int = 600,
        maxLineBytes: Int = 8 * 1024 * 1024
    ) -> [[String: Any]]? {
        let data = readTail(url: url, size: size, limit: limit)
        guard !data.isEmpty else { return nil }
        var lines = data.split(separator: 0x0A)
        if size > UInt64(limit), lines.count > 1 {
            lines.removeFirst()
        }
        return jsonObjects(lines: lines, maxEvents: maxEvents, maxLineBytes: maxLineBytes)
    }

    /// Read complete JSONL records from the beginning of a file. Used for
    /// session metadata, which lives in the first line (or first few lines).
    static func readJSONLinesFromHead(
        url: URL,
        limit: Int = 256 * 1024,
        maxEvents: Int = 40,
        maxLineBytes: Int = 8 * 1024 * 1024
    ) -> [[String: Any]]? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let data = try? fh.read(upToCount: limit), !data.isEmpty else { return nil }
        var lines = data.split(separator: 0x0A)
        if data.last != 0x0A, lines.count > 1 {
            lines.removeLast()
        }
        return jsonObjects(lines: lines, maxEvents: maxEvents, maxLineBytes: maxLineBytes)
    }

    private static func jsonObjects(
        lines: [Data.SubSequence],
        maxEvents: Int,
        maxLineBytes: Int
    ) -> [[String: Any]]? {
        var events: [[String: Any]] = []
        for line in lines where line.count > 8 && line.count <= maxLineBytes {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            events.append(obj)
        }
        guard !events.isEmpty else { return nil }
        if events.count > maxEvents { return Array(events.suffix(maxEvents)) }
        return events
    }
}
