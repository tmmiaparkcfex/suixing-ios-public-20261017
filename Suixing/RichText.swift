import SwiftUI
import UIKit
import ImageIO
import AVKit
import AVFoundation
import CoreVideo

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
        let parsed = (try? AttributedString(markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(value)
        var result = AttributedString()
        for run in parsed.runs {
            var segment = AttributedString(parsed[run.range])
            if run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true { segment.foregroundColor = Color(red: 0.18, green: 0.36, blue: 0.77) }
            if run.inlinePresentationIntent?.contains(.code) == true {
                let literal = String(segment.characters)
                let ink = Color(red: 0.43, green: 0.18, blue: 0.02), paper = Color(red: 1, green: 0.94, blue: 0.79)
                if let label = TechnicalName.label(literal) {
                    var prefix = AttributedString("〔" + label + "〕")
                    prefix.font = .system(size: 12, weight: .bold); prefix.foregroundColor = ink; prefix.backgroundColor = paper
                    result += prefix
                }
                segment.font = .system(size: 16, weight: .semibold, design: .monospaced)
                segment.foregroundColor = ink; segment.backgroundColor = paper
            }
            result += segment
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
                case .terms(let terms): for term in terms { _ = InlineEmphasis.styled(term.explanation) }
                case .sequence(let steps): for step in steps { _ = InlineEmphasis.styled(step) }
                case .code, .divider, .image, .attachment: break
                }
            }
        }
    }
}

struct RichMessageText: View, Equatable {
    let text: String
    var images: [MessageImage] = []
    var engine: String = "codex"
    var documents: [MessageFile] = []
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.text == rhs.text && lhs.images == rhs.images && lhs.engine == rhs.engine && lhs.documents == rhs.documents }
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
        case .terms(let terms): NamedTermsView(terms: terms)
        case .sequence(let steps): SequenceStepsView(steps: steps)
        case .divider: Rectangle().fill(Color.primary.opacity(0.10)).frame(height: 1).padding(.vertical, 4)
        case .image(let caption, let id):
            if let image = images.first(where: { $0.id == id }) { ConversationImageView(image: image, engine: engine) }
            else { Label(caption.isEmpty ? "图片暂不可用，请重新同步" : caption + " · 请重新同步", systemImage: "photo").font(.callout).foregroundStyle(.secondary) }
        case .attachment(let caption, let id):
            if let file = documents.first(where: { $0.id == id }) { ConversationFileView(file: file, engine: engine) }
            else { Label(caption + " · 请重新同步", systemImage: "doc").font(.callout).foregroundStyle(.secondary) }
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

private struct NamedTermsView: View {
    let terms: [NamedTerm]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(terms.enumerated()), id: \.offset) { index, term in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(index + 1).").font(.system(size: 15, weight: .semibold)).foregroundStyle(.blue).frame(width: 24, alignment: .leading)
                    VStack(alignment: .leading, spacing: 6) {
                        if !term.explanation.isEmpty { Text(InlineEmphasis.styled(term.explanation)).font(.system(size: 17, weight: .medium)).lineSpacing(5) }
                        Text(term.name).font(.system(size: 16, weight: .semibold, design: .monospaced)).foregroundStyle(Color(red: 0.12, green: 0.29, blue: 0.66)).lineSpacing(4)
                    }.frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                }
            }
        }.accessibilityIdentifier("readable-name-list")
    }
}

private struct SequenceStepsView: View {
    let steps: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(index + 1)").font(.system(size: 12, weight: .bold)).foregroundStyle(.white).frame(width: 23, height: 23).background(Color.blue, in: Circle())
                    Text(InlineEmphasis.styled(step)).font(.system(size: 17)).lineSpacing(6).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                }
            }
        }.accessibilityIdentifier("readable-workflow")
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
        if let picture = thumbnail, picture.size.height > 0 { return picture.size.width / picture.size.height }
        if let w = image.width, let h = image.height, w > 0, h > 0 { return w / h }
        return 0.6
    }
    private var thumbnailWidth: CGFloat { max(76, min(260, 230 * ratio)) }
    private var thumbnailHeight: CGFloat { min(230, thumbnailWidth / max(0.03, ratio)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                if thumbnail != nil { Task { await model.previewImage(image, engine: engine) } }
                else if failure != nil { failure = nil; retry += 1 }
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(thumbnail == nil ? Color(.secondarySystemBackground) : .clear)
                    if let thumbnail { Image(uiImage: thumbnail).resizable().scaledToFit().padding(1) }
                    else if let failure { VStack(spacing: 9) { Image(systemName: "photo.badge.exclamationmark").font(.title2); Text(failure).font(.caption).multilineTextAlignment(.center); Text("点此重试").font(.caption.bold()) }.foregroundStyle(.secondary).padding(16) }
                    else { ProgressView("正在读取图片…").font(.caption) }
                }.frame(width: thumbnailWidth, height: thumbnailHeight).clipShape(RoundedRectangle(cornerRadius: 12))
            }.buttonStyle(.plain).accessibilityIdentifier("conversation-image-" + image.id).accessibilityLabel(thumbnail == nil ? "加载对话图片" : "查看图片：" + image.name)
        }
        .task(id: key + ":" + String(retry)) {
            thumbnail = nil; failure = nil
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

struct ConversationFileView: View {
    @EnvironmentObject private var model: PocketModel
    let file: MessageFile
    let engine: String
    var body: some View {
        Button { Task { await model.openConversationFile(file, engine: engine) } } label: {
            HStack(spacing: 12) {
                Image(systemName: file.icon).font(.system(size: 25)).foregroundStyle(.blue).frame(width: 32)
                VStack(alignment: .leading, spacing: 5) { Text(file.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.primary).lineLimit(2); Text(file.actionLabel + (file.size.map { " · " + ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "")).font(.system(size: 11)).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
                if model.fileLoading { ProgressView().controlSize(.small) } else { Image(systemName: file.kind == "video" || file.kind == "audio" ? "play.fill" : "arrow.up.right").font(.system(size: 12)).foregroundStyle(.secondary) }
            }.padding(13).frame(maxWidth: .infinity, alignment: .leading).background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).disabled(model.fileLoading).accessibilityLabel(file.actionLabel + "：" + file.name).accessibilityIdentifier("conversation-file-" + file.id)
    }
}

struct MediaPlaybackSheet: View {
    @EnvironmentObject private var model: PocketModel
    @Environment(\.dismiss) private var dismiss
    let item: MediaPlayback
    @State private var player: AVPlayer?
    @State private var failure: String?
    @State private var downloading = false
    @State private var sharedFile: PreviewFile?
    @State private var ready = false
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                VideoPlayer(player: player).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black).accessibilityIdentifier("conversation-media-player").accessibilityValue(ready ? "ready" : "loading")
                if let failure { Text(failure).font(.caption).foregroundStyle(.secondary).padding(.horizontal) }
                Button {
                    downloading = true
                    Task { do { sharedFile = PreviewFile(url: try await model.downloadConversationFile(item.file, engine: item.engine)) } catch { failure = error.localizedDescription }; downloading = false }
                } label: { HStack { if downloading { ProgressView() }; Label(downloading ? "正在下载…" : "下载并在其他 App 打开", systemImage: "square.and.arrow.up") }.font(.callout).padding(.bottom, 16) }.disabled(downloading)
            }.navigationTitle(item.file.name).navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.sheet(item: $sharedFile) { file in ShareSheet(url: file.url) }
            .onAppear { try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback); try? AVAudioSession.sharedInstance().setActive(true); player = AVPlayer(url: item.url); player?.play() }
            .onDisappear { player?.pause(); player = nil; try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
            .task { while !Task.isCancelled { try? await Task.sleep(nanoseconds: 500_000_000); if player?.currentItem?.status == .readyToPlay { ready = true }; if player?.currentItem?.status == .failed { failure = player?.currentItem?.error?.localizedDescription ?? "当前格式无法直接播放，请下载后选择其他 App 打开。"; break } } }
    }
}

#if DEBUG && targetEnvironment(simulator)
@MainActor enum PreviewMediaFactory {
    static func file(_ file: MessageFile) async throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("合成附件验收", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(file.name)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        if file.kind != "video" {
            let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842))
            try renderer.writePDF(to: url) { context in context.beginPage(); ("随行 · 合成文档验收\n\n这一页来自本机生成的 PDF，用于检查原生预览和分享。" as NSString).draw(in: CGRect(x: 45, y: 70, width: 500, height: 600), withAttributes: [.font: UIFont.systemFont(ofSize: 24), .foregroundColor: UIColor.black]) }
            return url
        }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 240])
        writer.add(input); guard writer.startWriting() else { throw PocketError.message("合成验收视频无法创建。") }; writer.startSession(atSourceTime: .zero)
        for frame in 0..<4 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 10_000_000); if writer.status == .failed { throw writer.error ?? PocketError.message("视频编码失败。") } }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, 320, 240, kCVPixelFormatType_32ARGB, nil, &buffer) == kCVReturnSuccess, let buffer else { throw PocketError.message("视频帧创建失败。") }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let address = CVPixelBufferGetBaseAddress(buffer) { address.initializeMemory(as: UInt8.self, repeating: UInt8(80 + frame * 35), count: CVPixelBufferGetBytesPerRow(buffer) * 240) }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 2)) else { throw writer.error ?? PocketError.message("视频帧写入失败。") }
        }
        input.markAsFinished(); writer.endSession(atSourceTime: CMTime(value: 2, timescale: 1))
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in writer.finishWriting { continuation.resume() } }
        guard writer.status == .completed else { throw writer.error ?? PocketError.message("视频文件未完成。") }; return url
    }
}
#endif

struct FullscreenPhotoView: View {
    @EnvironmentObject private var model: PocketModel
    @Environment(\.dismiss) private var dismiss
    let photo: PhotoPreview
    @State private var editing = false
    @State private var finishAfterEditing = false
    private var selected: Bool { model.pendingImages.contains { $0.assetIdentifier == photo.assetIdentifier } }
    private var atLimit: Bool { !selected && model.pendingImages.count + model.pendingDocuments.count >= 5 }
    var body: some View {
        ZStack(alignment: .bottom) {
            ZoomablePhoto(url: photo.url, close: { dismiss() }).ignoresSafeArea()
            if let asset = photo.assetIdentifier, let data = photo.data {
                HStack(spacing: 20) {
                    Button { editing = true } label: { Label("编辑图片", systemImage: "slider.horizontal.3").padding(.vertical, 12).frame(maxWidth: .infinity) }
                    Button {
                        model.useLibraryPhoto(data, assetIdentifier: asset, edited: false)
                        dismiss()
                    } label: { Text(atLimit ? "已达附件上限" : selected ? "已选中，返回" : "使用此图").fontWeight(.semibold).padding(.vertical, 12).frame(maxWidth: .infinity).background(Color.blue, in: Capsule()) }.disabled(atLimit)
                }.font(.system(size: 16)).foregroundStyle(.white).padding(.horizontal, 24).padding(.bottom, 20).padding(.top, 10).background(Color.black.opacity(0.85))
            }
        }.background(Color.black).statusBarHidden(true)
            .sheet(isPresented: $editing, onDismiss: { if finishAfterEditing { dismiss() } }) {
                ImageEditorView(imageData: photo.data ?? Data()) { output in
                    if let output, let asset = photo.assetIdentifier { model.useLibraryPhoto(output, assetIdentifier: asset, edited: true); finishAfterEditing = true }
                    editing = false
                }.interactiveDismissDisabled()
            }
    }
}

private struct ZoomablePhoto: UIViewControllerRepresentable {
    let url: URL
    let close: () -> Void
    func makeUIViewController(context: Context) -> PhotoViewerController { PhotoViewerController(url: url, close: close) }
    func updateUIViewController(_ controller: PhotoViewerController, context: Context) {}
}

private final class PhotoViewerController: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private let url: URL
    private let closeAction: () -> Void
    private let scroll = UIScrollView(), picture = UIImageView(), closeButton = UIButton(type: .system)
    private var fittedSize = CGSize.zero
    init(url: URL, close: @escaping () -> Void) { self.url = url; closeAction = close; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    override var prefersStatusBarHidden: Bool { true }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black
        scroll.delegate = self; scroll.backgroundColor = .black; scroll.showsVerticalScrollIndicator = false; scroll.showsHorizontalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never; scroll.bounces = false; scroll.bouncesZoom = true
        scroll.accessibilityIdentifier = "photo-zoom-surface"; scroll.accessibilityValue = "fit"
        picture.contentMode = .scaleAspectFit; picture.isAccessibilityElement = true; picture.accessibilityLabel = "图片，可双指缩放和拖动查看"
        scroll.addSubview(picture); view.addSubview(scroll)
        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal); closeButton.tintColor = .white; closeButton.backgroundColor = UIColor.black.withAlphaComponent(0.45); closeButton.layer.cornerRadius = 19
        closeButton.accessibilityLabel = "关闭图片"; closeButton.addAction(UIAction { [weak self] _ in self?.closeAction() }, for: .touchUpInside); view.addSubview(closeButton)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(zoom(_:))); doubleTap.numberOfTapsRequired = 2; scroll.addGestureRecognizer(doubleTap)
        let tap = UITapGestureRecognizer(target: self, action: #selector(toggleControls)); tap.require(toFail: doubleTap); scroll.addGestureRecognizer(tap)
        let swipe = UISwipeGestureRecognizer(target: self, action: #selector(closeFromSwipe)); swipe.direction = .down; swipe.delegate = self; scroll.addGestureRecognizer(swipe)
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(share(_:))); scroll.addGestureRecognizer(hold)
        let fileURL = url
        Task { [weak self] in
            let image = await Task.detached(priority: .userInitiated) { UIImage(contentsOfFile: fileURL.path) }.value
            guard let self else { return }
            self.picture.image = image; self.fittedSize = .zero; self.view.setNeedsLayout()
            if image == nil { let label = UILabel(); label.text = "图片无法读取，请关闭后重试"; label.textColor = .white; label.textAlignment = .center; label.frame = self.view.bounds; label.autoresizingMask = [.flexibleWidth, .flexibleHeight]; self.view.insertSubview(label, belowSubview: self.closeButton) }
        }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews(); scroll.frame = view.bounds
        closeButton.frame = CGRect(x: 16, y: view.safeAreaInsets.top + 12, width: 38, height: 38)
        guard let image = picture.image, image.size.width > 0, image.size.height > 0, fittedSize != scroll.bounds.size else { return }
        fittedSize = scroll.bounds.size; picture.frame = CGRect(origin: .zero, size: image.size); scroll.contentSize = image.size
        let fit = min(scroll.bounds.width / image.size.width, scroll.bounds.height / image.size.height)
        scroll.minimumZoomScale = fit; scroll.maximumZoomScale = max(1, fit * 6); scroll.setZoomScale(fit, animated: false); centerPhoto()
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { picture }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerPhoto(); scroll.accessibilityValue = scroll.zoomScale > scroll.minimumZoomScale * 1.02 ? "zoomed" : "fit" }
    private func centerPhoto() { scroll.contentInset = UIEdgeInsets(top: max(0, (scroll.bounds.height - scroll.contentSize.height) / 2), left: max(0, (scroll.bounds.width - scroll.contentSize.width) / 2), bottom: 0, right: 0) }
    @objc private func toggleControls() { closeButton.isHidden.toggle() }
    @objc private func closeFromSwipe() { closeAction() }
    @objc private func zoom(_ gesture: UITapGestureRecognizer) {
        if scroll.zoomScale > scroll.minimumZoomScale * 1.02 { scroll.setZoomScale(scroll.minimumZoomScale, animated: true); return }
        let level = min(scroll.maximumZoomScale, scroll.minimumZoomScale * 2.8), point = gesture.location(in: picture)
        let size = CGSize(width: scroll.bounds.width / level, height: scroll.bounds.height / level)
        scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
    }
    @objc private func share(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil); sheet.popoverPresentationController?.sourceView = picture; present(sheet, animated: true)
    }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool { !(gestureRecognizer is UISwipeGestureRecognizer) || scroll.zoomScale <= scroll.minimumZoomScale * 1.02 }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { gestureRecognizer is UISwipeGestureRecognizer || otherGestureRecognizer is UISwipeGestureRecognizer }
}
