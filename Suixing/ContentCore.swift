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

enum ContentBlock: Equatable {
    case paragraph(String)
    case heading(Int, String)
    case listItem(String, String, Int)
    case quote(String)
    case code(String, String)
    case table([[String]])
    case divider
}

enum ContentParser {
    private static let heading = try! NSRegularExpression(pattern: "^(#{1,6})\\s+(.+?)(?:\\s+#+)?$")
    private static let list = try! NSRegularExpression(pattern: "^(\\s*)([-+*]|[0-9]+[.)])\\s+(.+)$")
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
            return stripped.count >= 3 && stripped.allSatisfy { $0 == "-" }
        }
    }
    static func parse(_ source: String) -> [ContentBlock] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var result: [ContentBlock] = [], paragraph: [String] = [], index = 0
        func flush() { if !paragraph.isEmpty { result.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] } }
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
            if ["---", "***", "___"].contains(line.replacingOccurrences(of: " ", with: "")) { flush(); result.append(.divider); index += 1; continue }
            if line.hasPrefix(">") {
                flush(); var quotes: [String] = []
                while index < lines.count && lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quotes.append(String(lines[index].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces)); index += 1
                }
                result.append(.quote(quotes.joined(separator: "\n"))); continue
            }
            if let values = groups(list, raw) {
                flush(); let prefix = ["-", "*", "+"].contains(values[1]) ? "•" : values[1]
                var text = values[2]; index += 1
                while index < lines.count && lines[index].hasPrefix("  ") && groups(list, lines[index]) == nil && !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    text += "\n" + lines[index].trimmingCharacters(in: .whitespaces); index += 1
                }
                result.append(.listItem(prefix, text, min(4, values[0].count / 2))); continue
            }
            paragraph.append(raw); index += 1
        }
        flush(); return result
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
