import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

private let inkBlue = Color(red: 0.25, green: 0.43, blue: 0.87)
private let softInk = Color(red: 0.56, green: 0.57, blue: 0.60)
private let hairline = Color.black.opacity(0.065)

enum WorkspacePanel: String, Identifiable {
    case files, history, settings, tasks, permissions, reference, models, usage, questions, notifications, updates
    var id: String { rawValue }
}

struct WorkspaceView: View {
    @EnvironmentObject private var model: PocketModel
    @State private var panel: WorkspacePanel?
    @State private var confirmNew = false
    @State private var sidebarOpen = false
    @AppStorage("pocket.tokenOverlay") private var tokenOverlay = true
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                if model.recentSessions.count > 1 { recentStrip }
                ChatView(openPanel: { panel = $0 }, newChat: { confirmNew = true })
                    .overlay { if tokenOverlay { FloatingTokenPanel(openDetails: { panel = .usage }) } }
            }
            .background(.white)
            .toolbar(.hidden, for: .navigationBar)
        }
        .overlay(alignment: .leading) {
            if sidebarOpen {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Color.black.opacity(0.20).ignoresSafeArea().onTapGesture { withAnimation(.easeOut(duration: 0.2)) { sidebarOpen = false } }
                        SessionSidebar(close: { withAnimation(.easeOut(duration: 0.2)) { sidebarOpen = false } }, newSession: { sidebarOpen = false; confirmNew = true })
                            .frame(width: min(340, geometry.size.width * 0.87)).shadow(color: .black.opacity(0.10), radius: 20, x: 6)
                            .transition(.move(edge: .leading))
                    }
                }
            }
        }
        .overlay { VoiceRecordingOverlay(voice: model.voiceRecorder).allowsHitTesting(false) }
        .overlay { if model.openingSession { ProgressView("正在切换会话…").padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)) } }
        .sheet(item: $panel) { item in
            NavigationStack {
                panelContent(item)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { panel = nil } } }
            }
            .sheet(item: $model.preview) { file in FilePreviewSheet(url: file.url) }
        }
        .sheet(item: Binding(get: { panel == nil ? model.preview : nil }, set: { model.preview = $0 })) { file in
            FilePreviewSheet(url: file.url)
        }
        .sheet(item: $model.playback) { item in MediaPlaybackSheet(item: item) }
        .confirmationDialog("新建对话？当前会话会保留在记录中。", isPresented: $confirmNew, titleVisibility: .visible) {
            Button("新建对话") { Task { await model.act("new") } }
        }
        .onAppear {
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--show-models") { panel = .models }
            if ProcessInfo.processInfo.arguments.contains("--show-sidebar") { sidebarOpen = true }
            if ProcessInfo.processInfo.arguments.contains("--show-market") { panel = .usage }
            if ProcessInfo.processInfo.arguments.contains("--show-notifications") { panel = .notifications }
            if ProcessInfo.processInfo.arguments.contains("--show-updates") { panel = .updates }
            #endif
        }
        .onChange(of: model.notificationLinkSerial) { _ in panel = nil; sidebarOpen = false }
    }
    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Button { withAnimation(.easeOut(duration: 0.2)) { sidebarOpen.toggle() } } label: { Image(systemName: "sidebar.left").font(.system(size: 19)) }
                    .frame(width: 30, height: 40).accessibilityLabel("会话记录")
                Text(model.workspaceTitle).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text("/").font(.system(size: 17)).foregroundStyle(Color(.systemGray3))
                Menu {
                    ForEach(PocketEngine.all, id: \.self) { engine in
                        Button { model.selectEngine(engine) } label: { Label(PocketEngine.title(engine), systemImage: model.engine == engine ? "checkmark" : PocketEngine.symbol(engine)) }
                    }
                } label: {
                    HStack(spacing: 5) { Text(model.engineTitle).font(.system(size: 15, weight: .medium)); Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)) }
                }.disabled(model.working).accessibilityLabel("切换 AI 引擎")
                Spacer(minLength: 0)
                Menu {
                    Button { confirmNew = true } label: { Label(model.canCreateSession ? "新建对话" : "新对话请在电脑创建", systemImage: "square.and.pencil") }.disabled(!model.canCreateSession)
                    Button { panel = .files } label: { Label("任务文件", systemImage: "folder") }
                    Button { withAnimation(.easeOut(duration: 0.2)) { sidebarOpen = true } } label: { Label("电脑会话", systemImage: "clock.arrow.circlepath") }
                    Button { panel = .settings } label: { Label("连接设置", systemImage: "gearshape") }
                    Button { panel = .notifications } label: { Label("任务通知", systemImage: "bell.badge") }
                    Button { panel = .updates } label: { Label("软件更新", systemImage: "arrow.down.app") }
                    Button { panel = .usage } label: { Label("Token 实时用量", systemImage: "chart.bar") }
                    Toggle("Token 悬浮面板", isOn: $tokenOverlay)
                    Button { Task { await model.refresh(); await model.loadFiles() } } label: { Label("重新同步", systemImage: "arrow.clockwise") }
                } label: { Image(systemName: "ellipsis").font(.system(size: 21)).frame(width: 32, height: 40) }.accessibilityLabel("更多操作")
            }.foregroundStyle(Color.primary).padding(.horizontal, 14)
            HStack(spacing: 7) {
                Button { panel = .permissions } label: {
                    Label(model.permissionLabel, systemImage: "checkmark.shield")
                }
                Circle().fill(model.connected ? Color.green : Color.orange).frame(width: 5, height: 5).padding(.leading, 4)
                Text(model.connected ? (model.conversation.desktopSync == false ? "独立模式" : "已同步") : "连接中").font(.system(size: 11))
                Spacer()
                Button { panel = .tasks } label: {
                    HStack(spacing: 4) { Text("\(model.conversation.busy ? 1 : 0) 个后台任务"); Image(systemName: "chevron.down").font(.system(size: 9)) }
                }
            }.font(.system(size: 12)).foregroundStyle(softInk).padding(.horizontal, 20).padding(.bottom, 13).padding(.top, 1)
        }
    }
    private var recentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(model.recentSessions) { item in
                    Button { Task { await model.openHistory(item.id) } } label: {
                        HStack(spacing: 5) { if item.busy == true { Circle().fill(.green).frame(width: 4, height: 4) }; Text(item.title).font(.system(size: 11, weight: item.id == model.conversation.threadId ? .semibold : .regular)).lineLimit(1).frame(maxWidth: 150); if item.id == model.conversation.threadId { Image(systemName: "checkmark").font(.system(size: 8)) } }.padding(.horizontal, 11).padding(.vertical, 7).foregroundStyle(item.id == model.conversation.threadId ? inkBlue : .secondary).background(item.id == model.conversation.threadId ? inkBlue.opacity(0.09) : Color(.systemGray6), in: Capsule())
                    }.buttonStyle(.plain).disabled(model.working).accessibilityIdentifier("recent-session-" + item.id)
                }
            }.padding(.horizontal, 14).padding(.bottom, 7)
        }.accessibilityIdentifier("recent-session-strip")
    }
    @ViewBuilder private func panelContent(_ item: WorkspacePanel) -> some View {
        switch item {
        case .files: FilesView()
        case .history: HistoryView()
        case .settings: SettingsView()
        case .notifications: NotificationSettingsView()
        case .updates: AppUpdateView()
        case .tasks: TaskDashboardView()
        case .permissions: ControlsSettingsView(showPermissions: true)
        case .models: ControlsSettingsView(showPermissions: false)
        case .usage: UsageMarketView()
        case .questions: PendingQuestionsView()
        case .reference: ReferenceFilesView()
        }
    }
}

struct ConnectionLabel: View {
    @EnvironmentObject private var model: PocketModel
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(model.connected ? Color.green : Color.orange).frame(width: 5, height: 5)
            Text(model.connected ? "电脑已连接" : "正在重新连接").font(.caption2).foregroundStyle(.secondary)
            Spacer()
        }.padding(12)
    }
}

struct ChatView: View {
    @EnvironmentObject private var model: PocketModel
    let openPanel: (WorkspacePanel) -> Void
    let newChat: () -> Void
    @State private var showTrace = false
    @State private var followingLatest = true
    @State private var jumpToken = 0
    @State private var composerExpanded = false
    @FocusState private var inputFocused: Bool
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var cameraPresented = false
    @State private var imagePreview: PendingImage?
    @State private var voiceMode = false
    @State private var trayOpen = false
    @State private var documentPicker = false
    @State private var modelPicker = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 27) {
                tab("对话", active: !showTrace) { showTrace = false }
                tab("轨迹", active: showTrace) { showTrace = true }
                Spacer()
                if !model.conversation.approvals.isEmpty {
                    Label("待确认", systemImage: "hand.raised").font(.system(size: 11)).foregroundStyle(Color.orange)
                }
            }.padding(.horizontal, 22).overlay(alignment: .bottom) { hairline.frame(height: 0.5) }
            if showTrace { TraceView() } else { messages }
            if let error = model.conversation.error, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            if model.loadingConversation { HStack(spacing: 7) { ProgressView().controlSize(.small); Text("正在同步电脑会话，已有记录会保留").font(.system(size: 11)).foregroundStyle(.secondary); Spacer() }.padding(.horizontal, 16).padding(.vertical, 6) }
            if !model.conversation.approvals.isEmpty { approvals }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if let questions = model.conversation.questions, !questions.isEmpty { InlineQuestionDock(requests: questions, showAll: { inputFocused = false; openPanel(.questions) }) }
                composer
                if trayOpen {
                    AttachmentTray(selectedPhotos: $selectedPhotos, camera: {
                        if UIImagePickerController.isSourceTypeAvailable(.camera) { cameraPresented = true } else { model.notice = "当前设备无法使用相机。" }
                    }, files: { documentPicker = true }).transition(.move(edge: .bottom).combined(with: .opacity)).disabled(model.working)
                }
            }.background(.white)
        }
        .onChange(of: inputFocused) { value in composerExpanded = value; if value { voiceMode = false; trayOpen = false } }
        .onChange(of: model.engine) { _ in inputFocused = false; composerExpanded = false; modelPicker = false; trayOpen = false }
        .onChange(of: model.conversation.threadId) { _ in modelPicker = false }
        .onChange(of: model.voiceDraftSerial) { _ in voiceMode = false; trayOpen = false; inputFocused = false; composerExpanded = true }
        .onDisappear { model.voiceRecorder.cancel() }
        .overlayPreferenceValue(ModelPickerAnchorKey.self) { anchor in
            ModelSelectionOverlay(anchor: anchor, presented: $modelPicker)
        }
        .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("收起键盘") { inputFocused = false; composerExpanded = false } } }
        .onChange(of: selectedPhotos) { photos in
            Task {
                for photo in photos {
                    do {
                        let data = try await photo.loadTransferable(type: Data.self)
                        if let data { model.addImage(data) }
                    } catch {
                        model.notice = "图片读取失败，请重新选择。"
                    }
                }
                selectedPhotos = []
            }
        }
        .sheet(isPresented: $cameraPresented) {
            CameraCaptureView { image in
                if let data = image?.jpegData(compressionQuality: 1) { model.addImage(data) }
                cameraPresented = false
                if image != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { imagePreview = model.pendingImages.last } }
            }.ignoresSafeArea()
        }
        .fileImporter(isPresented: $documentPicker, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            Task { @MainActor in
                do {
                    for url in try result.get().prefix(5) {
                        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                        guard info.isRegularFile == true, (info.fileSize ?? 0) <= 20 * 1024 * 1024 else { model.notice = "请选择20MB以内的文件。"; continue }
                        let bytes = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url) }.value
                        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                        if mime.hasPrefix("image/") { model.addImage(bytes) } else { model.addDocument(bytes, name: url.lastPathComponent, mimeType: mime) }
                    }
                } catch { model.notice = "文件读取失败，请重新选择。" }
            }
        }
        .sheet(item: $imagePreview) { image in
            ImageEditorView(imageData: image.data) { output in
                if let output { model.replaceImage(image.id, with: output) }
                imagePreview = nil
            }.interactiveDismissDisabled()
        }
        .onAppear {
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--show-editor") { imagePreview = model.pendingImages.first }
            if ProcessInfo.processInfo.arguments.contains("--show-attachments") { trayOpen = true }
            if ProcessInfo.processInfo.arguments.contains("--show-voice-input") { voiceMode = true }
            if ProcessInfo.processInfo.arguments.contains("--show-model-picker") { modelPicker = true }
            if ProcessInfo.processInfo.arguments.contains("--show-recording") { model.voiceRecorder.showPreview() }
            #endif
        }
    }
    private func tab(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 15, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? inkBlue : softInk).padding(.bottom, 11).padding(.top, 5)
                .overlay(alignment: .bottom) { if active { Capsule().fill(inkBlue).frame(height: 2).padding(.horizontal, 1) } }
        }.buttonStyle(.plain)
    }
    private var messages: some View {
        NativeTranscriptView(model: model, conversationKey: model.engine + ":" + (model.conversation.threadId ?? ""), jumpToken: jumpToken,
            initialFollowLatest: !(model.designPreview && ["--show-formatting", "--show-images", "--show-reading", "--show-media"].contains(where: ProcessInfo.processInfo.arguments.contains)),
            progress: model.conversation.busy ? AnyView(inlineProgress.environmentObject(model)) : nil,
            progressRevision: "\(model.conversation.busy)-\(model.conversation.events.count)-\(model.conversation.events.last?.summary ?? "")",
            emptyState: AnyView(emptyState.environmentObject(model)), onFollowingLatest: { followingLatest = $0 })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottomTrailing) {
                if !followingLatest {
                    Button { followingLatest = true; jumpToken += 1 } label: {
                        Image(systemName: "arrow.down").font(.system(size: 14, weight: .semibold)).foregroundStyle(inkBlue)
                            .frame(width: 34, height: 34).background(.white, in: Circle()).shadow(color: .black.opacity(0.10), radius: 5, y: 2)
                    }.padding(14).accessibilityLabel("回到最新回复")
                }
            }
    }
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: model.engineSymbol).font(.system(size: 27)).foregroundStyle(inkBlue)
            Text(model.loadingConversation ? "正在加载电脑会话" : "开始一项工作").font(.system(size: 23, weight: .semibold))
            Text(model.loadingConversation ? "正在同步历史记录，请稍候。" : "选择电脑上的会话继续，\n或在下方发送一条新指令。").font(.system(size: 15)).foregroundStyle(.secondary).lineSpacing(5)
            Button { openPanel(.history) } label: { Label("查看电脑会话", systemImage: "clock.arrow.circlepath").font(.system(size: 14)) }
                .buttonStyle(.bordered).tint(inkBlue)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 55).padding(.bottom, 30)
    }
    private var inlineProgress: some View {
        VStack(alignment: .leading, spacing: 13) {
            ForEach(Array(model.currentSteps.suffix(3).enumerated()), id: \.offset) { _, event in
                Button { showTrace = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: event.icon).frame(width: 16)
                        Text(event.stepTitle + " ·").fixedSize()
                        Text(event.stepSummary).lineLimit(1)
                        Spacer(minLength: 0)
                    }.font(.system(size: 12)).foregroundStyle(softInk)
                }.buttonStyle(.plain)
            }
            if model.conversation.busy {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack(spacing: 8) {
                        Text(model.progressTitle).font(.system(size: 14, weight: .medium)).foregroundStyle(inkBlue)
                        Text(elapsed(model.taskStartedAt, now: context.date)).font(.system(size: 12)).foregroundStyle(Color(.systemGray3))
                    }
                }
                if let activity = model.conversation.activity, !activity.isEmpty {
                    Text(activity).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }.padding(.top, 2)
    }
    private var approvals: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(model.conversation.approvals) { approval in
                    VStack(alignment: .leading, spacing: 8) {
                        Label("需要你的确认", systemImage: "hand.raised").font(.system(size: 14, weight: .medium))
                        DisclosureGroup("操作内容") { Text(approval.details.pretty).font(.caption.monospaced()).textSelection(.enabled) }
                        HStack {
                            Button("允许这一次") { Task { await model.act("approval", body: ["id": approval.id, "decision": "accept"]) } }.buttonStyle(.borderedProminent)
                            Button("拒绝") { Task { await model.act("approval", body: ["id": approval.id, "decision": "decline"]) } }.buttonStyle(.bordered)
                        }.disabled(model.working)
                    }.padding(12).background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                }
            }.padding(.horizontal, 15)
        }.frame(maxHeight: 175)
    }
    private var composer: some View {
        VStack(spacing: 7) {
            VStack(alignment: .leading, spacing: 9) {
                if !model.pendingImages.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(model.pendingImages) { image in
                                if let photo = UIImage(data: image.data) {
                                    Button { inputFocused = false; imagePreview = image } label: { Image(uiImage: photo).resizable().scaledToFill().frame(width: 64, height: 64).clipped().clipShape(RoundedRectangle(cornerRadius: 9)).overlay(alignment: .bottomLeading) { Image(systemName: "pencil.circle.fill").font(.system(size: 17)).foregroundStyle(.white, .black.opacity(0.65)).padding(3) } }.accessibilityLabel("裁剪、旋转或标注图片")
                                        .overlay(alignment: .topTrailing) {
                                            Button { model.pendingImages.removeAll { $0.id == image.id } } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 18)).symbolRenderingMode(.palette).foregroundStyle(.white, Color.black.opacity(0.7)) }.offset(x: 5, y: -5).accessibilityLabel("移除这张图片").disabled(model.working)
                                        }.padding(.top, 5).padding(.trailing, 5)
                                }
                            }
                        }.padding(.horizontal, 3)
                    }
                }
                if let status = model.uploadStatus { Text(status).font(.caption).foregroundStyle(inkBlue) }
                if !model.pendingDocuments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 9) {
                            ForEach(model.pendingDocuments) { file in
                                HStack(spacing: 7) { Image(systemName: "doc.fill").foregroundStyle(inkBlue); Text(file.name).font(.system(size: 12)).lineLimit(1).frame(maxWidth: 150); Button { model.pendingDocuments.removeAll { $0.id == file.id } } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.accessibilityLabel("移除文件：" + file.name) }.padding(10).background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                }
                if voiceMode {
                    VoiceComposerControl(voice: model.voiceRecorder, dismissKeyboard: { inputFocused = false; composerExpanded = false })
                } else {
                    HStack(alignment: .top, spacing: 5) {
                        ComposerTextInput(draft: model.composerDraft, focused: $inputFocused, expanded: composerExpanded, disabled: model.working, edited: { model.lastDraftEditAt = Date() })
                        Button { composerExpanded.toggle(); if !composerExpanded { inputFocused = false } } label: { Image(systemName: composerExpanded ? "chevron.down" : "chevron.up").font(.system(size: 12, weight: .semibold)).frame(width: 26, height: 24) }.foregroundStyle(softInk).accessibilityLabel(composerExpanded ? "收起输入框和键盘" : "展开输入框")
                    }.padding(.horizontal, 3).padding(.top, 2)
                }
                HStack(spacing: 8) {
                    Button { inputFocused = false; modelPicker = false; openPanel(.permissions) } label: {
                        HStack(spacing: 3) { Image(systemName: "checkmark.shield"); Text(model.permissionLabel).lineLimit(1); Image(systemName: "chevron.down").font(.system(size: 7)) }.font(.system(size: 10)).frame(maxWidth: 70)
                    }.accessibilityLabel("切换权限：" + model.permissionLabel)
                    Button {
                        inputFocused = false; trayOpen = false
                        modelPicker.toggle()
                        if modelPicker { Task { await model.loadControls() } }
                    } label: {
                        HStack(spacing: 3) { Text(model.modelAndEffortLabel).lineLimit(1).truncationMode(.middle).minimumScaleFactor(0.75); Image(systemName: "chevron.down").font(.system(size: 7)) }.font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .trailing)
                    }.accessibilityLabel("切换模型：" + model.modelLabel).anchorPreference(key: ModelPickerAnchorKey.self, value: .bounds) { $0 }
                    Button {
                        inputFocused = false; composerExpanded = false; modelPicker = false
                        withAnimation(.easeOut(duration: 0.2)) { trayOpen.toggle() }
                    } label: { Image(systemName: trayOpen ? "xmark" : "plus").font(.system(size: 17, weight: .medium)).frame(width: 30, height: 30).overlay { Circle().stroke(Color.primary.opacity(0.65), lineWidth: 1.2) } }.accessibilityLabel(trayOpen ? "收起附件面板" : "添加照片和文件")
                    VoiceModeToggle(voice: model.voiceRecorder, voiceMode: voiceMode, tap: {
                        trayOpen = false; modelPicker = false; voiceMode.toggle(); inputFocused = !voiceMode; composerExpanded = !voiceMode
                    }, dismissKeyboard: { inputFocused = false; composerExpanded = false; trayOpen = false; modelPicker = false }).frame(width: 32, height: 32)
                    ComposerSendButton(draft: model.composerDraft) {
                        inputFocused = false; composerExpanded = false; trayOpen = false; modelPicker = false
                        Task { if model.conversation.busy { await model.act("stop") } else { await model.send() } }
                    }
                }.foregroundStyle(Color(.darkGray))
            }.padding(13).background(.white, in: RoundedRectangle(cornerRadius: 21))
                .overlay { RoundedRectangle(cornerRadius: 21).stroke(hairline, lineWidth: 1) }
                .shadow(color: .black.opacity(0.035), radius: 9, y: 2)
            VoiceRecognitionStatus(voice: model.voiceRecorder)
            UsageFooter(openDetails: { inputFocused = false; openPanel(.usage) })
        }.padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 5).background(.white)
    }
}

private struct ModelSelectionOverlay: View {
    @EnvironmentObject private var model: PocketModel
    let anchor: Anchor<CGRect>?
    @Binding var presented: Bool
    var body: some View {
        GeometryReader { geometry in
            if presented, let anchor {
                let rect: CGRect = geometry[anchor]
                let desired: CGFloat = max(165, CGFloat(model.conversation.controls?.models?.count ?? 0) * 53 + 82)
                let height: CGFloat = min(330, min(desired, max(165, rect.minY - 16)))
                let width: CGFloat = min(354, geometry.size.width - 24)
                Color.black.opacity(0.04).contentShape(Rectangle()).onTapGesture { presented = false }
                CompactModelPicker(close: { presented = false }).frame(width: width, height: height)
                    .position(x: geometry.size.width - width / 2 - 12, y: max(height / 2 + 8, rect.minY - height / 2 - 8))
            }
        }
    }
}

private struct ComposerTextInput: View {
    @ObservedObject var draft: ComposerDraft
    var focused: FocusState<Bool>.Binding
    let expanded: Bool, disabled: Bool
    let edited: () -> Void
    var body: some View {
        TextField("发消息，@ 引用文件", text: $draft.text, axis: .vertical)
            .focused(focused).disabled(disabled)
            .font(.system(size: 15)).lineLimit(expanded ? 1...4 : 1...1)
            .frame(minHeight: expanded ? 42 : 22, alignment: .topLeading)
            .accessibilityIdentifier("composer-text")
            .onChange(of: draft.text) { _ in edited() }
    }
}

private struct ComposerSendButton: View {
    @EnvironmentObject private var model: PocketModel
    @ObservedObject var draft: ComposerDraft
    let send: () -> Void
    private var disabled: Bool { model.working || (!model.conversation.busy && draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.pendingImages.isEmpty && model.pendingDocuments.isEmpty) }
    var body: some View {
        Button(action: send) {
            Image(systemName: model.conversation.busy ? "stop.fill" : "arrow.up")
                .font(.system(size: model.conversation.busy ? 14 : 19, weight: .semibold))
                .foregroundStyle(.white).frame(width: 40, height: 40).background(inkBlue, in: Circle())
        }.buttonStyle(.plain).disabled(disabled).opacity(disabled ? 0.4 : 1)
            .accessibilityLabel(model.conversation.busy ? "停止当前任务" : "发送指令")
    }
}

struct ProgressMessagesView: View {
    let messages: [Message]
    let engine: String
    let opening: () -> Void
    @State private var expanded = false
    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { expanded }, set: { value in opening(); expanded = value })) {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(messages.enumerated()), id: \.offset) { index, message in
                    if index > 0 { Divider() }
                    RichMessageText(text: message.text, images: message.images ?? [], engine: engine, documents: message.documents ?? []).textSelection(.enabled)
                }
            }.padding(.top, 12)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Label("执行过程 · \(messages.count) 条", systemImage: "list.bullet.rectangle").font(.system(size: 12, weight: .medium))
                if let message = messages.last, !expanded { Text(message.text.replacingOccurrences(of: "**", with: "")).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2) }
            }
        }.tint(inkBlue).padding(12).background(Color(.secondarySystemBackground).opacity(0.6), in: RoundedRectangle(cornerRadius: 12)).accessibilityIdentifier("round-progress-disclosure")
    }
}

struct MessageBubble: View {
    let engine: String
    let message: Message
    let files: [TaskFile]
    @State private var copied = false
    @State private var sharing = false
    @State private var showingUsage = false
    private var isUser: Bool { message.role == "user" }
    private var isProgress: Bool { !isUser && message.phase == "commentary" }
    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 11) {
            HStack(spacing: 6) {
                if isUser { Spacer(); Text("你").font(.system(size: 11, weight: .semibold)).foregroundStyle(inkBlue) }
                else {
                    Image(systemName: PocketEngine.symbol(engine)).foregroundStyle(inkBlue)
                    Text((PocketEngine.title(engine)) + (message.phase == "commentary" ? " · 进度消息" : message.phase == "final_answer" ? " · 最终回复" : " · 回复")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                }
                Text(taskDate(message.time), style: .time).font(.system(size: 10)).foregroundStyle(softInk)
            }.font(.system(size: 11))
            HStack(alignment: .top, spacing: 0) {
                if isUser { Spacer(minLength: 40) }
                VStack(alignment: .leading, spacing: 15) {
                    if !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { RichMessageText(text: message.text, images: message.images ?? [], engine: engine, documents: message.documents ?? []).equatable().textSelection(.enabled) }
                    ForEach((message.images ?? []).filter { $0.inline != true }) { image in ConversationImageView(image: image, engine: engine) }
                    ForEach((message.documents ?? []).filter { !message.text.contains("](suixing-file:" + $0.id + ")") }) { file in ConversationFileView(file: file, engine: engine) }
                }
                    .padding(isUser ? 14 : 0)
                    .background(isUser ? Color(red: 0.935, green: 0.943, blue: 0.998) : .clear, in: RoundedRectangle(cornerRadius: 20))
                    .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
                if !isUser { Spacer(minLength: 0) }
            }
            if !isUser { ForEach(files) { file in TaskFileCard(file: file) } }
            HStack(spacing: 18) {
                if isUser { Spacer() }
                if !isUser {
                    copyButton
                    Button { sharing = true } label: { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("分享回复")
                    if !files.isEmpty { Image(systemName: "externaldrive") }
                    if message.usage?.totalTokens != nil {
                        Button { showingUsage = true } label: { Label((message.isTurnUsage ? "本轮用量 " : "用量 ") + tokenNumber(message.usage?.totalTokens) + " tok", systemImage: "externaldrive").font(.system(size: 10)) }.accessibilityLabel("查看回复的 Token 用量")
                    }
                }
                if isUser { copyButton }
                if !isUser { Spacer() }
            }.font(.system(size: 15)).foregroundStyle(softInk).padding(.horizontal, isUser ? 5 : 0)
        }.padding(isUser ? 0 : 15).background(isUser ? .clear : isProgress ? Color(.secondarySystemBackground).opacity(0.55) : Color(.systemBackground), in: RoundedRectangle(cornerRadius: 17))
            .overlay { if !isUser { RoundedRectangle(cornerRadius: 17).stroke(isProgress ? Color.primary.opacity(0.04) : inkBlue.opacity(0.18), lineWidth: 1) } }
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
            .sheet(isPresented: $sharing) { TextShareSheet(text: message.text) }
            .sheet(isPresented: $showingUsage) { NavigationStack { TokenDetailsView(usage: message.usage, scope: message.isTurnUsage ? "本轮回复合计" : "这条回复") }.presentationDetents([.medium, .large]) }
    }
    private var copyButton: some View {
        Button {
            UIPasteboard.general.string = message.text; copied = true
            Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
        } label: { Image(systemName: copied ? "checkmark" : "square.on.square") }.accessibilityLabel("复制消息")
    }
}

struct TaskFileCard: View {
    @EnvironmentObject private var model: PocketModel
    let file: TaskFile
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Image(systemName: file.icon).font(.system(size: 25)).foregroundStyle(inkBlue)
                if file.icon == "doc.fill" { Text(file.badge).font(.system(size: 6, weight: .bold)).foregroundStyle(.white).offset(y: 4) }
            }.frame(width: 24)
            VStack(alignment: .leading, spacing: 5) {
                Text(file.filename).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(file.displaySize + " · 电脑任务文件").font(.system(size: 10)).foregroundStyle(softInk).lineLimit(1)
            }
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                Button("打开") { Task { await model.previewFile(file.name) } }
                    .font(.system(size: 13)).padding(.horizontal, 12).frame(height: 39)
                hairline.frame(width: 0.5, height: 37)
                Menu {
                    Button { Task { await model.previewFile(file.name) } } label: { Label("预览与分享", systemImage: "doc.text.magnifyingglass") }
                    Button { model.referenceFile(file) } label: { Label("继续追问这个文件", systemImage: "at") }
                    Button { UIPasteboard.general.string = file.name } label: { Label("复制文件名", systemImage: "doc.on.doc") }
                } label: { Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(softInk).frame(width: 28, height: 39) }
            }.foregroundStyle(Color.primary).background(.white, in: RoundedRectangle(cornerRadius: 9))
                .overlay { RoundedRectangle(cornerRadius: 9).stroke(hairline, lineWidth: 0.5) }
        }.padding(.horizontal, 13).padding(.vertical, 12)
            .background(Color(white: 0.975), in: RoundedRectangle(cornerRadius: 15))
            .disabled(model.fileLoading)
    }
}

struct TraceView: View {
    @EnvironmentObject private var model: PocketModel
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if model.conversation.events.isEmpty { Text("执行步骤会显示在这里。").font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 40) }
                ForEach(Array(model.conversation.events.enumerated()), id: \.offset) { _, event in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: event.icon).font(.system(size: 15)).foregroundStyle(inkBlue).frame(width: 20).padding(.top, 2)
                        VStack(alignment: .leading, spacing: 8) {
                            HStack { Text(event.kind.isEmpty ? event.title : event.stepTitle).font(.system(size: 14, weight: .medium)); Spacer(); Text(taskDate(event.time), style: .time).font(.system(size: 10)).foregroundStyle(softInk) }
                            if !event.stepSummary.isEmpty { Text(event.stepSummary).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(8).textSelection(.enabled) }
                            if let detail = event.detail, detail != "{}", !detail.isEmpty {
                                DisclosureGroup("查看详情") { Text(detail).font(.system(size: 11, design: .monospaced)).textSelection(.enabled) }.font(.system(size: 11)).foregroundStyle(softInk)
                            }
                        }
                    }.padding(.vertical, 16)
                    hairline.frame(height: 0.5).padding(.leading, 32)
                }
            }.padding(.horizontal, 20)
        }
    }
}

struct TaskDashboardView: View {
    @EnvironmentObject private var model: PocketModel
    var body: some View {
        List {
            Section("当前工作台 · \(model.engineTitle)") {
                Label(model.conversation.busy ? "任务在电脑执行" : "没有正在执行的任务", systemImage: model.conversation.busy ? "circle.dotted" : "checkmark.circle")
                if model.conversation.busy {
                    Text(model.conversation.messages.last(where: { $0.role == "user" })?.text ?? "正在处理").font(.subheadline).lineLimit(5)
                    TimelineView(.periodic(from: .now, by: 1)) { context in Text("已运行 " + elapsed(model.taskStartedAt, now: context.date)).font(.caption).foregroundStyle(.secondary) }
                    Button("停止任务", role: .destructive) { Task { await model.act("stop") } }.disabled(model.working)
                }
            }
            Section { Text("可以切换工作台或离开手机。已发送的任务继续在电脑执行，回来后同步进度。").font(.subheadline).foregroundStyle(.secondary) }
        }.navigationTitle("后台任务").navigationBarTitleDisplayMode(.inline)
    }
}

struct ControlsSettingsView: View {
    @EnvironmentObject private var model: PocketModel
    let showPermissions: Bool
    @State private var permissionCandidate: EnginePermissionOption?
    var body: some View {
        List {
            Section {
                Label(model.engineTitle, systemImage: model.engineSymbol)
                Text("修改当前电脑会话的设置；正在执行的任务按引擎规则生效。").font(.caption).foregroundStyle(.secondary)
                if model.controlsLoading { ProgressView("正在同步设置…") }
                if let reason = model.conversation.controls?.disabledReason, !reason.isEmpty { Text(reason).font(.caption).foregroundStyle(.secondary) }
            }
            if showPermissions {
                Section("任务权限 · " + model.permissionLabel) {
                    ForEach(model.conversation.controls?.permissions ?? []) { option in
                        Button { permissionCandidate = option } label: {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(option.label).foregroundStyle(.primary)
                                    if let detail = option.description { Text(detail).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                if option.id == model.conversation.controls?.permissionId { Image(systemName: "checkmark").foregroundStyle(inkBlue) }
                            }
                        }.disabled(model.working || model.controlsLoading || model.conversation.controls?.canChangePermissions != true)
                    }
                    if model.conversation.controls?.permissions?.isEmpty != false { Text("当前电脑连接尚未提供可选权限。").font(.subheadline).foregroundStyle(.secondary) }
                }
            } else {
                Section("模型 · " + model.modelLabel) {
                    ForEach(model.conversation.controls?.models ?? []) { option in
                        Button { Task { await model.selectModel(option) } } label: {
                            HStack { Text(option.label).foregroundStyle(.primary); Spacer(); if option.id == model.conversation.controls?.modelId { Image(systemName: "checkmark").foregroundStyle(inkBlue) } }
                        }.disabled(model.working || model.controlsLoading || model.conversation.controls?.canChangeModel != true)
                    }
                    if model.conversation.controls?.models?.isEmpty != false { Text("当前电脑连接尚未提供可选模型。").font(.subheadline).foregroundStyle(.secondary) }
                }
                if !model.reasoningOptions.isEmpty {
                    Section("推理强度") {
                        ForEach(model.reasoningOptions, id: \.self) { effort in
                            Button { Task { await model.updateControls(["reasoningEffort": effort]) } } label: {
                                HStack { Text(effort.capitalized).foregroundStyle(.primary); Spacer(); if effort == model.conversation.controls?.reasoningEffort { Image(systemName: "checkmark").foregroundStyle(inkBlue) } }
                            }.disabled(model.working || model.controlsLoading || model.conversation.controls?.canChangeReasoning != true)
                        }
                    }
                }
            }
            Section("执行位置") { Text(model.conversation.cwd ?? "电脑当前任务目录").font(.caption.monospaced()).textSelection(.enabled) }
        }.navigationTitle(showPermissions ? "任务权限" : "模型与推理强度").navigationBarTitleDisplayMode(.inline)
            .task { await model.loadControls() }
            .alert("更改当前会话权限？", isPresented: Binding(get: { permissionCandidate != nil }, set: { if !$0 { permissionCandidate = nil } })) {
                Button("取消", role: .cancel) { permissionCandidate = nil }
                Button("应用到电脑会话") {
                    if let option = permissionCandidate { Task { await model.updateControls(["permissionId": option.id]) } }
                    permissionCandidate = nil
                }
            } message: {
                Text((permissionCandidate?.label ?? "") + "\n" + (permissionCandidate?.description ?? "修改会同步到电脑上的当前会话。"))
            }
    }
}

struct UsageFooter: View {
    @EnvironmentObject private var model: PocketModel
    let openDetails: () -> Void
    var body: some View {
        HStack(spacing: 0) {
          ScrollView(.horizontal, showsIndicators: false) {
            Button(action: openDetails) {
                HStack(spacing: 14) {
                    Label("\(tokenNumber(model.conversation.usage?.turns)) 轮 \(tokenNumber(model.conversation.usage?.steps)) 步", systemImage: "speedometer")
                    if let speed = model.conversation.usage?.tokensPerSecond { Text(String(format: "%.0f tok/s", speed)) }
                    Label(tokenNumber(model.conversation.usage?.totalTokens) + " tok", systemImage: "externaldrive")
                    Text("缓存 " + usagePercent(model.conversation.usage?.cacheHitPercent))
                    Label(usagePercent(model.conversation.usage?.contextPercent), systemImage: "circle.dotted")
                    Text("余量 " + tokenNumber(model.conversation.usage?.contextRemainingTokens))
                }.font(.system(size: 10)).foregroundStyle(softInk).padding(.horizontal, 14).padding(.vertical, 8).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("查看 Token、速度、缓存和上下文详情")
          }
          Button(action: openDetails) { Image(systemName: "chart.xyaxis.line").font(.system(size: 14)).foregroundStyle(inkBlue).frame(width: 34, height: 34).background(inkBlue.opacity(0.05), in: RoundedRectangle(cornerRadius: 9)) }.accessibilityLabel("打开 Token 实时曲线")
        }.frame(height: 34)
    }
}

struct TokenDetailsView: View {
    @EnvironmentObject private var model: PocketModel
    let usage: TokenUsage?
    let scope: String
    @AppStorage("pocket.tokenOverlay") private var tokenOverlay = true
    var body: some View {
        let usage = scope == "当前会话" ? model.conversation.usage : self.usage
        List {
            Section(scope + " · " + (model.engineTitle)) {
                row("累计用量", tokenNumber(usage?.totalTokens) + " tok")
                row("输入", tokenNumber(usage?.inputTokens))
                row("输出", tokenNumber(usage?.outputTokens))
                row("缓存输入", tokenNumber(usage?.cachedInputTokens))
                row("推理用量", tokenNumber(usage?.reasoningTokens))
                row("最近一轮用量", tokenNumber(usage?.lastTurnTokens))
            }
            Section("运行状态") {
                row("生成速度", usage?.tokensPerSecond.map { String(format: "%.1f tok/s", $0) } ?? "—")
                row("缓存命中", usagePercent(usage?.cacheHitPercent))
                row("上下文占用", usagePercent(usage?.contextPercent))
                row("上下文剩余", tokenNumber(usage?.contextRemainingTokens))
                row("上下文 Token", tokenNumber(usage?.contextTokens) + " / " + tokenNumber(usage?.contextWindow))
                row("轮次 / 步数", tokenNumber(usage?.turns) + " / " + tokenNumber(usage?.steps))
                if let updatedAt = usage?.updatedAt { HStack { Text("数据更新时间"); Spacer(); Text(taskDate(updatedAt), style: .time).foregroundStyle(.secondary) } }
            }
            Section {
                Toggle("显示 Token 悬浮面板", isOn: $tokenOverlay)
                Text("数据来自电脑对应引擎。“—”表示引擎尚未提供；部分统计在生成结束后更新。累计用量不等于当前上下文大小。").font(.caption).foregroundStyle(.secondary)
                if let source = usage?.source { Text("来源：" + source).font(.caption2).foregroundStyle(.secondary) }
            }
        }.navigationTitle("Token 实时用量").navigationBarTitleDisplayMode(.inline)
    }
    private func row(_ name: String, _ value: String) -> some View { HStack { Text(name); Spacer(); Text(value).monospacedDigit().foregroundStyle(.secondary) } }
}

struct PendingQuestionsView: View {
    @EnvironmentObject private var model: PocketModel
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if model.conversation.questions?.isEmpty != false { Label("当前没有待回答的问题", systemImage: "checkmark.circle").foregroundStyle(.secondary).padding(.top, 40) }
                ForEach(model.conversation.questions ?? []) { request in InlineQuestionCard(request: request).id(request.id) }
            }.padding(16)
        }.navigationTitle("选择回复").navigationBarTitleDisplayMode(.inline)
    }
}
struct ReferenceFilesView: View {
    @EnvironmentObject private var model: PocketModel
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    var body: some View {
        List {
            Section { Text("选择电脑上的文件，将文件名加入当前指令。").font(.caption).foregroundStyle(.secondary) }
            ForEach(model.files.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { file in
                Button { model.referenceFile(file); dismiss() } label: {
                    Label { VStack(alignment: .leading, spacing: 4) { Text(file.filename).foregroundStyle(.primary); Text(file.name).font(.caption2).foregroundStyle(.secondary) } } icon: { Image(systemName: file.icon).foregroundStyle(inkBlue) }
                }
            }
        }.searchable(text: $search, prompt: "查找电脑文件").navigationTitle("引用文件").navigationBarTitleDisplayMode(.inline)
            .task { if !model.designPreview { await model.loadFiles() } }
    }
}

struct TextShareSheet: UIViewControllerRepresentable {
    let text: String
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [text], applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct CameraCaptureView: UIViewControllerRepresentable {
    let completion: (UIImage?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController(); picker.sourceType = .camera; picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let completion: (UIImage?) -> Void
        init(completion: @escaping (UIImage?) -> Void) { self.completion = completion }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) { completion(info[.originalImage] as? UIImage) }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { completion(nil) }
    }
}

private func elapsed(_ start: Date, now: Date) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(start)))
    return seconds >= 60 ? "\(seconds / 60)分\(seconds % 60)秒" : "\(seconds)秒"
}



