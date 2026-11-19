import Foundation

/// Retry missing native text data, never infer an activation Boolean from it.
package enum AXActivationReadiness {
    static let offsets: [TimeInterval] = [0.5, 1.5, 2.5]
    static func nextDelay(attemptStarted: TimeInterval, elapsed: TimeInterval) -> TimeInterval? {
        guard attemptStarted < offsets.last! else { return nil }
        let target = offsets.first { $0 > elapsed } ?? offsets.last!
        return max(0, target - elapsed)
    }
    static func wait(_ delay: TimeInterval, cancellation: AXCancellation,
                     now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                     sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval:$0) }) throws -> TimeInterval {
        let start = now(), until = start + delay
        try cancellation.check()
        while now() < until {
            try cancellation.check()
            sleep(min(0.025, max(0, until - now())))
        }
        try cancellation.check()
        return now() - start
    }
    static func documentTreeMissing(rows: [[String:Any]]) -> Bool {
        // Empty documents still expose a WebArea. Native sheets/menus do not
        // imply a missing renderer and must not trigger activation retries.
        !rows.contains { ["AXWebArea", "AXSheet", "AXDialog", "AXMenu"].contains($0["role"] as? String ?? "") ||
            ["AXDialog", "AXSystemDialog"].contains($0["subrole"] as? String ?? "") }
    }
    static let missingStatuses: Set<String> = [
        "leaf_span_unavailable", "native_source_read_failed", "native_source_empty",
        "leaf_endpoint_unavailable", "marker_range_unavailable", "marker_line_start_unavailable",
        "marker_empty_or_stalled_range", "marker_bounds_unavailable", "marker_empty_bounds",
        "reverse_empty_or_stalled_range", "no_static_text_descendants"
    ]
    static func reasons(paragraphs: [[String: Any]], truncated: Bool) -> [String] {
        guard !truncated else { return [] }
        var reasons = Set<String>()
        for paragraph in paragraphs {
            let parts = paragraph["inlineContent"] as? [[String:Any]]
            let units = parts?.filter { $0["kind"] as? String == "text" } ?? [paragraph]
            for unit in units {
                let text = (unit["lineSourceText"] ?? unit["text"]) as? String ?? ""
                guard !MathTranslationPolicy.nonrendering(text),
                      let status = unit["lineRangeStatus"] as? String,
                      missingStatuses.contains(status) else { continue }
                reasons.insert(status)
            }
        }
        return reasons.sorted()
    }
}

package enum AXReadinessError: Error {
    case visibilitySearchUnavailable(Int32)
}
