import Foundation

// AX-native ownership, not formula-character detection or box merging.
// The original paragraph remains the owner of independently queried text spans.
enum MathSegments {
    struct Part { let math: Int?; var leaves: [Int] }
    static func parts(root: Int, rows: [[String: Any]], children: [Int: [Int]]) -> [Part]? {
        var result: [Part] = [], hasMath = false
        func visit(_ id: Int) {
            if rows[id]["mathOwner"] as? Int == id {
                result.append(Part(math: id, leaves: [])); hasMath = true; return
            }
            if rows[id]["role"] as? String == "AXStaticText" {
                guard !(rows[id]["recoveredText"] as? String ?? rows[id]["value"] as? String ?? "").isEmpty else { return }
                if result.last?.math == nil, !result.isEmpty { result[result.count - 1].leaves.append(id) }
                else { result.append(Part(math: nil, leaves: [id])) }
                return
            }
            for child in children[id] ?? [] { visit(child) }
        }
        visit(root)
        return hasMath ? result : nil
    }
}
