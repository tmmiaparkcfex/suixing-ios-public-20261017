import SwiftUI
import UIKit
import PencilKit
import Photos
import PhotosUI

@MainActor final class RecentPhotoLibrary: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    @Published var assets: [PHAsset] = []
    @Published var authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published var loading = Set<String>()
    private var observing = false
    func open() async {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--design-preview") && !ProcessInfo.processInfo.arguments.contains("--photo-library-fixture") { authorization = .denied; return }
        #endif
        if authorization == .notDetermined { authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
        guard authorization == .authorized || authorization == .limited else { return }
        if !observing { PHPhotoLibrary.shared().register(self); observing = true }
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--photo-library-fixture"), PHAsset.fetchAssets(with: .image, options: nil).count == 0 {
            let picture = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 1200)).image { context in
                UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 900, height: 1200))
                ("相册操作验收图片" as NSString).draw(at: CGPoint(x: 70, y: 180), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 58), .foregroundColor: UIColor.white])
            }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                PHPhotoLibrary.shared().performChanges({ PHAssetChangeRequest.creationRequestForAsset(from: picture) }) { _, _ in continuation.resume() }
            }
        }
        #endif
        reload()
    }
    private func reload() {
        let options = PHFetchOptions(); options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]; options.fetchLimit = 60
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var values: [PHAsset] = []; result.enumerateObjects { asset, _, _ in values.append(asset) }; assets = values
    }
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) { Task { @MainActor [weak self] in self?.reload() } }
    func bytes(_ asset: PHAsset) async -> Data? {
        let options = PHImageRequestOptions(); options.version = .current; options.deliveryMode = .highQualityFormat; options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { continuation in PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { bytes, _, _, _ in continuation.resume(returning: bytes) } }
    }
    deinit { if observing { PHPhotoLibrary.shared().unregisterChangeObserver(self) } }
}

private struct RecentPhotoThumbnail: View {
    let asset: PHAsset
    let selected: Bool
    let loading: Bool
    let select: () -> Void
    let preview: () -> Void
    @State private var picture: UIImage?
    @State private var request: PHImageRequestID?
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: preview) {
                Group { if let picture { Image(uiImage: picture).resizable().scaledToFill() } else { Color(.systemGray5).overlay { Image(systemName: "photo").foregroundStyle(.secondary) } } }
                    .frame(width: 84, height: 104).clipped().clipShape(RoundedRectangle(cornerRadius: 12))
            }.buttonStyle(.plain).accessibilityLabel("放大预览相册照片")
            Button(action: select) {
                ZStack {
                    Circle().fill(selected ? Color.blue : Color.black.opacity(0.32))
                    Circle().stroke(.white, lineWidth: 1.8)
                    if loading { ProgressView().tint(.white).scaleEffect(0.65) }
                    else if selected { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white) }
                }.frame(width: 23, height: 23).padding(7).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(selected ? "取消选择这张照片" : "选择这张照片")
        }.onAppear {
            guard picture == nil else { return }
            let options = PHImageRequestOptions(); options.deliveryMode = .opportunistic; options.resizeMode = .fast; options.isNetworkAccessAllowed = true
            request = PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 200, height: 250), contentMode: .aspectFill, options: options) { image, _ in if let image { Task { @MainActor in picture = image } } }
        }.onDisappear { if let request { PHImageManager.default().cancelImageRequest(request) } }
    }
}

struct AttachmentTray: View {
    @EnvironmentObject private var model: PocketModel
    @StateObject private var library = RecentPhotoLibrary()
    @Binding var selectedPhotos: [PhotosPickerItem]
    let camera: () -> Void
    let files: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            if library.authorization == .authorized || library.authorization == .limited {
                if library.assets.isEmpty { Text("最近照片会显示在这里").font(.caption).foregroundStyle(.secondary).frame(height: 104) }
                else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 8) {
                            ForEach(library.assets, id: \.localIdentifier) { asset in
                                RecentPhotoThumbnail(asset: asset, selected: model.pendingImages.contains { $0.assetIdentifier == asset.localIdentifier }, loading: library.loading.contains(asset.localIdentifier)) { toggle(asset) } preview: { preview(asset) }
                            }
                        }.padding(.horizontal, 14)
                    }.frame(height: 104)
                }
            } else {
                HStack(spacing: 10) { Image(systemName: "photo.on.rectangle"); Text("允许相册访问后，可在这里滑动勾选最近照片。相册按钮也可以单独选图。").font(.system(size: 12)).lineSpacing(3) }.foregroundStyle(.secondary).frame(height: 82).padding(.horizontal, 18)
            }
            HStack(spacing: 10) {
                trayButton("拍照", icon: "camera", action: camera)
                PhotosPicker(selection: $selectedPhotos, maxSelectionCount: max(1, 5 - model.pendingDocuments.count - model.pendingImages.count), matching: .images) { trayLabel("相册", icon: "photo.on.rectangle") }.buttonStyle(.plain).accessibilityLabel("从相册选择截图或照片")
                trayButton("文件", icon: "paperclip", action: files)
            }.padding(.horizontal, 14)
            if library.authorization == .limited { Button("管理允许访问的照片") { if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene, let controller = scene.windows.first(where: \.isKeyWindow)?.rootViewController { PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: controller) } }.font(.system(size: 11)).foregroundStyle(.secondary) }
        }.padding(.vertical, 14).background(Color(.secondarySystemBackground)).accessibilityIdentifier("attachment-tray").accessibilityValue(photoAccessSummary).task { await library.open() }
    }
    private var photoAccessSummary: String {
        #if DEBUG && targetEnvironment(simulator)
        return "authorization=\(library.authorization.rawValue);photos=\(library.assets.count)"
        #else
        return "最近照片，共 \(library.assets.count) 张"
        #endif
    }
    private func trayLabel(_ title: String, icon: String) -> some View {
        VStack(spacing: 9) { Image(systemName: icon).font(.system(size: 24)); Text(title).font(.system(size: 14, weight: .medium)) }.frame(maxWidth: .infinity).frame(height: 82).foregroundStyle(Color.primary).background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }
    private func trayButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View { Button(action: action) { trayLabel(title, icon: icon) }.buttonStyle(.plain) }
    private func preview(_ asset: PHAsset) {
        Task { if let bytes = await library.bytes(asset) { model.presentLibraryPhoto(bytes, assetIdentifier: asset.localIdentifier) } else { model.notice = "照片暂时无法读取，请稍后重试。" } }
    }
    private func toggle(_ asset: PHAsset) {
        let id = asset.localIdentifier
        if model.pendingImages.contains(where: { $0.assetIdentifier == id }) { model.pendingImages.removeAll { $0.assetIdentifier == id }; return }
        if library.loading.contains(id) { library.loading.remove(id); return }
        guard model.pendingImages.count + model.pendingDocuments.count < 5 else { model.notice = "每条消息最多添加5个附件。"; return }
        library.loading.insert(id)
        Task {
            let bytes = await library.bytes(asset)
            guard library.loading.remove(id) != nil else { return }
            if let bytes { model.addImage(bytes, assetIdentifier: id) } else { model.notice = "照片暂时无法读取，请从相册重新选择。" }
        }
    }
}

enum PhotoRendering {
    static func flatten(_ image: UIImage, drawing: PKDrawing, canvasSize: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: image.size, format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: image.size))
            image.draw(in: CGRect(origin: .zero, size: image.size))
            if canvasSize.width > 0 && !drawing.bounds.isEmpty {
                drawing.image(from: CGRect(origin: .zero, size: canvasSize), scale: image.size.width / canvasSize.width).draw(in: CGRect(origin: .zero, size: image.size))
            }
        }
    }
    static func rotate(_ image: UIImage) -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: image.size.height, height: image.size.width), format: format).image { context in
            context.cgContext.translateBy(x: image.size.height, y: 0); context.cgContext.rotate(by: .pi / 2)
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }
    static func crop(_ image: UIImage, selection: CGRect, canvasSize: CGSize) -> UIImage? {
        guard canvasSize.width > 0, let cg = image.cgImage else { return nil }
        let scale = CGFloat(cg.width) / canvasSize.width
        let rect = CGRect(x: selection.minX * scale, y: selection.minY * scale, width: selection.width * scale, height: selection.height * scale).integral.intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard rect.width >= 1, rect.height >= 1, let result = cg.cropping(to: rect) else { return nil }
        return UIImage(cgImage: result)
    }
}

struct ImageEditorView: UIViewControllerRepresentable {
    let imageData: Data
    let completion: (Data?) -> Void
    func makeUIViewController(context: Context) -> UINavigationController {
        let editor = PhotoEditorController(image: UIImage(data: imageData) ?? UIImage(), completion: completion)
        let navigation = UINavigationController(rootViewController: editor); navigation.modalPresentationStyle = .fullScreen
        return navigation
    }
    func updateUIViewController(_ controller: UINavigationController, context: Context) {}
}

final class PhotoEditorController: UIViewController, UIGestureRecognizerDelegate {
    private let original: UIImage
    private var image: UIImage
    private var previousImages: [UIImage] = []
    private let completion: (Data?) -> Void
    private let stage = UIView(), imageView = UIImageView(), canvas = PKCanvasView(), cropOverlay = CropSelectionView()
    private let modes = UISegmentedControl(items: ["预览", "裁剪", "标注"])
    private let help = UILabel(), tools = UIStackView(), apply = UIButton(type: .system)
    private var cropSelection: CGRect = .zero, dragOrigin = CGPoint.zero, originalSelection = CGRect.zero
    private var movingSelection = false, anchoredCorner: CGPoint?
    init(image: UIImage, completion: @escaping (Data?) -> Void) { self.image = image; original = image; self.completion = completion; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "编辑图片"; view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "取消", style: .plain, target: self, action: #selector(cancel))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "使用此图", style: .done, target: self, action: #selector(save))
        modes.selectedSegmentIndex = 0; modes.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        help.font = .systemFont(ofSize: 12); help.textColor = .secondaryLabel; help.textAlignment = .center; help.numberOfLines = 2
        stage.backgroundColor = UIColor.secondarySystemBackground; stage.layer.cornerRadius = 14; stage.clipsToBounds = true
        imageView.contentMode = .scaleAspectFit; imageView.image = image
        canvas.backgroundColor = .clear; canvas.isOpaque = false; canvas.isScrollEnabled = false; canvas.drawingPolicy = .anyInput
        canvas.tool = PKInkingTool(.pen, color: .systemRed, width: 4)
        stage.addSubview(imageView); stage.addSubview(canvas); stage.addSubview(cropOverlay)
        cropOverlay.backgroundColor = .clear; cropOverlay.isUserInteractionEnabled = false
        let cropGesture = UIPanGestureRecognizer(target: self, action: #selector(cropPan(_:))); cropGesture.delegate = self; stage.addGestureRecognizer(cropGesture)
        tools.axis = .horizontal; tools.distribution = .equalSpacing; tools.spacing = 8
        tools.addArrangedSubview(button("旋转", "rotate.right", #selector(rotate)))
        tools.addArrangedSubview(button("撤销", "arrow.uturn.backward", #selector(undo)))
        tools.addArrangedSubview(button("还原", "arrow.counterclockwise", #selector(reset)))
        for (name, color) in [("红", UIColor.systemRed), ("黄", .systemYellow), ("蓝", .systemBlue)] {
            let colorButton = UIButton(type: .system); colorButton.setTitle(name, for: .normal); colorButton.tintColor = color
            colorButton.addAction(UIAction { [weak self] _ in self?.modes.selectedSegmentIndex = 2; self?.canvas.tool = PKInkingTool(.pen, color: color, width: 4); self?.modeChanged() }, for: .touchUpInside)
            colorButton.accessibilityLabel = name + "色标注笔"; tools.addArrangedSubview(colorButton)
        }
        tools.addArrangedSubview(button("擦除", "eraser", #selector(eraser)))
        apply.setTitle("应用裁剪", for: .normal); apply.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold); apply.addTarget(self, action: #selector(applyCrop), for: .touchUpInside)
        [modes, help, stage, tools, apply].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; view.addSubview($0) }
        NSLayoutConstraint.activate([
            modes.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12), modes.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20), modes.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            help.topAnchor.constraint(equalTo: modes.bottomAnchor, constant: 10), help.leadingAnchor.constraint(equalTo: modes.leadingAnchor), help.trailingAnchor.constraint(equalTo: modes.trailingAnchor), help.heightAnchor.constraint(equalToConstant: 34),
            stage.topAnchor.constraint(equalTo: help.bottomAnchor, constant: 10), stage.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16), stage.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            tools.topAnchor.constraint(equalTo: stage.bottomAnchor, constant: 14), tools.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18), tools.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18), tools.heightAnchor.constraint(equalToConstant: 40),
            apply.topAnchor.constraint(equalTo: tools.bottomAnchor, constant: 5), apply.heightAnchor.constraint(equalToConstant: 38), apply.centerXAnchor.constraint(equalTo: view.centerXAnchor), apply.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8)
        ])
        modeChanged()
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let rect = ContentGeometry.imageRect(in: stage.bounds.size, image: image.size)
        if imageView.frame != rect { imageView.frame = rect; canvas.frame = rect; canvas.contentSize = rect.size; cropOverlay.frame = rect; cropSelection = CGRect(origin: .zero, size: rect.size).insetBy(dx: rect.width * 0.08, dy: rect.height * 0.08) }
        cropOverlay.selection = cropSelection
    }
    private func button(_ title: String, _ icon: String, _ action: Selector) -> UIButton {
        let button = UIButton(type: .system); button.setImage(UIImage(systemName: icon), for: .normal); button.setTitle(" " + title, for: .normal); button.titleLabel?.font = .systemFont(ofSize: 11); button.accessibilityLabel = title; button.addTarget(self, action: action, for: .touchUpInside); return button
    }
    @objc private func modeChanged() {
        canvas.isUserInteractionEnabled = modes.selectedSegmentIndex == 2
        if modes.selectedSegmentIndex == 2 { canvas.becomeFirstResponder() }
        cropOverlay.isHidden = modes.selectedSegmentIndex != 1; apply.isHidden = modes.selectedSegmentIndex != 1
        help.text = modes.selectedSegmentIndex == 1 ? "拖动框选保留区域；拖动四角调整，框内拖动位置" : modes.selectedSegmentIndex == 2 ? "用手指画线、圈出重点；可切换颜色、擦除和撤销" : "裁剪、旋转或标注后，点右上角使用此图"
    }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool { modes.selectedSegmentIndex == 1 }
    @objc private func cropPan(_ gesture: UIPanGestureRecognizer) {
        guard modes.selectedSegmentIndex == 1 else { return }
        let point = gesture.location(in: cropOverlay), bounds = cropOverlay.bounds
        if gesture.state == .began {
            originalSelection = cropSelection; dragOrigin = point; anchoredCorner = nil
            let corners = [CGPoint(x: cropSelection.minX, y: cropSelection.minY), CGPoint(x: cropSelection.maxX, y: cropSelection.minY), CGPoint(x: cropSelection.minX, y: cropSelection.maxY), CGPoint(x: cropSelection.maxX, y: cropSelection.maxY)]
            if let corner = corners.first(where: { hypot($0.x-point.x, $0.y-point.y) < 26 }) { anchoredCorner = CGPoint(x: corner.x == cropSelection.minX ? cropSelection.maxX : cropSelection.minX, y: corner.y == cropSelection.minY ? cropSelection.maxY : cropSelection.minY) }
            movingSelection = anchoredCorner == nil && cropSelection.contains(point)
        }
        if movingSelection {
            var moved = originalSelection.offsetBy(dx: point.x - dragOrigin.x, dy: point.y - dragOrigin.y)
            moved.origin.x = max(0, min(moved.origin.x, bounds.width - moved.width)); moved.origin.y = max(0, min(moved.origin.y, bounds.height - moved.height)); cropSelection = moved
        } else if let rect = ContentGeometry.cropRect(start: anchoredCorner ?? dragOrigin, end: point, imageBounds: bounds) { cropSelection = rect }
        cropOverlay.selection = cropSelection
    }
    private func flattened() -> UIImage { PhotoRendering.flatten(image, drawing: canvas.drawing, canvasSize: canvas.bounds.size) }
    private func replace(_ newImage: UIImage, saveUndo: Bool = true) {
        if saveUndo { previousImages.append(flattened()); if previousImages.count > 8 { previousImages.removeFirst() } }
        image = newImage; imageView.image = newImage; canvas.drawing = PKDrawing(); canvas.undoManager?.removeAllActions(); imageView.frame = .zero; view.setNeedsLayout()
    }
    @objc private func rotate() { replace(PhotoRendering.rotate(flattened())) }
    @objc private func eraser() { modes.selectedSegmentIndex = 2; canvas.tool = PKEraserTool(.bitmap); modeChanged() }
    @objc private func undo() {
        if canvas.undoManager?.canUndo == true { canvas.undoManager?.undo() }
        else if let previous = previousImages.popLast() { replace(previous, saveUndo: false) }
    }
    @objc private func reset() { previousImages = []; replace(original, saveUndo: false) }
    @objc private func applyCrop() {
        if let cropped = PhotoRendering.crop(flattened(), selection: cropSelection, canvasSize: canvas.bounds.size) { replace(cropped); modes.selectedSegmentIndex = 0; modeChanged() }
    }
    @objc private func cancel() { completion(nil) }
    @objc private func save() {
        var output = flattened()
        if modes.selectedSegmentIndex == 1, let cropped = PhotoRendering.crop(output, selection: cropSelection, canvasSize: canvas.bounds.size) { output = cropped }
        completion(output.jpegData(compressionQuality: 0.9))
    }
}

#if DEBUG && targetEnvironment(simulator)
enum PhotoEditorChecks {
    static func run() {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let base = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 80), format: format).image { context in UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 100, height: 80)) }
        let points = [CGPoint(x: 15, y: 40), CGPoint(x: 85, y: 40)].enumerated().map { index, point in PKStrokePoint(location: point, timeOffset: Double(index) * 0.1, size: CGSize(width: 6, height: 6), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2) }
        let path = PKStrokePath(controlPoints: points, creationDate: Date())
        let drawing = PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .systemBlue), path: path)])
        let marked = PhotoRendering.flatten(base, drawing: drawing, canvasSize: base.size)
        precondition(marked.pngData() != base.pngData(), "Annotations must be burned into outgoing image bytes")
        var rgba = [UInt8](repeating: 0, count: 100 * 80 * 4)
        let bitmap = CGContext(data: &rgba, width: 100, height: 80, bitsPerComponent: 8, bytesPerRow: 400, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        bitmap.draw(marked.cgImage!, in: CGRect(x: 0, y: 0, width: 100, height: 80))
        let offset = (40 * 100 + 50) * 4
        precondition(rgba[offset + 2] > 150 && rgba[offset] < 120, "Saved image must actually contain the blue stroke")
        let rotated = PhotoRendering.rotate(marked); precondition(rotated.size == CGSize(width: 80, height: 100))
        let cropped = PhotoRendering.crop(marked, selection: CGRect(x: 10, y: 10, width: 30, height: 20), canvasSize: base.size)
        precondition(cropped?.size == CGSize(width: 30, height: 20))
        let result = "{\"photoMarkupBakedIntoBytes\":true,\"rotationDimensions\":true,\"cropDimensions\":true}"
        let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("photo-checks.json")
        try! result.write(to: output, atomically: true, encoding: .utf8)
    }
}
#endif

private final class CropSelectionView: UIView {
    var selection: CGRect = .zero { didSet { setNeedsDisplay() } }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.addRect(bounds); context.addRect(selection); context.setFillColor(UIColor.black.withAlphaComponent(0.45).cgColor); context.drawPath(using: .eoFill)
        context.setStrokeColor(UIColor.white.cgColor); context.setLineWidth(2); context.stroke(selection)
        context.setLineWidth(0.5); context.setStrokeColor(UIColor.white.withAlphaComponent(0.65).cgColor)
        for step in 1...2 { let x = selection.minX + selection.width * CGFloat(step) / 3, y = selection.minY + selection.height * CGFloat(step) / 3; context.move(to: CGPoint(x: x, y: selection.minY)); context.addLine(to: CGPoint(x: x, y: selection.maxY)); context.move(to: CGPoint(x: selection.minX, y: y)); context.addLine(to: CGPoint(x: selection.maxX, y: y)) }; context.strokePath()
        context.setFillColor(UIColor.white.cgColor)
        for point in [CGPoint(x: selection.minX, y: selection.minY), CGPoint(x: selection.maxX, y: selection.minY), CGPoint(x: selection.minX, y: selection.maxY), CGPoint(x: selection.maxX, y: selection.maxY)] { context.fillEllipse(in: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)) }
    }
}
