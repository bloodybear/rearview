import Foundation

/// Temporary, opt-in investigation trace. Never accepts source/translated text or images.
/// A launch-time expiry and event cap keep recording bounded; normal profiling is unchanged.
final class PresentationTrace: @unchecked Sendable {
    static let shared = PresentationTrace()
    static let schemaVersion = 1
    static let maximumEvents = 20_000
    private let lock = NSLock()
    private let expiry = UserDefaults.standard.double(forKey: "diagnostics.presentationTraceUntil")
    private var count = 0
    private var handle: FileHandle?

    var enabled: Bool { expiry > Date().timeIntervalSince1970 }

    static func rect(_ rect: CGRect) -> [Any] {
        [rect.minX, rect.minY, rect.width, rect.height].map { value in
            value.isFinite ? (Double(value) as Any) : String(describing: value)
        }
    }

    func record(_ event: String, _ fields: [String: Any] = [:]) {
        guard enabled else { return }
        lock.lock()
        defer { lock.unlock() }
        guard count < Self.maximumEvents else { return }

        if handle == nil {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("RearviewPresentationTrace", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            let url = directory.appendingPathComponent(UUID().uuidString + ".jsonl")
            guard FileManager.default.createFile(atPath: url.path, contents: nil),
                  let opened = try? FileHandle(forWritingTo: url) else { return }
            handle = opened
        }

        var payload = fields
        payload["schema"] = Self.schemaVersion
        payload["event"] = event
        payload["sequence"] = count
        payload["uptime"] = ProcessInfo.processInfo.systemUptime
        guard var data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        else { return }
        data.append(10)
        try? handle?.write(contentsOf: data)
        count += 1
    }
}
