import Foundation
import CoreGraphics

struct NotificationDestination {
    let engine: String
    let threadId: String?
    static func parse(_ url: URL) -> NotificationDestination? {
        guard url.scheme == "suixing", url.host == "chat", url.user == nil, url.password == nil,
              url.path.isEmpty || url.path == "/", let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let engines = (parts.queryItems ?? []).filter { $0.name == "engine" }, ids = (parts.queryItems ?? []).filter { $0.name == "id" }
        guard engines.count == 1, let engine = engines.first?.value, ["codex", "dsh", "workbuddy"].contains(engine), ids.count <= 1 else { return nil }
        let id = ids.first?.value
        if let id { guard !id.isEmpty, id.count <= 160, id.range(of: "^[-_A-Za-z0-9]+$", options: .regularExpression) != nil else { return nil } }
        return NotificationDestination(engine: engine, threadId: id)
    }
}

struct NamedTerm: Equatable {
    let name: String
    let explanation: String
}

enum ContentBlock: Equatable {
    case paragraph(String)
    case heading(Int, String)
    case listItem(String, String, Int)
    case quote(String)
    case code(String, String)
    case table([[String]])
    case divider
    case image(String, String)
    case attachment(String, String)
    case callout(String, String)
    case terms([NamedTerm])
    case sequence([String])
}

enum TechnicalName {
    private static let file = try! NSRegularExpression(pattern: #"\.(?:md|markdown|ya?ml|json|toml|ini|cfg|txt|csv|tsv|py|js|mjs|cjs|tsx?|jsx|swift|html|css|sh|ps1|cmd|bat|sql|xml|pdf|docx?|xlsx?|pptx?|png|jpe?g|gif|webp|mp4|mov|wav|mp3)(?::\d+(?::\d+)?)?$"#, options: .caseInsensitive)
    static func label(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 180, !value.contains("\n"), !value.contains("://") else { return nil }
        if (value.hasSuffix("/") || value.hasSuffix("\\")) && !value.contains(" ") { return "目录" }
        if file.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil {
            return value.contains("*") || value.contains("?") ? "文件规则" : "文件"
        }
        if !value.contains(" "), value.contains("/") || value.contains("\\") { return "路径" }
        return nil
    }
}

enum ContentParser {
    private static let heading = try! NSRegularExpression(pattern: "^(#{1,6})\\s+(.+?)(?:\\s+#+)?$")
    private static let list = try! NSRegularExpression(pattern: "^(\\s*)([-+*•](?=\\s)|[0-9]+\\.(?=\\s)|[0-9]+[、)）]|[一二三四五六七八九十]+[、)）])\\s*(.+)$")
    private static let standaloneBold = try! NSRegularExpression(pattern: "^\\*\\*([^*\\n]{1,80})\\*\\*[:：]?$")
    private static func groups(_ expression: NSRegularExpression, _ line: String) -> [String]? {
        let ns = line as NSString
        guard let match = expression.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (1..<match.numberOfRanges).map { ns.substring(with: match.range(at: $0)) }
    }
    static func cells(_ line: String) -> [String] {
        var result: [String] = [], current = "", escaped = false, inlineCode = false
        for character in line.trimmingCharacters(in: .whitespaces) {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\" { current.append(character); escaped = true; continue }
            if character == "`" { inlineCode.toggle() }
            if character == "|" && !inlineCode { result.append(current.trimmingCharacters(in: .whitespaces)); current = "" }
            else { current.append(character) }
        }
        result.append(current.trimmingCharacters(in: .whitespaces))
        if result.first == "" { result.removeFirst() }
        if result.last == "" { result.removeLast() }
        return result
    }
    private static func isTableRule(_ line: String) -> Bool {
        let columns = cells(line)
        return columns.count >= 2 && columns.allSatisfy { value in
            let stripped = value.replacingOccurrences(of: ":", with: "").trimmingCharacters(in: .whitespaces)
            return stripped.count >= 2 && stripped.allSatisfy { $0 == "-" }
        }
    }
    static func parse(_ source: String) -> [ContentBlock] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var result: [ContentBlock] = [], paragraph: [String] = [], index = 0
        func flush() {
            guard !paragraph.isEmpty else { return }
            let text = paragraph.joined(separator: "\n")
            let labels = ["注意：", "提醒：", "重要：", "结论：", "提示：", "警告："]
            if let terms = namedTerms(text) { result.append(.terms(terms)) }
            else if let steps = sequenceSteps(text) { result.append(.sequence(steps)) }
            else if let label = labels.first(where: { text.hasPrefix($0) }) {
                result.append(.callout(String(label.dropLast()), String(text.dropFirst(label.count)).trimmingCharacters(in: .whitespacesAndNewlines)))
            } else { result.append(.paragraph(text)) }
            paragraph = []
        }
        while index < lines.count {
            let raw = lines[index], line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); index += 1; continue }
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                flush(); let fence = String(line.prefix(3)), language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                index += 1; var code: [String] = []
                while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) { code.append(lines[index]); index += 1 }
                if index < lines.count { index += 1 }
                result.append(.code(language, code.joined(separator: "\n"))); continue
            }
            if index + 1 < lines.count && line.contains("|") && isTableRule(lines[index + 1]) {
                flush(); let header = cells(raw); var rows = [header]; index += 2
                while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces).isEmpty && lines[index].contains("|") {
                    var row = cells(lines[index]); if row.count < header.count { row += Array(repeating: "", count: header.count - row.count) }
                    rows.append(Array(row.prefix(header.count))); index += 1
                }
                result.append(.table(rows)); continue
            }
            if let values = groups(heading, line) { flush(); result.append(.heading(values[0].count, values[1])); index += 1; continue }
            if let values = groups(standaloneBold, line) { flush(); result.append(.heading(3, values[0])); index += 1; continue }
            if let image = imageLine(line) { flush(); result.append(.image(image.0, image.1)); index += 1; continue }
            if line.hasPrefix("["), line.hasSuffix(")"), let marker = line.range(of: "](suixing-file:") {
                flush(); result.append(.attachment(String(line[line.index(after: line.startIndex)..<marker.lowerBound]), String(line[marker.upperBound..<line.index(before: line.endIndex)]))); index += 1; continue
            }
            if ["---", "***", "___"].contains(line.replacingOccurrences(of: " ", with: "")) { flush(); result.append(.divider); index += 1; continue }
            if line.hasPrefix(">") {
                flush(); var quotes: [String] = []
                while index < lines.count && lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quotes.append(String(lines[index].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces)); index += 1
                }
                result.append(.quote(quotes.joined(separator: "\n"))); continue
            }
            if let values = groups(list, raw) {
                flush(); var prefix = ["-", "*", "+", "•"].contains(values[1]) ? "•" : values[1]
                var text = values[2]; index += 1
                if text.hasPrefix("[x] ") || text.hasPrefix("[X] ") { prefix = "✓"; text = String(text.dropFirst(4)) }
                else if text.hasPrefix("[ ] ") { prefix = "○"; text = String(text.dropFirst(4)) }
                while index < lines.count && lines[index].prefix(while: { $0 == " " }).count > values[0].count && groups(list, lines[index]) == nil && groups(heading, lines[index].trimmingCharacters(in: .whitespaces)) == nil && !lines[index].trimmingCharacters(in: .whitespaces).isEmpty && !lines[index].contains("```") && !lines[index].contains("~~~") && !(index + 1 < lines.count && isTableRule(lines[index+1])) {
                    text += "\n" + lines[index].trimmingCharacters(in: .whitespaces); index += 1
                }
                result.append(.listItem(prefix, text, min(4, values[0].count / 2))); continue
            }
            paragraph.append(raw); index += 1
        }
        flush(); return result
    }
    private static func splitOutsideCode(_ text: String, on separator: Character) -> [String]? {
        guard !text.contains("\n\n"), !text.contains("``") else { return nil }
        var pieces: [String] = [], current = "", inCode = false
        for character in text {
            if character == "`" { inCode.toggle() }
            if character == separator && !inCode { pieces.append(current.trimmingCharacters(in: .whitespacesAndNewlines)); current = "" }
            else { current.append(character) }
        }
        guard !inCode else { return nil }
        pieces.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        return pieces
    }
    private static func namedTerms(_ text: String) -> [NamedTerm]? {
        guard text.contains("·"), let pieces = splitOutsideCode(text, on: "·"), (3...40).contains(pieces.count) else { return nil }
        var terms: [NamedTerm] = []
        for piece in pieces {
            guard piece.first == "`", let end = piece.dropFirst().firstIndex(of: "`") else { return nil }
            let name = String(piece[piece.index(after: piece.startIndex)..<end])
            guard !name.isEmpty, name.count < 180, !name.contains("\n") else { return nil }
            var explanation = String(piece[piece.index(after: end)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if (explanation.hasPrefix("（") && explanation.hasSuffix("）")) || (explanation.hasPrefix("(") && explanation.hasSuffix(")")) { explanation = String(explanation.dropFirst().dropLast()) }
            terms.append(NamedTerm(name: name, explanation: explanation))
        }
        return terms
    }
    private static func sequenceSteps(_ text: String) -> [String]? {
        guard text.contains("→"), text.count < 2000, let pieces = splitOutsideCode(text, on: "→"), (4...20).contains(pieces.count), pieces.allSatisfy({ !$0.isEmpty && $0.count < 240 }) else { return nil }
        return pieces
    }
    private static func imageLine(_ line: String) -> (String, String)? {
        guard line.hasPrefix("!["), line.hasSuffix(")"), let separator = line.range(of: "](") else { return nil }
        let caption = String(line[line.index(line.startIndex, offsetBy: 2)..<separator.lowerBound])
        var target = String(line[separator.upperBound..<line.index(before: line.endIndex)]).trimmingCharacters(in: .whitespaces)
        if target.hasPrefix("<"), target.hasSuffix(">") { target = String(target.dropFirst().dropLast()) }
        guard target.hasPrefix("suixing-image:") else { return nil }
        return (caption, String(target.dropFirst("suixing-image:".count)))
    }
}

struct TranscriptOutlineMessage {
    let role: String
    let phase: String?
    let hasMedia: Bool
}
enum TranscriptOutlineItem: Equatable {
    case message(Int)
    case progress(Int, [Int])
}
enum TranscriptOutline {
    static func make(_ messages: [TranscriptOutlineMessage], busy: Bool) -> [TranscriptOutlineItem] {
        var output: [TranscriptOutlineItem] = [], index = 0
        while index < messages.count {
            guard messages[index].role == "user" else { output.append(.message(index)); index += 1; continue }
            let start = index
            output.append(.message(start)); index += 1
            var end = index
            while end < messages.count && messages[end].role != "user" { end += 1 }
            let lastAssistant = (index..<end).last(where: { messages[$0].role == "assistant" })
            let active = busy && end == messages.count
            let folded = (index..<end).filter { i in
                let m = messages[i]
                return m.role == "assistant" && !m.hasMedia && m.phase != "final_answer" && (m.phase == "commentary" || active || i != lastAssistant)
            }
            let foldedSet = Set(folded)
            for i in index..<end {
                if i == folded.first { output.append(.progress(start, folded)) }
                if !foldedSet.contains(i) { output.append(.message(i)) }
            }
            index = end
        }
        return output
    }
}

enum ContentGeometry {
    static func remaining(window: Double?, used: Double?) -> Double? {
        guard let window, let used, window.isFinite, used.isFinite, window > 0, used >= 0 else { return nil }
        return max(0, window - used)
    }
    static func cropRect(start: CGPoint, end: CGPoint, imageBounds: CGRect) -> CGRect? {
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y)).intersection(imageBounds)
        return !rect.isNull && rect.width >= 16 && rect.height >= 16 ? rect : nil
    }
    static func imageRect(in size: CGSize, image: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0, image.width > 0, image.height > 0 else { return .zero }
        let scale = min(size.width / image.width, size.height / image.height)
        let width = image.width * scale, height = image.height * scale
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }
}
