import SwiftUI
import UIKit

private final class ParsedContent: NSObject {
    let blocks: [ContentBlock]
    init(_ text: String) { blocks = ContentParser.parse(text) }
}
private enum ContentCache {
    static let cache: NSCache<NSString, ParsedContent> = {
        let value = NSCache<NSString, ParsedContent>(); value.countLimit = 512; value.totalCostLimit = 8 * 1024 * 1024; return value
    }()
    static func blocks(_ text: String) -> [ContentBlock] {
        let key = text as NSString
        if let value = cache.object(forKey: key) { return value.blocks }
        let value = ParsedContent(text); cache.setObject(value, forKey: key, cost: text.utf8.count * 3); return value.blocks
    }
}

private final class StyledInline: NSObject {
    let value: AttributedString
    init(_ value: AttributedString) { self.value = value }
}

private enum InlineEmphasis {
    static let cache: NSCache<NSString, StyledInline> = {
        let value = NSCache<NSString, StyledInline>(); value.countLimit = 6000; value.totalCostLimit = 12 * 1024 * 1024; return value
    }()
    static func styled(_ value: String) -> AttributedString {
        let key = value as NSString
        if let cached = cache.object(forKey: key) { return cached.value }
        var result = (try? AttributedString(markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(value)
        for run in result.runs {
            if run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true { result[run.range].foregroundColor = Color(red: 0.18, green: 0.36, blue: 0.77) }
            if run.inlinePresentationIntent?.contains(.code) == true { result[run.range].font = .system(size: 13, design: .monospaced); result[run.range].backgroundColor = Color.blue.opacity(0.07) }
        }
        cache.setObject(StyledInline(result), forKey: key, cost: value.utf8.count * 8 + 128)
        return result
    }
}

/// Called during background decoding, before UIKit asks a scrolling cell to render.
/// NSCache is thread safe; user text is kept in memory only and is never persisted here.
enum MessageRenderPreparation {
    static func prepare(_ messages: [Message]) {
        for message in messages {
            for block in ContentCache.blocks(message.text) {
                switch block {
                case .paragraph(let text), .heading(_, let text), .listItem(_, let text, _), .quote(let text): _ = InlineEmphasis.styled(text)
                case .table(let rows): for row in rows { for text in row { _ = InlineEmphasis.styled(text) } }
                case .code, .divider: break
                }
            }
        }
    }
}

struct RichMessageText: View, Equatable {
    let text: String
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.text == rhs.text }
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            ForEach(Array(ContentCache.blocks(text).enumerated()), id: \.offset) { _, block in blockView(block) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder private func blockView(_ block: ContentBlock) -> some View {
        switch block {
        case .paragraph(let text): inline(text).font(.system(size: 16)).lineSpacing(5)
        case .heading(let level, let text):
            inline(text).font(.system(size: level == 1 ? 23 : level == 2 ? 20 : 17, weight: .semibold)).foregroundStyle(Color(red: 0.18, green: 0.31, blue: 0.58)).lineSpacing(4).padding(.top, 5)
        case .listItem(let marker, let text, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker).foregroundStyle(.secondary).frame(minWidth: 15, alignment: .leading)
                inline(text).font(.system(size: 15)).lineSpacing(5).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.leading, CGFloat(indent) * 13)
        case .quote(let text):
            HStack(alignment: .top, spacing: 11) { RoundedRectangle(cornerRadius: 2).fill(Color.blue.opacity(0.45)).frame(width: 3); inline(text).font(.system(size: 15)).lineSpacing(5).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }.fixedSize(horizontal: false, vertical: true).padding(12).background(Color.blue.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
        case .code(let language, let code): CodeBlockView(language: language, code: code)
        case .table(let rows): MarkdownTableView(rows: rows)
        case .divider: Rectangle().fill(Color.primary.opacity(0.10)).frame(height: 1).padding(.vertical, 4)
        }
    }
    private func inline(_ value: String) -> Text {
        Text(InlineEmphasis.styled(value))
    }
}

private struct CodeBlockView: View {
    let language: String
    let code: String
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text(language.isEmpty ? "代码" : language).font(.caption); Spacer(); Button { UIPasteboard.general.string = code; copied = true } label: { Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc").font(.caption) } }.foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 9)
            Divider()
            ScrollView(.horizontal, showsIndicators: true) { Text(code).font(.system(size: 12, design: .monospaced)).lineSpacing(4).textSelection(.enabled).fixedSize(horizontal: true, vertical: false).padding(12) }
        }.background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10)).overlay { RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.07), lineWidth: 1) }
    }
}

private struct MarkdownTableView: View {
    let rows: [[String]]
    private var columns: Int { rows.first?.count ?? 0 }
    var body: some View {
        Group {
            if columns <= 2 { table }
            else { ScrollView(.horizontal, showsIndicators: true) { table.frame(width: CGFloat(columns) * 168) } }
        }.background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 11)).overlay { RoundedRectangle(cornerRadius: 11).stroke(Color.primary.opacity(0.10), lineWidth: 1) }.clipShape(RoundedRectangle(cornerRadius: 11))
    }
    private var table: some View {
        VStack(spacing: 0) {
            ForEach(rows.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: 0) {
                    ForEach(0..<columns, id: \.self) { column in
                        cell(rows[index][column], header: index == 0).frame(width: columns == 2 && column == 0 ? 82 : nil, alignment: .leading).frame(maxWidth: columns == 2 && column == 0 ? nil : .infinity, alignment: .leading)
                    }
                }.background(index == 0 ? Color.blue.opacity(0.065) : index % 2 == 0 ? Color.primary.opacity(0.018) : .clear)
                if index < rows.count - 1 { Divider().opacity(0.6) }
            }
        }
    }
    private func cell(_ value: String, header: Bool) -> some View {
        Text(InlineEmphasis.styled(value)).font(.system(size: 14, weight: header ? .semibold : .regular)).lineSpacing(4).textSelection(.enabled).padding(.horizontal, 11).padding(.vertical, 11).fixedSize(horizontal: false, vertical: true)
    }
}
