import Foundation
import Combine
import Security
import WebKit
import UIKit
import ImageIO

private enum Vault {
    static let service = "local.suixing.pocket.session"
    static func read() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "session",
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ token: String) throws {
        clear()
        let entry: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "session",
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        guard SecItemAdd(entry as CFDictionary, nil) == errSecSuccess else {
            throw PocketError.message("无法安全保存连接凭证，请重试。")
        }
    }
    static func clear() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "session"] as CFDictionary)
    }
}

@MainActor final class ComposerDraft: ObservableObject {
    @Published var text = ""
}

@MainActor final class PocketModel: ObservableObject {
    @Published var server: String = {
        let previous = UserDefaults.standard.string(forKey: "pocket.server")
        return previous == nil || previous == "http://172.16.3.70:8787" ? "http://172.16.3.70:8789" : previous!
    }()
    @Published var password = ""
    @Published var loggedIn = false
    @Published var connected = false
    @Published var working = false
    @Published var notice: String?
    @Published var conversation = Conversation()
    @Published var files: [TaskFile] = [] {
        didSet {
            if oldValue != files {
                fileReferenceCandidates = files.sorted { $0.name < $1.name }.map { ($0, $0.name.lowercased(), $0.filename.lowercased()) }
            }
        }
    }
    private var fileReferenceCandidates: [(file: TaskFile, path: String, name: String)] = []
    @Published var history: [HistoryItem] = []
    let composerDraft = ComposerDraft()
    let voiceRecorder = PhoneVoiceRecorder()
    @Published var voiceDraftSerial = 0
    var draft: String { get { composerDraft.text } set { composerDraft.text = newValue } }
    var lastDraftEditAt = Date.distantPast
    @Published var preview: PreviewFile?
    @Published var playback: MediaPlayback?
    @Published var fileLoading = false
    @Published var controlsLoading = false
    @Published var pendingImages: [PendingImage] = []
    @Published var pendingDocuments: [PendingDocument] = []
    @Published var uploadStatus: String?
    @Published var usageHistory = UsageHistory()
    @Published var accountBudget: AccountBudget?
    private var budgetsByEngine: [String: AccountBudget] = [:]
    private var budgetRefreshAt: [String: Date] = [:]
    private var budgetRevision = 0
    @Published var draggingTokenPanel = false
    // UIKit owns this flag. Publishing it would itself invalidate every chat view.
    var interactingWithTranscript = false
    @Published var openingSession = false
    @Published var loadingConversation = false
    @Published var answeringQuestionId: String?
    @Published var recentSessions: [HistoryItem] = []
    private var recentByEngine: [String: [HistoryItem]] = [:]
    private var selectionRevision = 0
    private var selectionChanging = false
    private struct CachedConversation {
        let conversation: Conversation
        let files: [TaskFile]
        let usage: UsageHistory
    }
    private var conversationCache: [String: CachedConversation] = [:]
    private var cacheOrder: [String] = []
    private var lastThreadByEngine: [String: String] = [:]
    @Published var notificationLinkSerial = 0
    private var pendingNotificationLink: NotificationDestination?
    var usagePanelVisible = false
    private var lastUsageRefresh = Date.distantPast
    private var lastStateRefresh = Date.distantPast
    @Published var engine = UserDefaults.standard.string(forKey: "pocket.engine") ?? "codex" {
        didSet { UserDefaults.standard.set(engine, forKey: "pocket.engine") }
    }
    private var lastFileRefresh = Date.distantPast
    var designPreview = false
    private var sessionToken: String?
    private var eventTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var refreshingSelections = Set<Int>()
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--network-fixture") { configuration.protocolClasses = [PocketFixtureProtocol.self] }
        #endif
        return URLSession(configuration: configuration)
    }()

    init() {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--design-preview") {
            designPreview = true; loggedIn = true; connected = true
            UserDefaults.standard.set(true, forKey: "pocket.tokenOverlay")
            if ProcessInfo.processInfo.arguments.contains("--reset-overlay-position") {
                UserDefaults.standard.set(0.73, forKey: "pocket.tokenOverlayX"); UserDefaults.standard.set(0.025, forKey: "pocket.tokenOverlayY")
            }
            engine = ProcessInfo.processInfo.arguments.contains("workbuddy") ? "workbuddy" : ProcessInfo.processInfo.arguments.contains("dsh") ? "dsh" : "codex"
            let now = Date().timeIntervalSince1970 * 1000
            conversation.threadId = "design-preview"
            conversation.title = "随行界面优化"
            conversation.capabilities = EngineCapabilities(newSession: true, deleteSession: engine != "codex", deleteMode: engine == "workbuddy" ? "delete" : "archive", deleteDisabledReason: "Codex 归档请在电脑操作")
            history = [HistoryItem(id: "design-preview", title: "随行界面优化", time: now, cwd: "D:/codex/随行", busy: true), HistoryItem(id: "preview-2", title: "给我装个 VM 虚拟机", time: now - 3600000, cwd: "D:/codex/虚拟机"), HistoryItem(id: "preview-3", title: "整理游戏截图与文件", time: now - 7200000, cwd: "D:/codex/截图任务"), HistoryItem(id: "preview-4", title: "查找图片里的工具", time: now - 86400000, cwd: "D:/codex/截图任务")]
            recentSessions = Array(history.prefix(3)); recentByEngine[engine] = recentSessions
            conversation.messages = [
                Message(role: "assistant", text: "已整理好工作台和使用说明。文件可以直接在对话里打开，后续修改也会同步到电脑。\n\n生成了 README.md 和 使用说明.md。", time: now - 180000),
                Message(role: "user", text: "继续把手机端的对话和执行轨迹做好，退出后电脑也继续运行。", time: now - 130000)
            ]
            files = [TaskFile(name: "README.md", size: 2450, modified: now - 180000), TaskFile(name: "使用说明.md", size: 1860, modified: now - 180000)]
            conversation.busy = true
            conversation.activity = "整理界面布局，保留电脑端正在执行的任务。"
            conversation.events = [
                TaskEvent(method: "turn/started", time: now - 130000, summary: "", detail: nil),
                TaskEvent(method: "item/completed", time: now - 110000, summary: "reasoning", detail: "{\"id\":\"preview-thought\",\"type\":\"reasoning\"}"),
                TaskEvent(method: "item/started", time: now - 90000, summary: "检查工作目录和生成的文件", detail: "{\"id\":\"preview-command\",\"type\":\"commandExecution\",\"command\":\"检查工作目录和生成的文件\"}")
            ]
            conversation.usage = TokenUsage(totalTokens: 521000, inputTokens: 480000, outputTokens: 41000, cachedInputTokens: 240000, reasoningTokens: 12000, lastTurnTokens: 261000, contextTokens: 136000, contextWindow: 524288, contextPercent: 26, tokensPerSecond: 141, cacheHitPercent: 50, steps: 3, turns: 3, updatedAt: now, source: "界面演示数据")
            var cumulative = 400000.0
            usageHistory.samples = (0..<181).map { index in
                let rate = max(0, 180 + sin(Double(index) / 8) * 150 + cos(Double(index) / 3) * 60)
                cumulative += rate * 2
                return UsageSample(time: now - Double(180 - index) * 2000, totalTokens: cumulative, rateTokensPerSecond: rate, generationTokensPerSecond: 141, contextPercent: 26, contextRemainingTokens: 388288, cacheHitPercent: 50, segment: 0)
            }
            usageHistory.updatedAt = now; usageHistory.source = "仅用于 DEBUG 模拟器审阅的演示曲线"
            conversation.usage?.totalTokens = cumulative
            accountBudget = AccountBudget(kind: engine == "workbuddy" ? "credits" : engine == "dsh" ? "money" : "window", label: engine == "workbuddy" ? "剩余积分" : engine == "dsh" ? "账户余额" : "五小时额度剩余", status: "available", remaining: engine == "workbuddy" ? 1234.5 : engine == "dsh" ? 28.36 : nil, total: nil, used: nil, remainingPercent: engine == "codex" ? 74 : nil, windowMinutes: engine == "codex" ? 300 : nil, resetsAt: engine == "codex" ? now + 7200000 : nil, updatedAt: now, source: "仅 DEBUG 模拟器演示", message: "界面演示数据", currency: engine == "dsh" ? "CNY" : nil, stale: false)
            conversation.messages[0].usage = TokenUsage(totalTokens: 261000, inputTokens: 240000, outputTokens: 21000)
            let previewModel = engine + "-preview"
            let previewLabel = engine == "workbuddy" ? "WorkBuddy 当前模型" : engine == "dsh" ? "DeepSeek-V4.1-Flash" : "GPT-6.1-Sol"
            conversation.controls = EngineControls(modelId: previewModel, modelLabel: previewLabel, reasoningEffort: "high", permissionId: "preview-standard", permissionLabel: "工作区", models: [EngineModelOption(id: previewModel, label: previewLabel, reasoningEfforts: ["low", "medium", "high"]), EngineModelOption(id: "preview-other", label: "其他可用模型", reasoningEfforts: ["low", "high"])], permissions: [EnginePermissionOption(id: "preview-standard", label: "工作区", description: "仅用于模拟器界面审阅")], canChangeModel: true, canChangePermissions: true, canChangeReasoning: true)
            if ProcessInfo.processInfo.arguments.contains("--show-questions") {
                conversation.questions = [QuestionRequest(id: "preview-question", title: "需要你的选择", questions: [QuestionItem(id: "preview-scope", header: "修改范围", question: "图片已经收到，接下来先处理哪一项？", options: [QuestionOption(label: "调整界面布局", description: "按照截图修改手机界面。"), QuestionOption(label: "分析图片内容", description: "先说明图片里的问题。")], multiSelect: false, allowFreeText: true)], supported: true)]
            }
            if ProcessInfo.processInfo.arguments.contains("--show-multiple-questions") {
                conversation.questions = [QuestionRequest(id: "preview-multi", title: "选择修改项", questions: [QuestionItem(id: "preview-multi-item", question: "哪些修改需要一起完成？", options: [QuestionOption(label: "优化界面"), QuestionOption(label: "修复同步")], multiSelect: true, allowFreeText: true)], supported: true)]
            }
            if ProcessInfo.processInfo.arguments.contains("--show-formatting") {
                conversation.messages = [Message(role: "assistant", text: "## 准备已就绪\n\n**结论：现在可以开始操作。**\n\n| 功能 | 当前状态 |\n|---|---|\n| 图片 | 支持**裁剪、旋转和标注** |\n| 用量 | 点击底栏查看**实时曲线** |\n| 任务 | 手机退出后，电脑继续执行 |\n\n### 下一步\n\n1. 打开要继续的电脑会话。\n2. 发送截图，圈出需要修改的地方。\n\n> 注意：关机或休眠会中断任务。\n\n```text\n工作目录：D:\\codex\n```", time: now - 60000)]
                conversation.busy = false; conversation.events = []
            }
            if ProcessInfo.processInfo.arguments.contains("--show-images") {
                let computer = MessageImage(id: "preview-desktop", name: "电脑回复中的示意图", width: 800, height: 500, inline: true)
                let phone = MessageImage(id: "preview-phone", name: "手机发送的截图", width: 800, height: 500, inline: false)
                conversation.messages = [
                    Message(role: "assistant", text: "## 图片与文字一起显示\n\n这是电脑回复中的图片，点击可以查看大图。\n\n![示意图](suixing-image:preview-desktop)\n\n**重点：图片后面的说明属于同一条回复。**", time: now - 60000, itemId: "preview-picture-answer", phase: "final_answer", images: [computer]),
                    Message(role: "user", text: "这是我从手机发来的截图。", time: now, itemId: "preview-picture-user", images: [phone])
                ]
                conversation.busy = false; conversation.events = []
            }
            if ProcessInfo.processInfo.arguments.contains("--show-reading") {
                conversation.messages = [
                    Message(role: "user", text: "检查一下连接，告诉我能不能用，以及接下来怎么做。", time: now - 120000, itemId: "reading-user"),
                    Message(role: "assistant", text: "正在检查电脑后台与手机的连接。", time: now - 110000, itemId: "reading-progress-1", phase: "commentary"),
                    Message(role: "assistant", text: "连接正常，正在核对三款 AI 的会话和余额。", time: now - 100000, itemId: "reading-progress-2", phase: "commentary"),
                    Message(role: "assistant", text: "## 检查结果\n\n**连接正常，可以继续使用。**\n\nCodex、DSH 和 WorkBuddy 都已连接。手机退出后，电脑仍会继续执行任务。\n\n### 接下来这样做\n\n1. 在顶部选择要使用的 AI。\n2. 从会话列表打开需要继续的对话。\n3. 发送要求，完成后查看回复和附件。\n\n注意：电脑需要保持开机、联网。\n\n| 项目 | 说明 |\n|---|---|\n| 图片与文件 | 直接在对应的回复中打开 |\n| 执行过程 | 点击上方的执行过程，展开查看 |", time: now - 60000, itemId: "reading-answer", phase: "final_answer"),
                    Message(role: "user", text: "如果重启电脑呢？", time: now - 30000, itemId: "reading-user-2"),
                    Message(role: "assistant", text: "## 重启后这样连接\n\n1. 打开蒲公英，连接原来的组网。\n2. 打开要使用的电脑 AI 和随行后台。\n3. 在手机随行中打开原对话，继续发送消息。\n\n**原来的对话和设置会保留。**", time: now - 20000, itemId: "reading-answer-2", phase: "final_answer")
                ]
                conversation.busy = false; conversation.events = []
            }
            if ProcessInfo.processInfo.arguments.contains("--show-media") {
                let video = MessageFile(id: "preview-video", name: "演示视频.mp4", kind: "video", mimeType: "video/mp4")
                let pdf = MessageFile(id: "preview-pdf", name: "使用说明.pdf", kind: "file", mimeType: "application/pdf")
                conversation.messages = [Message(role: "assistant", text: "## 任务附件\n\n[播放演示视频](suixing-file:preview-video)\n\n[查看使用说明](suixing-file:preview-pdf)", time: now - 60000, itemId: "preview-media", phase: "final_answer", documents: [video, pdf])]
                conversation.busy = false; conversation.events = []
            }
            if ProcessInfo.processInfo.arguments.contains("--show-editor") {
                // Photo editor previews are separate from transcript image previews.
                let picture = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 1200)).image { context in
                    UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 900, height: 1200))
                    UIColor.systemBlue.withAlphaComponent(0.09).setFill(); context.fill(CGRect(x: 50, y: 60, width: 800, height: 200))
                    ("截图编辑示例" as NSString).draw(at: CGPoint(x: 85, y: 100), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 58), .foregroundColor: UIColor.label])
                    ("裁剪保留区域\n用彩笔圈出重点\n确认后发送给电脑 AI" as NSString).draw(in: CGRect(x: 85, y: 340, width: 700, height: 600), withAttributes: [.font: UIFont.systemFont(ofSize: 42), .foregroundColor: UIColor.darkGray])
                }
                if let data = picture.jpegData(compressionQuality: 0.9) { pendingImages = [PendingImage(name: "编辑示例.jpg", data: data)] }
            }
            if ProcessInfo.processInfo.arguments.contains("--stress-transcript") {
                conversation.messages = (0..<240).map { index in Message(role: index % 3 == 0 ? "user" : "assistant", text: index == 239 ? "最新回复标记 · 任务已完成" : "## 第 \(index + 1) 条任务记录\n\n这是一段用于检验长对话滚动稳定性的内容。\n\n" + String(repeating: "段落分开显示，快速滚动和跳到底部仍能看到消息。\n\n", count: index % 7 + 1), time: now - Double(240 - index) * 1000, itemId: "stress-\(index)") }
                conversation.busy = false; conversation.events = []
                UserDefaults.standard.set(false, forKey: "pocket.tokenOverlay")
                if ProcessInfo.processInfo.arguments.contains("--streaming-transcript") {
                    Task { [weak self] in
                        for index in 1...30 {
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            guard let self, let last = self.conversation.messages.last else { return }
                            self.conversation.messages[self.conversation.messages.count - 1] = Message(role: last.role, text: "最新回复标记 · 正在更新 \(index)", time: last.time, itemId: last.itemId)
                            self.conversation.busy = true
                            self.conversation.events.append(TaskEvent(method: "item/commandExecution", time: Date().timeIntervalSince1970 * 1000, summary: "模拟进度更新 \(index)", detail: nil))
                        }
                    }
                }
            }
            if ProcessInfo.processInfo.arguments.contains("--run-checks") { PhotoEditorChecks.run() }
        }
        if ProcessInfo.processInfo.arguments.contains("--network-fixture") {
            server = "http://127.0.0.1:18999"; engine = "codex"; loggedIn = true
            conversation.csrf = "fixture-csrf"; sessionToken = "fixture-session"; loadingConversation = true
            UserDefaults.standard.set(false, forKey: "pocket.tokenOverlay")
            Task { [weak self] in self?.beginUpdates() }
        }
        #endif
    }

    var currentSteps: [TaskEvent] {
        let since = conversation.messages.last(where: { $0.role == "user" })?.time ?? 0
        var steps: [TaskEvent] = []
        for event in conversation.events where event.time >= since && event.kind != "agentMessage" && !event.kind.isEmpty {
            if let id = event.itemID, let index = steps.firstIndex(where: { $0.itemID == id }) { steps[index] = event }
            else { steps.append(event) }
        }
        return steps
    }
    var taskStartedAt: Date {
        taskDate(conversation.events.last(where: { $0.method == "turn/started" })?.time ?? conversation.messages.last(where: { $0.role == "user" })?.time ?? Date().timeIntervalSince1970 * 1000)
    }
    func files(for message: Message) -> [TaskFile] {
        guard message.role == "assistant" else { return [] }
        if fileReferenceCandidates.isEmpty, !files.isEmpty {
            fileReferenceCandidates = files.sorted { $0.name < $1.name }.map { ($0, $0.name.lowercased(), $0.filename.lowercased()) }
        }
        let text = message.text.lowercased() as NSString
        return fileReferenceCandidates.compactMap { candidate in
            text.range(of: candidate.path, options: .literal).location != NSNotFound || text.range(of: candidate.name, options: .literal).location != NSNotFound ? candidate.file : nil
        }
    }
    func referenceFile(_ file: TaskFile) {
        if !draft.isEmpty && !draft.hasSuffix(" ") { draft += " " }
        draft += "@\(file.name) "
    }

    var origin: URL? { URL(string: server.trimmingCharacters(in: .whitespacesAndNewlines)) }
    var workspaceTitle: String {
        if let cwd = conversation.cwd, !cwd.isEmpty {
            return cwd.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? "随行任务"
        }
        return "随行任务"
    }
    var progressTitle: String { engine == "dsh" ? "深度求索中…" : "正在执行…" }
    var engineTitle: String { PocketEngine.title(engine) }
    var engineSymbol: String { PocketEngine.symbol(engine) }
    var modelLabel: String { conversation.controls?.modelLabel ?? conversation.controls?.modelId ?? "模型设置" }
    var modelAndEffortLabel: String {
        guard let effort = conversation.controls?.reasoningEffort, !effort.isEmpty else { return modelLabel }
        return modelLabel + " " + effort.capitalized
    }
    var permissionLabel: String { conversation.controls?.permissionLabel ?? "权限设置" }
    var reasoningOptions: [String] {
        conversation.controls?.models?.first(where: { $0.id == conversation.controls?.modelId })?.reasoningEfforts ?? []
    }
    func loadControls() async {
        guard !designPreview else { return }
        let expectedEngine = engine, expectedThread = conversation.threadId
        controlsLoading = true; defer { controlsLoading = false }
        do {
            let result = try await read("api/controls", as: EngineControls.self)
            if engine == expectedEngine && conversation.threadId == expectedThread { conversation.controls = result }
        } catch { handle(error) }
    }
    func updateControls(_ patch: [String: String]) async {
        guard !working, !controlsLoading, !designPreview else { return }
        notice = nil
        controlsLoading = true; working = true
        defer { controlsLoading = false; working = false }
        let expectedEngine = engine, expectedThread = conversation.threadId
        do {
            let result = try JSONDecoder().decode(EngineControls.self, from: await data("api/controls", body: patch))
            guard patch.allSatisfy({ key, value in key == "modelId" ? result.modelId == value : key == "reasoningEffort" ? result.reasoningEffort == value : result.permissionId == value }), result.confirmed != false else { throw PocketError.message("电脑尚未确认设置，手机没有应用这次切换，请重试。") }
            if engine == expectedEngine && conversation.threadId == expectedThread { conversation.controls = result; notice = "电脑已确认模型设置。" }
            if engine == "dsh", patch["modelId"] != nil { invalidateAccountBudget() }
            await refresh()
        } catch { handle(error) }
    }
    func selectModel(_ option: EngineModelOption) async {
        var patch = ["modelId": option.id]
        let efforts = option.reasoningEfforts ?? []
        if let current = conversation.controls?.reasoningEffort, efforts.contains(current) { patch["reasoningEffort"] = current }
        else if let next = efforts.first(where: { $0 == "medium" }) ?? efforts.first { patch["reasoningEffort"] = next }
        await updateControls(patch)
    }
    var canCreateSession: Bool { conversation.capabilities?.newSession ?? (engine == "dsh") }
    var canDeleteSession: Bool { conversation.capabilities?.deleteSession == true }
    var sessionDeleteLabel: String { conversation.capabilities?.deleteMode == "archive" ? "归档对话" : "删除对话" }
    func canDeleteHistory(_ item: HistoryItem) -> Bool {
        canDeleteSession && !working && item.busy != true && !(conversation.threadId == item.id && conversation.busy)
    }
    func selectEngine(_ value: String) {
        guard PocketEngine.all.contains(value), value != engine, !working else { return }
        voiceRecorder.cancel()
        saveCurrentSnapshot()
        stopUpdates()
        accountBudget = budgetsByEngine[value]
        selectionRevision += 1
        let csrf = conversation.csrf
        engine = value
        if let thread = lastThreadByEngine[value], let cached = conversationCache[value + ":" + thread] {
            conversation = cached.conversation; files = cached.files; usageHistory = cached.usage
        } else if designPreview {
            conversation.title = value == "dsh" ? "DSH 测试工作台" : "随行界面优化"
            conversation.threadId = value + "-preview"
        } else {
            conversation = Conversation(); files = []; usageHistory = UsageHistory()
        }
        conversation.csrf = csrf
        if !designPreview { history = []; connected = false; loadingConversation = true }
        recentSessions = recentByEngine[value] ?? []
        lastUsageRefresh = .distantPast; lastStateRefresh = .distantPast
        lastFileRefresh = .distantPast
        beginUpdates()
    }
    var sessionCookie: HTTPCookie? {
        guard let host = origin?.host, let token = sessionToken else { return nil }
        return HTTPCookie(properties: [.domain: host, .path: "/", .name: "pocket_session", .value: token])
    }
    private func validatedOrigin() throws -> URL {
        guard let u = origin, let host = u.host, ["http", "https"].contains(u.scheme),
              u.user == nil, u.password == nil, u.query == nil, u.fragment == nil,
              u.path.isEmpty || u.path == "/" else {
            throw PocketError.message("请输入电脑的蒲公英地址，例如 http://172.16.3.70:8789")
        }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        let privateIP = parts.count == 4 && parts.allSatisfy { (0...255).contains($0) } &&
            (parts[0] == 10 || (parts[0] == 172 && (16...31).contains(parts[1])) ||
             (parts[0] == 192 && parts[1] == 168))
        var fixtureLocalhost = false
        #if DEBUG && targetEnvironment(simulator)
        fixtureLocalhost = ProcessInfo.processInfo.arguments.contains("--network-fixture") && host == "127.0.0.1"
        #endif
        guard u.scheme == "https" || privateIP || fixtureLocalhost else {
            throw PocketError.message("HTTP 只允许蒲公英或局域网地址，其他服务器必须使用 HTTPS。")
        }
        return u
    }
    private func request(_ route: String, body: [String: Any]? = nil,
                         query: [URLQueryItem] = []) throws -> URLRequest {
        let base = try validatedOrigin()
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        c.path = "/_pocket/" + route
        c.queryItems = route.hasPrefix("api/") ? query + [URLQueryItem(name: "engine", value: engine)] : (query.isEmpty ? nil : query)
        var req = URLRequest(url: c.url!)
        req.timeoutInterval = 110
        req.setValue(base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")), forHTTPHeaderField: "Origin")
        if let cookie = sessionCookie { req.setValue("pocket_session=\(cookie.value)", forHTTPHeaderField: "Cookie") }
        if let body {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(conversation.csrf, forHTTPHeaderField: "X-Pocket-CSRF")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return req
    }
    private func check(_ response: URLResponse, data: Data) throws {
        guard let response = response as? HTTPURLResponse else { throw PocketError.message("电脑返回了无效响应。") }
        if response.statusCode == 401 { throw PocketError.expired }
        guard (200..<300).contains(response.statusCode) else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw PocketError.message(json?["error"] as? String ?? "电脑服务错误（\(response.statusCode)）")
        }
    }
    private func data(_ route: String, body: [String: Any]? = nil,
                      query: [URLQueryItem] = []) async throws -> Data {
        let (data, response) = try await session.data(for: request(route, body: body, query: query))
        try check(response, data: data)
        return data
    }
    private func read<T: Decodable>(_ route: String, as type: T.Type) async throws -> T {
        let bytes = try await data(route)
        return try await Task.detached(priority: .userInitiated) {
            let value = try JSONDecoder().decode(type, from: bytes)
            if let conversation = value as? Conversation { MessageRenderPreparation.prepare(conversation.messages) }
            return value
        }.value
    }
    private func handle(_ error: Error) {
        if Task.isCancelled { return }
        if case PocketError.expired = error {
            loggedIn = false; connected = false; stopUpdates(); sessionToken = nil; Vault.clear()
        }
        notice = error.localizedDescription
    }
    func restore() async {
        guard !designPreview else { return }
        guard !loggedIn, let token = Vault.read() else { return }
        sessionToken = token
        do {
            conversation = try await read("api/state", as: Conversation.self)
            loggedIn = true; connected = true; beginUpdates()
            await loadFiles()
            await resumeNotificationLink()
        } catch {
            // Keep the keychain entry when the computer is only offline.
            if case PocketError.expired = error { Vault.clear(); sessionToken = nil }
            notice = "暂时无法恢复连接，请确认电脑服务和蒲公英已启动。"
        }
    }
    func login() async {
        guard !working else { return }
        working = true; defer { working = false }
        do {
            let base = try validatedOrigin()
            sessionToken = nil
            server = base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let (data, response) = try await session.data(for: request("login", body: ["password": password]))
            if (response as? HTTPURLResponse)?.statusCode == 401 {
                throw PocketError.message("电脑控制密码不正确，请在电脑的手机连接信息文件中核对。")
            }
            try check(response, data: data)
            let cookies = HTTPCookieStorage.shared.cookies(for: base) ?? []
            guard let cookie = cookies.first(where: { $0.name == "pocket_session" }) else {
                throw PocketError.message("未收到电脑连接凭证，请重试。")
            }
            sessionToken = cookie.value
            try Vault.save(cookie.value)
            for index in pendingImages.indices { pendingImages[index].uploadedId = nil }
            UserDefaults.standard.set(server, forKey: "pocket.server")
            password = ""
            conversation = try await read("api/state", as: Conversation.self)
            loggedIn = true; connected = true; beginUpdates()
            await loadFiles()
            working = false
            await resumeNotificationLink()
        } catch { handle(error) }
    }
    func refresh(force: Bool = false) async {
        guard loggedIn, !refreshingSelections.contains(selectionRevision), !selectionChanging, !draggingTokenPanel, !interactingWithTranscript, force || Date().timeIntervalSince(lastStateRefresh) >= 0.6 else { return }
        guard force || Date().timeIntervalSince(lastDraftEditAt) >= 0.7 else { return }
        lastStateRefresh = Date()
        let expectedEngine = engine, expectedRevision = selectionRevision
        refreshingSelections.insert(expectedRevision)
        defer { refreshingSelections.remove(expectedRevision) }
        do {
            let wasBusy = conversation.busy
            let updated = try await read("api/state", as: Conversation.self)
            guard expectedEngine == engine, expectedRevision == selectionRevision, !selectionChanging, !draggingTokenPanel, !interactingWithTranscript, force || Date().timeIntervalSince(lastDraftEditAt) >= 0.7 else { return }
            if updated.historyReady == false {
                connected = updated.connected ?? false; loadingConversation = true
                return
            }
            if updated.connected == false, updated.messages.isEmpty, updated.threadId == conversation.threadId, !conversation.messages.isEmpty {
                connected = false
                return
            }
            conversation = updated; connected = updated.connected ?? true; loadingConversation = false
            rememberCurrentSession()
            saveCurrentSnapshot()
            if Date().timeIntervalSince(budgetRefreshAt[engine] ?? .distantPast) > 30 { Task { await self.loadAccountBudget() } }
            if Date().timeIntervalSince(lastUsageRefresh) > (usagePanelVisible ? 1 : 3) { await loadUsage() }
            if (wasBusy && !conversation.busy) || Date().timeIntervalSince(lastFileRefresh) > (conversation.busy ? 6 : 30) {
                lastFileRefresh = Date()
                if let list = try? await read("api/files", as: FileList.self), expectedEngine == engine, expectedRevision == selectionRevision, files != list.files { files = list.files }
            }
        }
        catch { guard expectedRevision == selectionRevision else { return }; connected = false; loadingConversation = false; if case PocketError.expired = error { handle(error) } }
    }
    func beginUpdates() {
        guard !designPreview else { return }
        stopUpdates()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            }
        }
        eventTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    var req = try self.request("api/events")
                    req.timeoutInterval = 3600
                    let (bytes, response) = try await self.session.bytes(for: req)
                    try self.check(response, data: Data())
                    for try await line in bytes.lines {
                        if Task.isCancelled { return }
                        if line.hasPrefix("data: "), let data = String(line.dropFirst(6)).data(using: .utf8),
                           let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            let params = event["params"] as? [String: Any]
                            if params?["engine"] as? String == nil || params?["engine"] as? String == self.engine { await self.refresh() }
                        }
                    }
                } catch { if Task.isCancelled { return } }
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            }
        }
    }
    func stopUpdates() { eventTask?.cancel(); pollTask?.cancel(); eventTask = nil; pollTask = nil }
    func act(_ route: String, body: [String: String] = [:]) async {
        guard !working else { return }
        working = true; defer { working = false }
        do {
            if route == "new" { voiceRecorder.cancel(); saveCurrentSnapshot(); selectionRevision += 1; lastStateRefresh = .distantPast }
            _ = try await data("api/" + route, body: body)
            await refresh(force: true)
        }
        catch { handle(error) }
    }
    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!text.isEmpty || !pendingImages.isEmpty || !pendingDocuments.isEmpty), !conversation.busy, !working else { return }
        working = true; defer { working = false }
        defer { uploadStatus = nil }
        do {
            var ids: [String] = []
            for index in pendingImages.indices {
                if let id = pendingImages[index].uploadedId { ids.append(id); continue }
                uploadStatus = "正在上传图片 \(index + 1)/\(pendingImages.count)"
                let image = pendingImages[index]
                let result = try JSONDecoder().decode(UploadedImage.self, from: await data("api/attachments", body: ["name": image.name, "mimeType": "image/jpeg", "base64": image.data.base64EncodedString()]))
                pendingImages[index].uploadedId = result.id
                ids.append(result.id)
            }
            for index in pendingDocuments.indices {
                if let id = pendingDocuments[index].uploadedId { ids.append(id); continue }
                uploadStatus = "正在上传文件 \(index + 1)/\(pendingDocuments.count)"
                let file = pendingDocuments[index]
                let result = try JSONDecoder().decode(UploadedImage.self, from: await data("api/documents", body: ["name": file.name, "mimeType": file.mimeType, "base64": file.data.base64EncodedString()]))
                pendingDocuments[index].uploadedId = result.id; ids.append(result.id)
            }
            _ = try await data("api/send", body: ["text": text, "attachments": ids])
            voiceRecorder.cancel(); draft = ""; pendingImages = []; pendingDocuments = []; await refresh()
        }
        catch { handle(error) }
    }
    func addImage(_ original: Data, assetIdentifier: String? = nil) {
        guard !working else { return }
        guard pendingImages.count + pendingDocuments.count < 5 else { notice = "每条消息最多添加 5 个附件。"; return }
        guard original.count <= 40 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(original as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 4096] as CFDictionary),
              let data = UIImage(cgImage: thumbnail).jpegData(compressionQuality: 0.9), data.count <= 10 * 1024 * 1024 else {
            notice = "这张图片无法读取或过大，请换一张截图。"; return
        }
        pendingImages.append(PendingImage(name: "手机图片-\(pendingImages.count + 1).jpg", data: data, assetIdentifier: assetIdentifier))
    }
    func replaceImage(_ id: UUID, with data: Data) {
        guard !working, data.count <= 10 * 1024 * 1024, let index = pendingImages.firstIndex(where: { $0.id == id }) else { return }
        let name = pendingImages[index].name
        pendingImages[index] = PendingImage(name: name, data: data, assetIdentifier: pendingImages[index].assetIdentifier)
    }
    func addDocument(_ bytes: Data, name: String, mimeType: String) {
        guard !working else { return }
        guard pendingImages.count + pendingDocuments.count < 5 else { notice = "每条消息最多添加 5 个附件。"; return }
        guard !bytes.isEmpty, bytes.count <= 20 * 1024 * 1024 else { notice = "单个文件请控制在20MB以内。"; return }
        guard pendingImages.reduce(0, { $0 + $1.data.count }) + pendingDocuments.reduce(0, { $0 + $1.data.count }) + bytes.count <= 50 * 1024 * 1024 else { notice = "本条消息的附件总大小不能超过50MB。"; return }
        pendingDocuments.append(PendingDocument(name: name, data: bytes, mimeType: mimeType))
    }
    func loadUsage() async {
        guard loggedIn, !designPreview, !draggingTokenPanel, !interactingWithTranscript else { return }
        lastUsageRefresh = Date()
        let expectedEngine = engine, expectedThread = conversation.threadId, expectedRevision = selectionRevision
        do {
            let snapshot = try await read("api/usage", as: UsageSnapshot.self)
            guard expectedEngine == engine, expectedRevision == selectionRevision, expectedThread == conversation.threadId, snapshot.threadId == expectedThread, !draggingTokenPanel, !interactingWithTranscript else { return }
            usageHistory = snapshot.history
        } catch { /* Keep real last-known data when an older bridge or network is temporarily unavailable. */ }
    }
    func loadAccountBudget() async {
        guard loggedIn, !designPreview else { return }
        let expectedEngine = engine, expectedRevision = budgetRevision
        budgetRefreshAt[expectedEngine] = Date()
        do {
            let value = try await read("api/account", as: AccountBudget.self)
            guard expectedEngine != "dsh" || expectedRevision == budgetRevision else { return }
            budgetsByEngine[expectedEngine] = value
            if expectedEngine == engine, accountBudget != value { accountBudget = value }
        } catch {
            guard expectedEngine != "dsh" || expectedRevision == budgetRevision else { return }
            if var value = budgetsByEngine[expectedEngine] { value.stale = true; budgetsByEngine[expectedEngine] = value; if expectedEngine == engine { accountBudget = value } }
        }
    }
    private func invalidateAccountBudget() {
        budgetRevision += 1; accountBudget = nil; budgetsByEngine.removeValue(forKey: engine); budgetRefreshAt[engine] = .distantPast
    }
    func transcribeVoice(_ bytes: Data, duration: Double) async throws -> VoiceTranscript {
        guard !bytes.isEmpty, bytes.count <= 10 * 1024 * 1024 else { throw PocketError.message("录音为空或过大，请分段录制。") }
        let result = try JSONDecoder().decode(VoiceTranscript.self, from: await data("api/speech", body: ["base64": bytes.base64EncodedString(), "mimeType": "audio/wav", "name": "speech.wav", "duration": duration, "language": "zh"]))
        guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PocketError.message("未识别到文字，请靠近麦克风再试。") }
        return result
    }
    @discardableResult func answerQuestion(_ id: String, answers: [String: [String]]) async -> Bool {
        guard !working else { return false }
        if designPreview {
            conversation.questions?.removeAll { $0.id == id }
            conversation.messages.append(Message(role: "user", text: "回复：" + answers.values.flatMap { $0 }.joined(separator: "、"), time: Date().timeIntervalSince1970 * 1000, itemId: UUID().uuidString))
            return true
        }
        answeringQuestionId = id
        working = true; defer { working = false }
        defer { answeringQuestionId = nil }
        do {
            _ = try await data("api/question", body: ["id": id, "answers": answers])
            selectionRevision += 1
            lastStateRefresh = .distantPast
            await refresh(force: true)
            return true
        } catch { handle(error); return false }
    }
    func loadFiles() async {
        guard !designPreview else { return }
        let expectedEngine = engine, expectedRevision = selectionRevision
        do { let list = try await read("api/files", as: FileList.self); if engine == expectedEngine, expectedRevision == selectionRevision { files = list.files } }
        catch { handle(error) }
    }
    func loadHistory() async {
        guard !designPreview else { return }
        let expectedEngine = engine, expectedRevision = selectionRevision
        do { let list = try await read("api/history", as: HistoryList.self); if engine == expectedEngine, selectionRevision == expectedRevision { history = list.items } }
        catch { handle(error) }
    }
    func deleteHistory(_ item: HistoryItem) async {
        guard canDeleteHistory(item) else { notice = "正在工作的对话请先停止任务，再操作。"; return }
        notice = nil; voiceRecorder.cancel()
        selectionRevision += 1; selectionChanging = true; working = true; stopUpdates()
        defer { selectionChanging = false; working = false; loadingConversation = false; beginUpdates() }
        do {
            if !designPreview {
                let result = try JSONDecoder().decode(SessionDeletion.self, from: await data("api/history/delete", body: ["id": item.id]))
                guard result.id == item.id, ["deleted", "archived"].contains(result.operation) else { throw PocketError.message("电脑尚未确认操作，请刷新列表检查。") }
            }
            let key = engine + ":" + item.id
            conversationCache.removeValue(forKey: key); cacheOrder.removeAll { $0 == key }
            recentByEngine[engine]?.removeAll { $0.id == item.id }; recentSessions.removeAll { $0.id == item.id }
            history.removeAll { $0.id == item.id }
            if lastThreadByEngine[engine] == item.id { lastThreadByEngine.removeValue(forKey: engine) }
            let wasCurrent = conversation.threadId == item.id
            if wasCurrent {
                let previous = conversation
                conversation = Conversation(); conversation.csrf = previous.csrf; conversation.capabilities = previous.capabilities
                conversation.controls = previous.controls; conversation.connected = previous.connected; conversation.engine = engine
                files = []; usageHistory = UsageHistory()
            }
            // Acknowledgement precedes list/cache removal. Late polling responses
            // carry an older revision and cannot restore the removed conversation.
            if !designPreview {
                let refreshedHistory = try await read("api/history", as: HistoryList.self)
                history = refreshedHistory.items
                if wasCurrent, let next = history.first {
                    loadingConversation = true
                    _ = try await data("api/history/open", body: ["id": next.id])
                    let nextState = try await read("api/state", as: Conversation.self)
                    guard nextState.threadId == next.id else { throw PocketError.message("会话已处理，请重新选择下一条对话。") }
                    conversation = nextState; connected = nextState.connected ?? true
                    let nextFiles = try? await read("api/files", as: FileList.self)
                    if let list = nextFiles { files = list.files }
                    rememberCurrentSession(); saveCurrentSnapshot()
                }
            } else if wasCurrent, let next = history.first { conversation.threadId = next.id; conversation.title = next.title; rememberCurrentSession() }
            lastStateRefresh = .distantPast; lastUsageRefresh = .distantPast
        } catch { handle(error) }
    }
    func openHistory(_ id: String) async {
        guard !working, !openingSession else { return }
        voiceRecorder.cancel()
        if designPreview {
            saveCurrentSnapshot()
            if let item = history.first(where: { $0.id == id }) { conversation.threadId = id; conversation.title = item.title; rememberCurrentSession() }
            return
        }
        notice = nil
        saveCurrentSnapshot()
        selectionRevision += 1
        selectionChanging = true; openingSession = true; loadingConversation = true; working = true
        if engine == "dsh" { invalidateAccountBudget() }
        if let cached = conversationCache[engine + ":" + id] { conversation = cached.conversation; files = cached.files; usageHistory = cached.usage }
        stopUpdates()
        defer { selectionChanging = false; openingSession = false; loadingConversation = false; working = false; beginUpdates() }
        do {
            _ = try await data("api/history/open", body: ["id": id])
            let state = try await read("api/state", as: Conversation.self)
            guard state.threadId == id else { throw PocketError.message("电脑会话尚未切换完成，请重试。") }
            conversation = state; connected = state.connected ?? true
            files = []; usageHistory = UsageHistory(); lastUsageRefresh = .distantPast; lastStateRefresh = .distantPast
            rememberCurrentSession()
            let fileResult = try? await read("api/files", as: FileList.self)
            if let list = fileResult { files = list.files }
            saveCurrentSnapshot()
        } catch { handle(error) }
    }
    private func rememberCurrentSession() {
        guard let id = conversation.threadId else { return }
        let row = history.first(where: { $0.id == id })
        let item = HistoryItem(id: id, title: conversation.title ?? row?.title ?? "未命名对话", time: row?.time ?? Date().timeIntervalSince1970 * 1000, cwd: conversation.cwd ?? row?.cwd, busy: conversation.busy)
        var items = recentByEngine[engine] ?? []
        if items.first?.id == id { items[0] = item } else { items.removeAll { $0.id == id }; items.insert(item, at: 0) }
        items = Array(items.prefix(8)); recentByEngine[engine] = items
        if recentSessions.map(\.id) != items.map(\.id) || recentSessions.map(\.title) != items.map(\.title) || recentSessions.map(\.busy) != items.map(\.busy) { recentSessions = items }
    }
    private func saveCurrentSnapshot() {
        guard let id = conversation.threadId, conversation.historyReady != false else { return }
        let key = engine + ":" + id
        conversationCache[key] = CachedConversation(conversation: conversation, files: files, usage: usageHistory)
        lastThreadByEngine[engine] = id
        cacheOrder.removeAll { $0 == key }; cacheOrder.append(key)
        while cacheOrder.count > 8 { conversationCache.removeValue(forKey: cacheOrder.removeFirst()) }
    }
    func previewFile(_ name: String) async {
        guard !fileLoading else { return }
        fileLoading = true; defer { fileLoading = false }
        do {
            let file = try JSONDecoder().decode(MessageFile.self, from: await data("api/file-reference", query: [URLQueryItem(name: "name", value: name)]))
            try await presentConversationFile(file, engine: engine)
        } catch { handle(error) }
    }
    func openConversationFile(_ file: MessageFile, engine requestedEngine: String) async {
        guard !fileLoading else { return }; fileLoading = true; defer { fileLoading = false }
        do { try await presentConversationFile(file, engine: requestedEngine) } catch { handle(error) }
    }
    private func presentConversationFile(_ file: MessageFile, engine requestedEngine: String) async throws {
        if file.kind == "video" || file.kind == "audio" { playback = MediaPlayback(file: file, engine: requestedEngine, url: try await mediaAccess(file, engine: requestedEngine)) }
        else { preview = PreviewFile(url: try await downloadConversationFile(file, engine: requestedEngine)) }
    }
    private func mediaAccess(_ file: MessageFile, engine requestedEngine: String) async throws -> URL {
        #if DEBUG && targetEnvironment(simulator)
        if designPreview { return try await PreviewMediaFactory.file(file) }
        #endif
        if let remote = file.remoteURL {
            guard let url = URL(string: remote), url.scheme == "https", url.user == nil, url.password == nil else { throw PocketError.message("文件链接无效。") }; return url
        }
        var req = try request("api/media-ticket", query: [URLQueryItem(name: "id", value: file.id)])
        var parts = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
        parts.queryItems = (parts.queryItems ?? []).filter { $0.name != "engine" } + [URLQueryItem(name: "engine", value: requestedEngine)]; req.url = parts.url
        let (bytes, response) = try await session.data(for: req); try check(response, data: bytes)
        let access = try JSONDecoder().decode(MediaAccess.self, from: bytes).url
        guard access.scheme == req.url?.scheme, access.host == req.url?.host, access.port == req.url?.port, access.path == "/_pocket/api/media" else { throw PocketError.message("电脑返回的文件地址无效。") }
        return access
    }
    func downloadConversationFile(_ file: MessageFile, engine requestedEngine: String) async throws -> URL {
        #if DEBUG && targetEnvironment(simulator)
        if designPreview { return try await PreviewMediaFactory.file(file) }
        #endif
        guard file.id.count <= 160, file.id.range(of: "^[-_A-Za-z0-9]+$", options: .regularExpression) != nil else { throw PocketError.message("文件标识无效。") }
        var req = URLRequest(url: try await mediaAccess(file, engine: requestedEngine)); req.timeoutInterval = 300
        let configuration = URLSessionConfiguration.ephemeral; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil; configuration.httpShouldSetCookies = false
        let downloader = URLSession(configuration: configuration); defer { downloader.finishTasksAndInvalidate() }
        let (temporary, response) = try await downloader.download(for: req); try check(response, data: Data())
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("对话附件", isDirectory: true).appendingPathComponent(file.id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = (file.name as NSString).lastPathComponent
        let destination = folder.appendingPathComponent(name.isEmpty ? "文件" : name)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: temporary, to: destination); return destination
    }
    func imageData(_ image: MessageImage, engine requestedEngine: String) async throws -> Data {
        #if DEBUG && targetEnvironment(simulator)
        if designPreview {
            return UIGraphicsImageRenderer(size: CGSize(width: 800, height: 500)).pngData { context in
                UIColor(red: 0.92, green: 0.95, blue: 1, alpha: 1).setFill(); context.fill(CGRect(x: 0, y: 0, width: 800, height: 500))
                (image.name as NSString).draw(at: CGPoint(x: 50, y: 80), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 42), .foregroundColor: UIColor.systemBlue])
                for i in 0..<3 { UIColor.systemBlue.withAlphaComponent(CGFloat(i + 1) * 0.18).setFill(); context.fill(CGRect(x: CGFloat(50 + i * 235), y: 210, width: 200, height: 180)) }
                ("合成验收图片 · 点开可放大" as NSString).draw(at: CGPoint(x: 50, y: 430), withAttributes: [.font: UIFont.systemFont(ofSize: 24), .foregroundColor: UIColor.secondaryLabel])
            }
        }
        #endif
        let limit = 20 * 1024 * 1024
        if let raw = image.remoteURL {
            guard let url = URL(string: raw), url.scheme == "https", url.user == nil, url.password == nil else { throw PocketError.message("图片地址无效。") }
            let download = Task.detached(priority: .utility) {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false; configuration.urlCredentialStorage = nil
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                let remote = URLSession(configuration: configuration)
                defer { remote.finishTasksAndInvalidate() }
                var req = URLRequest(url: url); req.timeoutInterval = 25
                let (stream, response) = try await remote.bytes(for: req)
                guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                      response.mimeType?.hasPrefix("image/") == true, response.expectedContentLength <= Int64(limit) else { throw PocketError.message("远程图片暂不可用。") }
                var bytes = Data()
                for try await byte in stream { if bytes.count >= limit { throw PocketError.message("图片超过20MB。") }; bytes.append(byte) }
                return bytes
            }
            return try await withTaskCancellationHandler(operation: { try await download.value }, onCancel: { download.cancel() })
        }
        var req = try request("api/image", query: [URLQueryItem(name: "id", value: image.id)])
        var components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
        components.queryItems = (components.queryItems ?? []).filter { $0.name != "engine" } + [URLQueryItem(name: "engine", value: requestedEngine)]
        req.url = components.url; req.timeoutInterval = 25
        let (bytes, response) = try await session.data(for: req)
        try check(response, data: bytes)
        guard bytes.count <= limit, response.mimeType?.hasPrefix("image/") == true else { throw PocketError.message("电脑返回的图片无效或过大。") }
        return bytes
    }
    func previewImage(_ image: MessageImage, engine requestedEngine: String) async {
        guard !fileLoading else { return }
        fileLoading = true; defer { fileLoading = false }
        do {
            let bytes = try await imageData(image, engine: requestedEngine)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("图片预览", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let ext = bytes.starts(with: [0x89, 0x50, 0x4e, 0x47]) ? ".png" : bytes.starts(with: [0xff, 0xd8]) ? ".jpg" : bytes.starts(with: [0x47, 0x49, 0x46]) ? ".gif" : bytes.count >= 12 && bytes.subdata(in: 4..<8) == Data("ftyp".utf8) ? ".heic" : ".webp"
            let url = folder.appendingPathComponent(image.id + ext)
            try bytes.write(to: url, options: .atomic)
            preview = PreviewFile(url: url)
        } catch { handle(error) }
    }
    func logout() async {
        _ = try? await data("api/logout", body: [:])
        selectionRevision += 1
        stopUpdates(); Vault.clear(); sessionToken = nil; loggedIn = false; connected = false
        conversation = Conversation()
        conversationCache = [:]; cacheOrder = []; lastThreadByEngine = [:]; recentByEngine = [:]; recentSessions = []
        accountBudget = nil; budgetsByEngine = [:]; budgetRefreshAt = [:]
        pendingImages = []; draft = ""
        if let origin { for cookie in HTTPCookieStorage.shared.cookies(for: origin) ?? [] { HTTPCookieStorage.shared.deleteCookie(cookie) } }
    }
    func loadNotifications() async throws -> NotificationSettings {
        if designPreview { return NotificationSettings() }
        return try await read("api/notifications", as: NotificationSettings.self)
    }
    func saveNotifications(_ value: NotificationSettings, barkURL: String, remove: Bool = false) async throws -> NotificationSettings {
        guard !designPreview else { return value }
        var body: [String: Any] = ["enabled": value.enabled, "complete": value.complete, "failed": value.failed, "attention": value.attention, "taskPreview": value.taskPreview]
        if !barkURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { body["barkURL"] = barkURL }
        if remove { body = ["remove": true] }
        return try JSONDecoder().decode(NotificationSettings.self, from: await data("api/notifications", body: body))
    }
    func testNotifications() async throws {
        guard !designPreview else { return }
        _ = try await data("api/notifications/test", body: [:])
    }
    var installedAppVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    var installedAppBuild: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0" }
    func checkAppUpdates() async throws -> AppUpdateInfo {
        if designPreview {
            return AppUpdateInfo(available: false, installed: AppUpdateVersion(version: installedAppVersion, build: installedAppBuild), latest: AppUpdateRelease(version: installedAppVersion, build: installedAppBuild, publishedAt: "2026-10-17T00:00:00+08:00", notes: "三款 AI 切换，保留电脑原会话；增加软件更新与电脑安装助手。\n\n此处为模拟器界面演示，不会打开真实电脑软件。", sha256: String(repeating: "0", count: 64), size: 1000000, minOSVersion: "16.0"), signing: AppUpdateSigning(requiresSigning: true, refreshDays: 7, automaticInstall: false), message: "当前已是已发布的最新版本。")
        }
        let bytes = try await data("api/app-updates", query: [URLQueryItem(name: "version", value: installedAppVersion), URLQueryItem(name: "build", value: installedAppBuild)])
        return try JSONDecoder().decode(AppUpdateInfo.self, from: bytes)
    }
    func openDesktopUpdateInstaller() async throws {
        guard !designPreview else { throw PocketError.message("界面演示不会操作真实电脑。") }
        _ = try await data("api/app-updates/open-installer", body: [:])
    }
    func receiveNotificationLink(_ url: URL) async {
        guard let target = NotificationDestination.parse(url) else { return }
        pendingNotificationLink = target
        await resumeNotificationLink()
    }
    private func resumeNotificationLink() async {
        guard loggedIn, pendingNotificationLink != nil else { return }
        for _ in 0..<20 where working { try? await Task.sleep(nanoseconds: 250_000_000) }
        guard !working, let target = pendingNotificationLink else { return }
        pendingNotificationLink = nil; notificationLinkSerial += 1
        selectEngine(target.engine)
        if let id = target.threadId { await openHistory(id) }
    }
}

