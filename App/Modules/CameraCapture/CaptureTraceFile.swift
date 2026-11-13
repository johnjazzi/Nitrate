import Foundation

/// The shared opt-in capture trace file, written by every `--trace-photo-exposure`
/// producer: the photo controller, the video session and the camera view model.
///
/// ONE file so a single pull from the device says which side owned an exposure
/// write. Two rules keep it pullable:
///
///  * Each launch starts it fresh. Appending across runs grew it past what
///    `devicectl device copy from` will transfer — it gives up at 3 MB — which is
///    exactly when the trace is needed.
///  * Past `capBytes` it rotates by starting over, so a long run keeps its most
///    recent window instead of becoming uncopyable. The interesting lines are
///    always at the end, never at the beginning.
enum CaptureTraceFile {
    private static let lock = NSLock()
    /// Guarded by `lock`; `nonisolated(unsafe)` states that to the compiler.
    nonisolated(unsafe) private static var startedThisLaunch = false
    private static let capBytes = 2_000_000

    static var isEnabled: Bool {
        CommandLine.arguments.contains("--trace-photo-exposure")
    }

    static func write(_ line: String) {
        guard isEnabled, let data = (line + "\n").data(using: .utf8) else { return }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("photo-exposure-trace.txt")
        lock.lock()
        defer { lock.unlock() }
        var reset = !startedThisLaunch
        startedThisLaunch = true
        if !reset,
           let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
           size > capBytes {
            reset = true
        }
        if reset {
            try? FileManager.default.removeItem(at: url)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let file = try? FileHandle(forWritingTo: url) else { return }
        defer { try? file.close() }
        _ = try? file.seekToEnd()
        try? file.write(contentsOf: data)
    }
}
