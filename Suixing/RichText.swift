import SwiftUI
import UIKit
import ImageIO

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
                case .paragraph(let text), .heading(_, let text), .listItem(_, let text, _), .quote(let text), .callout(_, let text): _ = InlineEmphasis.styled(text)
                case .table(let rows): for row in rows { for text in row { _ = InlineEmphasis.styled(text) } }
                case .code, .divider, .image: break
                }
            }
        }
    }
}

struct RichMessageText: View, Equatable {
    let text: String
    var images: [MessageImage] = []
    var engine: String = "codex"
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.text == rhs.text && lhs.images == rhs.images && lhs.engine == rhs.engine }
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            ForEach(Array(ContentCache.blocks(text).enumerated()), id: \.offset) { _, block in blockView(block) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder private func blockView(_ block: ContentBlock) -> some View {
        switch block {
        case .paragraph(let text): inline(text).font(.system(size: 17)).lineSpacing(6).fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let text):
            inline(text).font(.system(size: level == 1 ? 23 : level == 2 ? 21 : 18, weight: .bold)).foregroundStyle(Color.primary).lineSpacing(5).padding(.top, 7).fixedSize(horizontal: false, vertical: true)
        case .listItem(let marker, let text, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color(red: 0.25, green: 0.43, blue: 0.87)).frame(minWidth: 21, alignment: .leading)
                inline(text).font(.system(size: 17)).lineSpacing(6).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }.padding(.leading, CGFloat(indent) * 13)
        case .quote(let text):
            HStack(alignment: .top, spacing: 11) { RoundedRectangle(cornerRadius: 2).fill(Color.blue.opacity(0.45)).frame(width: 3); inline(text).font(.system(size: 15)).lineSpacing(5).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }.fixedSize(horizontal: false, vertical: true).padding(12).background(Color.blue.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
        case .code(let language, let code): CodeBlockView(language: language, code: code)
        case .table(let rows): MarkdownTableView(rows: rows)
        case .divider: Rectangle().fill(Color.primary.opacity(0.10)).frame(height: 1).padding(.vertical, 4)
        case .image(let caption, let id):
            if let image = images.first(where: { $0.id == id }) { ConversationImageView(image: image, engine: engine) }
            else { Label(caption.isEmpty ? "图片暂不可用，请重新同步" : caption + " · 请重新同步", systemImage: "photo").font(.callout).foregroundStyle(.secondary) }
        case .callout(let label, let text):
            VStack(alignment: .leading, spacing: 8) {
                Label(label, systemImage: label == "警告" || label == "注意" ? "exclamationmark.circle.fill" : "info.circle.fill").font(.system(size: 14, weight: .bold)).foregroundStyle(Color.blue)
                inline(text).font(.system(size: 17)).lineSpacing(6).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(13).background(Color.blue.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
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
        table.background(Color(.secondarySystemBackground).opacity(0.55), in: RoundedRectangle(cornerRadius: 12)).overlay { RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08), lineWidth: 1) }.clipShape(RoundedRectangle(cornerRadius: 12))
    }
    private var table: some View {
        VStack(spacing: 0) {
            if let header = rows.first {
                HStack(spacing: 5) { ForEach(header.indices, id: \.self) { i in if i > 0 { Text("/") }; Text(InlineEmphasis.styled(header[i])) } }.font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(13)
                Divider().opacity(0.6)
            }
            ForEach(Array(rows.dropFirst().enumerated()), id: \.offset) { index, row in
                VStack(alignment: .leading, spacing: 10) {
                    if let title = row.first { Text(InlineEmphasis.styled(title)).font(.system(size: 15, weight: .bold)).foregroundStyle(Color(red: 0.18, green: 0.36, blue: 0.77)).lineSpacing(4) }
                    ForEach(1..<max(1, row.count), id: \.self) { column in
                        VStack(alignment: .leading, spacing: 4) {
                            if columns > 2, let header = rows.first, column < header.count { Text(InlineEmphasis.styled(header[column])).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary) }
                            Text(InlineEmphasis.styled(row[column])).font(.system(size: 16)).lineSpacing(6).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                if index < rows.count - 2 { Divider().padding(.horizontal, 14).opacity(0.7) }
            }
        }
    }
    private func cell(_ value: String, header: Bool) -> some View {
        Text(InlineEmphasis.styled(value)).font(.system(size: 14, weight: header ? .semibold : .regular)).lineSpacing(4).textSelection(.enabled).padding(.horizontal, 11).padding(.vertical, 11).fixedSize(horizontal: false, vertical: true)
    }
}

private enum ConversationImageCache {
    static let images: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>(); cache.countLimit = 48; cache.totalCostLimit = 40 * 1024 * 1024; return cache
    }()
    static func thumbnail(_ bytes: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1000, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

struct ConversationImageView: View {
    @EnvironmentObject private var model: PocketModel
    let image: MessageImage
    let engine: String
    @State private var thumbnail: UIImage?
    @State private var failure: String?
    @State private var retry = 0
    private var key: String { model.server + ":" + engine + ":" + image.id }
    private var ratio: CGFloat {
        if let w = image.width, let h = image.height, w > 0, h > 0 { return min(2.2, max(0.65, w / h)) }
        return 1.35
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                if thumbnail != nil { Task { await model.previewImage(image, engine: engine) } }
                else if failure != nil { failure = nil; retry += 1 }
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground))
                    if let thumbnail { Image(uiImage: thumbnail).resizable().scaledToFit().padding(1) }
                    else if let failure { VStack(spacing: 9) { Image(systemName: "photo.badge.exclamationmark").font(.title2); Text(failure).font(.caption).multilineTextAlignment(.center); Text("点此重试").font(.caption.bold()) }.foregroundStyle(.secondary).padding(16) }
                    else { ProgressView("正在读取图片…").font(.caption) }
                }.aspectRatio(ratio, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 12)).overlay { RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08), lineWidth: 1) }
            }.buttonStyle(.plain).accessibilityIdentifier("conversation-image-" + image.id).accessibilityLabel(thumbnail == nil ? "加载对话图片" : "查看图片：" + image.name)
            HStack { Image(systemName: "photo"); Text(image.name).lineLimit(1); Spacer(); if thumbnail != nil { Text("点开大图") } }.font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .task(id: key + ":" + String(retry)) {
            let cacheKey = key as NSString
            if let cached = ConversationImageCache.images.object(forKey: cacheKey) { thumbnail = cached; return }
            do {
                let bytes = try await model.imageData(image, engine: engine)
                let decoded = await Task.detached(priority: .utility) { ConversationImageCache.thumbnail(bytes) }.value
                try Task.checkCancellation()
                guard let decoded else { throw PocketError.message("图片无法解码，请在电脑检查原图。") }
                ConversationImageCache.images.setObject(decoded, forKey: cacheKey, cost: (decoded.cgImage?.bytesPerRow ?? 0) * (decoded.cgImage?.height ?? 0))
                thumbnail = decoded; failure = nil
            } catch { if !Task.isCancelled { failure = "图片暂未加载成功" } }
        }
    }
}
