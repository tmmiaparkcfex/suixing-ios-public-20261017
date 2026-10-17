import SwiftUI
import AVFoundation
import UIKit

/// Recording and metering publish only to the small composer, never the chat model.
@MainActor final class PhoneVoiceRecorder: ObservableObject {
    @Published private(set) var recording = false
    @Published private(set) var recognizing = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var level: Double = 0
    @Published private(set) var message: String?
    @Published private(set) var failed = false
    @Published var cancelArmed = false
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var clip: URL?
    private var request: Task<Void, Never>?
    private var generation = 0
    private var sendAfterRecognition = false
    var timeLimit: (() -> Void)?
    var canRetry: Bool { clip != nil && !recording && !recognizing && failed }

    func start() async {
        guard !recognizing, !recording else { return }
        cancel(); message = nil; failed = false; elapsed = 0
        let revision = generation
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--voice-fixture") {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
            try? Data("RIFF0000WAVEfmt simulator recording fixture".utf8).write(to: url)
            clip = url; recording = true; return
        }
        #endif
        let audio = AVAudioSession.sharedInstance()
        let permitted = await withCheckedContinuation { continuation in audio.requestRecordPermission { continuation.resume(returning: $0) } }
        guard generation == revision else { return }
        guard permitted else { failed = true; message = "请在 iPhone 设置中允许随行使用麦克风。"; return }
        do {
            try audio.setCategory(.record, mode: .measurement, options: [])
            try audio.setActive(true)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 24000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
            let value = try AVAudioRecorder(url: url, settings: settings)
            value.isMeteringEnabled = true
            guard value.prepareToRecord(), value.record(forDuration: 120) else { throw PocketError.message("无法开始录音，请重试。") }
            clip = url; recorder = value; recording = true
            let meter = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
            RunLoop.main.add(meter, forMode: .common)
            timer = meter
        } catch { try? audio.setActive(false, options: .notifyOthersOnDeactivation); failed = true; message = error.localizedDescription }
    }
    private func tick() {
        guard recording else { return }
        recorder?.updateMeters(); elapsed = min(120, recorder?.currentTime ?? elapsed)
        level = min(1, max(0, pow(10, Double(recorder?.averagePower(forChannel: 0) ?? -60) / 35)))
        if elapsed >= 119.5 || recorder?.isRecording == false { timeLimit?() }
    }
    func finish(using model: PocketModel, autoSend: Bool = false) {
        guard !recognizing, let clip else { return }
        if recording { sendAfterRecognition = autoSend }
        recording = false; timer?.invalidate(); timer = nil
        elapsed = max(elapsed, recorder?.currentTime ?? 0); recorder?.stop(); recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        recognizing = true; failed = false; message = sendAfterRecognition ? "正在识别，完成后发送到当前 AI…" : "正在用电脑识别语音…"
        let revision = generation, engine = model.engine, thread = model.conversation.threadId, duration = max(0.1, elapsed)
        request = Task { [weak self, weak model] in
            guard let self, let model else { return }
            defer { if self.generation == revision { self.recognizing = false; self.request = nil } }
            do {
                let bytes = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: clip) }.value
                let result = try await model.transcribeVoice(bytes, duration: duration)
                guard !Task.isCancelled, self.generation == revision else { return }
                guard model.engine == engine, model.conversation.threadId == thread else { self.failed = true; self.message = "会话已切换，请在当前会话重新识别。"; return }
                if !model.draft.isEmpty && !model.draft.hasSuffix("\n") { model.draft += "\n" }
                model.draft += result.text
                try? FileManager.default.removeItem(at: clip); self.clip = nil
                if self.sendAfterRecognition {
                    await model.send()
                    guard !Task.isCancelled, self.generation == revision else { return }
                    self.message = model.draft.isEmpty ? "语音已识别并发送到电脑。" : "已转成文字，尚未发送，请检查输入框后发送。"
                } else { self.message = "已转文字，请检查或修改后再发送。" }
                self.failed = false
            } catch {
                guard !Task.isCancelled, self.generation == revision else { return }
                self.failed = true; self.message = error.localizedDescription
            }
        }
    }
    func cancel() {
        generation += 1; request?.cancel(); request = nil
        timer?.invalidate(); timer = nil; recorder?.stop(); recorder = nil
        recording = false; recognizing = false; level = 0; message = nil; failed = false; cancelArmed = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if let clip { try? FileManager.default.removeItem(at: clip) }; clip = nil
    }
    #if DEBUG && targetEnvironment(simulator)
    func showPreview() { recording = true; elapsed = 12; level = 0.62; cancelArmed = ProcessInfo.processInfo.arguments.contains("--voice-cancel-preview") }
    #endif
}

struct VoiceComposerControl: View {
    @EnvironmentObject private var model: PocketModel
    @ObservedObject var voice: PhoneVoiceRecorder
    let dismissKeyboard: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                VoiceHoldButton(enabled: !voice.recognizing && !model.working, active: voice.recording, begin: {
                    dismissKeyboard()
                    voice.timeLimit = { [weak voice, weak model] in
                        guard let voice, let model else { return }
                        if voice.cancelArmed { voice.cancel() } else { voice.finish(using: model, autoSend: true) }
                    }
                    Task { await voice.start() }
                }, moved: { voice.cancelArmed = $0 }, end: { cancelled in
                    if voice.recognizing { return }
                    if cancelled || !voice.recording { voice.cancel() }
                    else { voice.finish(using: model, autoSend: true) }
                }, accessibilityToggle: {
                    if voice.recording { voice.finish(using: model, autoSend: true) }
                    else { Task { await voice.start() } }
                }).frame(width: 130, height: 30)
                if voice.recognizing { ProgressView().controlSize(.small); Text("识别并发送中").font(.caption).foregroundStyle(.secondary) }
                else if !voice.recording { Text("上滑取消").font(.system(size: 10)).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
                if voice.canRetry { Button("重试识别") { voice.finish(using: model) }.font(.caption) }
                if voice.recording || voice.recognizing || voice.canRetry { Button("取消") { voice.cancel() }.font(.caption).foregroundStyle(.secondary) }
            }
            if let message = voice.message { Text(message).font(.system(size: 11)).foregroundStyle(voice.failed ? Color.red : .secondary).fixedSize(horizontal: false, vertical: true) }
        }.onChange(of: model.engine) { _ in voice.cancel() }
            .onChange(of: model.conversation.threadId) { _ in voice.cancel() }
            .onDisappear { voice.cancel() }
            .onAppear {
                #if DEBUG && targetEnvironment(simulator)
                if ProcessInfo.processInfo.arguments.contains("--show-recording") { voice.showPreview() }
                #endif
            }
    }
}

struct VoiceHoldButton: UIViewRepresentable {
    let enabled: Bool, active: Bool
    let begin: () -> Void, moved: (Bool) -> Void, end: (Bool) -> Void, accessibilityToggle: () -> Void
    func makeUIView(context: Context) -> VoiceHoldControl { VoiceHoldControl() }
    func updateUIView(_ view: VoiceHoldControl, context: Context) {
        view.began = begin; view.moved = moved; view.ended = end; view.accessibilityToggle = accessibilityToggle
        view.isUserInteractionEnabled = enabled; view.alpha = enabled ? 1 : 0.45
        view.caption.text = active ? "录音中…" : "按住说话"; view.backgroundColor = active ? UIColor.systemBlue.withAlphaComponent(0.13) : UIColor.secondarySystemBackground
    }
}

final class VoiceHoldControl: UIControl {
    let caption = UILabel()
    private let icon = UIImageView(image: UIImage(systemName: "mic.fill"))
    var began: (() -> Void)?, moved: ((Bool) -> Void)?, ended: ((Bool) -> Void)?, accessibilityToggle: (() -> Void)?
    private var initialY: CGFloat = 0, beganAt: CFTimeInterval = 0, armed = false
    override init(frame: CGRect) {
        super.init(frame: frame); layer.cornerRadius = 14
        caption.font = .systemFont(ofSize: 12, weight: .medium); caption.textColor = .systemBlue; addSubview(caption)
        icon.tintColor = .systemBlue; icon.contentMode = .scaleAspectFit; addSubview(icon)
        isAccessibilityElement = true; accessibilityTraits = .button; accessibilityLabel = "按住语音输入"; accessibilityHint = "按住说话，松手识别并发送；向上滑动后松手取消。"
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() { super.layoutSubviews(); icon.frame = CGRect(x: 13, y: 7, width: 15, height: 16); caption.frame = CGRect(x: 36, y: 4, width: bounds.width - 42, height: 22) }
    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        initialY = touch.location(in: window).y; beganAt = CACurrentMediaTime(); armed = false; began?(); return true
    }
    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        let next = touch.location(in: window).y - initialY < -70
        if next != armed { armed = next; moved?(next) }
        return true
    }
    override func endTracking(_ touch: UITouch?, with event: UIEvent?) { ended?(armed || CACurrentMediaTime() - beganAt < 0.25) }
    override func cancelTracking(with event: UIEvent?) { ended?(true) }
    override func accessibilityActivate() -> Bool { accessibilityToggle?(); return true }
}

struct VoiceRecordingOverlay: View {
    @ObservedObject var voice: PhoneVoiceRecorder
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        if voice.recording {
            GeometryReader { geometry in
                ZStack(alignment: .bottom) {
                    Color.black.opacity(0.80)
                    RadialGradient(colors: [(voice.cancelArmed ? Color.red : Color(red: 0.10, green: 0.40, blue: 0.98)).opacity(0.97), (voice.cancelArmed ? Color.red : Color.blue).opacity(0.55), .clear], center: .bottom, startRadius: 10, endRadius: max(geometry.size.width, geometry.size.height * 0.63))
                    VStack(spacing: 32) {
                        Text(voice.cancelArmed ? "松手取消" : "松手发送，上滑取消").font(.system(size: 17, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                        NativeVoiceWaveform(level: voice.level, reduceMotion: reduceMotion).frame(height: 70).padding(.horizontal, 53)
                        Text(String(format: "%02d:%02d", Int(voice.elapsed) / 60, Int(voice.elapsed) % 60)).font(.system(size: 13, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
                    }.padding(.bottom, max(70, geometry.size.height * 0.09))
                }.ignoresSafeArea().animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: voice.cancelArmed)
            }.accessibilityIdentifier("voice-recording-overlay")
        }
    }
}

struct NativeVoiceWaveform: UIViewRepresentable {
    let level: Double, reduceMotion: Bool
    func makeUIView(context: Context) -> VoiceWaveformView { VoiceWaveformView() }
    func updateUIView(_ view: VoiceWaveformView, context: Context) { view.level = level; view.reduceMotion = reduceMotion; view.refresh() }
    static func dismantleUIView(_ view: VoiceWaveformView, coordinator: ()) { view.stop() }
}
@MainActor private final class VoiceWaveTarget: NSObject {
    weak var owner: VoiceWaveformView?
    @objc func step(_ link: CADisplayLink) { owner?.draw(at: link.timestamp) }
}
final class VoiceWaveformView: UIView {
    var level: Double = 0, reduceMotion = false
    private let bars = CAShapeLayer(), target = VoiceWaveTarget()
    private var link: CADisplayLink?, shown: Double = 0
    override init(frame: CGRect) { super.init(frame: frame); backgroundColor = .clear; bars.fillColor = UIColor.white.withAlphaComponent(0.85).cgColor; layer.addSublayer(bars); target.owner = self }
    required init?(coder: NSCoder) { fatalError() }
    override func didMoveToWindow() { super.didMoveToWindow(); refresh() }
    override func layoutSubviews() { super.layoutSubviews(); draw(at: CACurrentMediaTime()) }
    func refresh() {
        guard window != nil, !reduceMotion else { stop(); draw(at: 0); return }
        if link == nil { let value = CADisplayLink(target: target, selector: #selector(VoiceWaveTarget.step(_:))); value.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30); value.add(to: .main, forMode: .common); link = value }
    }
    func draw(at time: Double) {
        shown += (level - shown) * (reduceMotion ? 1 : 0.18)
        let path = UIBezierPath(), count = 45, width = bounds.width / CGFloat(count)
        for index in 0..<count {
            let distance = Double(index - count / 2) / 17
            let envelope = exp(-distance * distance)
            let phase = reduceMotion ? 0 : time * 7
            let modulation = 0.35 + 0.65 * abs(sin(Double(index) * 1.73 + phase))
            let boundedLevel: Double = max(0.0, min(1.0, shown))
            let availableHeight: Double = Double(max(CGFloat(0), bounds.height - CGFloat(4)))
            let amplitude: Double = boundedLevel * envelope * modulation * availableHeight
            let height: CGFloat = CGFloat(3.0 + amplitude)
            let barX: CGFloat = CGFloat(index) * width + width * CGFloat(0.27)
            let barWidth: CGFloat = max(CGFloat(2), width * CGFloat(0.40))
            let rectangle = CGRect(x: barX, y: (bounds.height - height) / 2, width: barWidth, height: height)
            path.append(UIBezierPath(roundedRect: rectangle, cornerRadius: 2))
        }
        CATransaction.begin(); CATransaction.setDisableActions(true); bars.path = path.cgPath; CATransaction.commit()
    }
    func stop() { link?.invalidate(); link = nil }
    deinit { link?.invalidate() }
}
