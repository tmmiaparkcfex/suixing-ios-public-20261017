import Foundation

@main struct FileReferenceChecks {
    static func main() {
        let names = (0..<100).map { "reference-\($0).txt" }
        let texts = (0..<100).map { index in
            String(repeating: "**重点**：保留段落、表格和执行记录。\n\n", count: index == 0 ? 600 : 40) + "REFERENCE-\(index).TXT"
        }
        let oldStart = Date()
        let original = texts.map { text in names.filter { text.localizedCaseInsensitiveContains($0) } }
        let oldMS = Date().timeIntervalSince(oldStart) * 1000
        let candidates = names.map { ($0, $0.lowercased()) }
        let newStart = Date()
        let improved = texts.map { text in
            let normalized = text.lowercased() as NSString
            return candidates.compactMap { normalized.range(of: $0.1, options: .literal).location != NSNotFound ? $0.0 : nil }
        }
        let newMS = Date().timeIntervalSince(newStart) * 1000
        precondition(original == improved && improved.allSatisfy { $0.count == 1 })
        let result: [String: Any] = ["messages": texts.count, "files": names.count, "characters": texts.reduce(0) { $0 + $1.count }, "originalMilliseconds": oldMS, "optimizedMilliseconds": newMS, "sameReferences": true]
        print(String(data: try! JSONSerialization.data(withJSONObject: result, options: .sortedKeys), encoding: .utf8)!)
    }
}
