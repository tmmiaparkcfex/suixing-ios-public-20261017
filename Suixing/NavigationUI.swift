import SwiftUI

private let navigationBlue = Color(red: 0.25, green: 0.43, blue: 0.87)

struct ModelPickerAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>?
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = nextValue() ?? value }
}
private struct ModelRowPositionKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}

struct CompactModelPicker: View {
    @EnvironmentObject private var model: PocketModel
    let close: () -> Void
    @State private var selectedID: String?
    @State private var rowPositions: [String: CGFloat] = [:]
    private var options: [EngineModelOption] { model.conversation.controls?.models ?? [] }
    private var selected: EngineModelOption? { options.first { $0.id == (selectedID ?? model.conversation.controls?.modelId) } }
    var body: some View {
        GeometryReader { geometry in
            let leftWidth = geometry.size.width * 0.64
            let levels = selected?.reasoningEfforts ?? []
            let rightHeight = min(geometry.size.height - 12, CGFloat(max(1, levels.count)) * 35 + 40)
            HStack(alignment: .top, spacing: 8) {
                VStack(spacing: 0) {
                    HStack { Text("模型").font(.system(size: 13, weight: .semibold)); Spacer(); if model.controlsLoading { ProgressView().controlSize(.small) }; Button(action: close) { Image(systemName: "xmark").font(.system(size: 12)) }.accessibilityLabel("关闭模型选择") }.padding(12)
                    Divider()
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: true) {
                            LazyVStack(spacing: 2) {
                                ForEach(options) { option in
                                    Button {
                                        selectedID = option.id
                                        if option.reasoningEfforts?.isEmpty != false { apply(option, effort: nil) }
                                    } label: {
                                        HStack(spacing: 5) {
                                            VStack(alignment: .leading, spacing: 3) { Text(option.label).font(.system(size: 12, weight: option.id == selected?.id ? .semibold : .regular)).lineLimit(2); if let price = option.billingLabel { Text(price).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary) } }
                                            Spacer(minLength: 0)
                                            if option.id == model.conversation.controls?.modelId { Image(systemName: "checkmark").font(.system(size: 10)).foregroundStyle(.green) }
                                            if option.reasoningEfforts?.isEmpty == false { Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(.secondary) }
                                        }.frame(maxWidth: .infinity, minHeight: 35, alignment: .leading).padding(.horizontal, 9).padding(.vertical, 4).background(option.id == selected?.id ? Color.blue.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 8)).contentShape(Rectangle())
                                    }.buttonStyle(.plain).disabled(model.working || model.controlsLoading || model.conversation.controls?.canChangeModel != true).id(option.id).accessibilityLabel("选择模型：" + option.label)
                                        .background { GeometryReader { row in Color.clear.preference(key: ModelRowPositionKey.self, value: [option.id: row.frame(in: .named("model-options")).minY + 44]) } }
                                }
                            }.padding(5)
                        }.coordinateSpace(name: "model-options").onAppear { if let id = model.conversation.controls?.modelId { proxy.scrollTo(id, anchor: .center) } }
                    }
                    if options.allSatisfy({ $0.billingLabel == nil }) { Text("电脑未提供模型倍率").font(.system(size: 10)).foregroundStyle(.secondary).padding(8) }
                }.frame(width: leftWidth, height: geometry.size.height).background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 13)).overlay { RoundedRectangle(cornerRadius: 13).stroke(Color.primary.opacity(0.09), lineWidth: 1) }
                VStack(spacing: 0) {
                    Text(levels.isEmpty ? "推理档位固定" : "推理等级").font(.system(size: 11, weight: .semibold)).padding(.vertical, 10)
                    Divider()
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(spacing: 2) {
                            ForEach(levels, id: \.self) { level in
                                Button { if let selected { apply(selected, effort: level) } } label: {
                                    HStack(spacing: 3) { VStack(alignment: .leading, spacing: 2) { Text(effortLabel(level)).font(.system(size: 12)); if let rate = selected?.reasoningOptions?.first(where: { $0.id == level })?.billingLabel { Text(rate).font(.system(size: 9)).foregroundStyle(.secondary) } }; Spacer(minLength: 0); if selected?.id == model.conversation.controls?.modelId && level == model.conversation.controls?.reasoningEffort { Image(systemName: "checkmark").font(.system(size: 9)).foregroundStyle(.green) } }.frame(maxWidth: .infinity, minHeight: 31).padding(.horizontal, 8).contentShape(Rectangle())
                                }.buttonStyle(.plain).disabled(model.working || model.controlsLoading).accessibilityLabel("选择推理等级：" + level)
                            }
                        }.padding(.vertical, 4)
                    }
                }.frame(maxWidth: .infinity).frame(height: rightHeight).background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 12)).overlay { RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.09), lineWidth: 1) }
                    .offset(y: min(geometry.size.height - rightHeight, max(0, rowPositions[selected?.id ?? ""] ?? 45)))
            }
        }.shadow(color: .black.opacity(0.13), radius: 14, y: 5).onPreferenceChange(ModelRowPositionKey.self) { rowPositions = $0 }.onAppear { selectedID = model.conversation.controls?.modelId }.accessibilityIdentifier("compact-model-picker")
    }
    private func effortLabel(_ value: String) -> String { ["off": "关闭", "none": "关闭", "low": "低", "medium": "中", "high": "高", "xhigh": "超高", "max": "最大", "ultra": "极高"][value] ?? value }
    private func apply(_ option: EngineModelOption, effort: String?) {
        var patch = ["modelId": option.id]; if let effort { patch["reasoningEffort"] = effort }
        Task {
            await model.updateControls(patch)
            if model.notice == "电脑已确认模型设置。", model.conversation.controls?.modelId == option.id, effort == nil || model.conversation.controls?.reasoningEffort == effort { close() }
        }
    }
}

struct SessionSidebar: View {
    @EnvironmentObject private var model: PocketModel
    let close: () -> Void
    let newSession: () -> Void
    @State private var search = ""
    @State private var project: String?
    @State private var pendingDeletion: HistoryItem?
    @State private var confirmingDeletion = false
    private var items: [HistoryItem] {
        model.history.filter { item in
            (search.isEmpty || item.title.localizedCaseInsensitiveContains(search)) && (project == nil || item.cwd == project)
        }
    }
    private var projects: [String] { Array(Set(model.history.compactMap(\.cwd))).sorted() }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("工作台").font(.title3.weight(.semibold))
                Spacer()
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 15, weight: .medium)).frame(width: 34, height: 34) }.accessibilityLabel("关闭会话侧栏")
            }.padding(.horizontal, 20).padding(.top, 14)
            HStack(spacing: 6) {
                ForEach(PocketEngine.all, id: \.self) { engine in
                    Button { project = nil; model.selectEngine(engine); Task { await model.loadHistory() } } label: {
                        Text(PocketEngine.title(engine)).font(.system(size: 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8).frame(maxWidth: .infinity).padding(.vertical, 11).background(model.engine == engine ? Color.white : .clear, in: RoundedRectangle(cornerRadius: 10)).foregroundStyle(model.engine == engine ? navigationBlue : .secondary)
                    }.buttonStyle(.plain).disabled(model.working).accessibilityLabel("侧栏切换 " + PocketEngine.title(engine))
                }
            }.padding(4).background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 13)).padding(.horizontal, 16).padding(.top, 14)
            HStack(spacing: 8) { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("搜索对话", text: $search).font(.subheadline).autocorrectionDisabled() }.padding(11).background(.white, in: RoundedRectangle(cornerRadius: 10)).padding(.horizontal, 16).padding(.top, 14)
            Button(action: newSession) { Label(model.canCreateSession ? "新对话" : "新对话请在电脑创建", systemImage: "square.and.pencil").font(.system(size: 14)).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 14) }.disabled(!model.canCreateSession || model.working).padding(.horizontal, 22)
            if !projects.isEmpty {
                Menu {
                    Button("全部项目") { project = nil }
                    ForEach(projects, id: \.self) { path in Button((path as NSString).lastPathComponent) { project = path } }
                } label: { HStack { Image(systemName: "folder"); Text(project.map { ($0 as NSString).lastPathComponent } ?? "全部项目").lineLimit(1); Spacer(); Image(systemName: "chevron.down").font(.caption2) }.font(.system(size: 13)).foregroundStyle(.secondary) }.padding(.horizontal, 22).padding(.bottom, 15)
            }
            HStack { Text(project == nil ? "最近" : "项目对话").font(.caption.weight(.medium)).foregroundStyle(.secondary); Spacer(); Button { Task { await model.loadHistory() } } label: { Image(systemName: "arrow.clockwise").font(.caption) }.accessibilityLabel("刷新侧栏会话") }.padding(.horizontal, 22).padding(.bottom, 8)
            List {
                ForEach(items) { item in
                    sessionRow(item)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if model.canDeleteHistory(item) {
                                Button(role: .destructive) { requestDeletion(item) } label: { Label(model.sessionDeleteLabel, systemImage: model.conversation.capabilities?.deleteMode == "archive" ? "archivebox" : "trash") }
                            }
                        }
                        .contextMenu {
                            if model.canDeleteHistory(item) {
                                Button(role: .destructive) { requestDeletion(item) } label: { Label(model.sessionDeleteLabel, systemImage: model.conversation.capabilities?.deleteMode == "archive" ? "archivebox" : "trash") }
                            } else {
                                Text(item.busy == true || (item.id == model.conversation.threadId && model.conversation.busy) ? "请先停止此对话的任务" : model.conversation.capabilities?.deleteDisabledReason ?? "当前无法操作此会话")
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
                        .listRowSeparator(.hidden).listRowBackground(Color.clear)
                }
                if items.isEmpty { Text(search.isEmpty ? "暂无可用会话，下拉或点刷新同步。" : "没有匹配的对话").font(.caption).foregroundStyle(.secondary).listRowBackground(Color.clear).listRowSeparator(.hidden) }
            }.listStyle(.plain).scrollContentBackground(.hidden)
                .refreshable { await model.loadHistory() }.scrollDismissesKeyboard(.interactively)
            Divider()
            HStack(spacing: 7) { Circle().fill(model.connected ? Color.green : .orange).frame(width: 5, height: 5); Text(model.connected ? "电脑已连接" : "等待电脑连接").font(.caption); Spacer(); Text("随行 " + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")).font(.caption2).foregroundStyle(.secondary) }.padding(18)
        }.background(Color(red: 0.97, green: 0.975, blue: 0.985)).task { await model.loadHistory() }.accessibilityIdentifier("session-sidebar")
            .confirmationDialog(model.sessionDeleteLabel + "？", isPresented: $confirmingDeletion, titleVisibility: .visible, presenting: pendingDeletion) { item in
                Button(model.sessionDeleteLabel, role: .destructive) { Task { await model.deleteHistory(item) } }
                Button("取消", role: .cancel) { pendingDeletion = nil }
            } message: { item in
                Text("“" + item.title + "”\n" + (model.conversation.capabilities?.deleteMode == "archive" ? "归档后从电脑和手机的活动列表移除，可在电脑恢复。" : "将同步删除电脑和手机上的这条对话记录，此操作无法撤销。") + "工作文件不受影响，输入框中未发送的内容会保留。")
            }
            .onChange(of: model.engine) { _ in confirmingDeletion = false; pendingDeletion = nil }
    }
    private func requestDeletion(_ item: HistoryItem) { pendingDeletion = item; confirmingDeletion = true }
    private func sessionRow(_ item: HistoryItem) -> some View {
        Button {
            Task { await model.openHistory(item.id); if model.notice == nil { close() } }
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Circle().fill(item.busy == true ? Color.green : Color.clear).frame(width: 5, height: 5).padding(.top, 6)
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title).font(.system(size: 14, weight: item.id == model.conversation.threadId ? .semibold : .regular)).lineLimit(2).multilineTextAlignment(.leading).foregroundStyle(.primary)
                    if let cwd = item.cwd { Text((cwd.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 0)
                if item.id == model.conversation.threadId { Image(systemName: "checkmark").font(.caption).foregroundStyle(navigationBlue) }
            }.padding(.vertical, 12).padding(.horizontal, 12).frame(maxWidth: .infinity, alignment: .leading).background(item.id == model.conversation.threadId ? navigationBlue.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 10)).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(model.working).accessibilityIdentifier("sidebar-session-" + item.id)
    }
}

struct InlineQuestionDock: View {
    @EnvironmentObject private var model: PocketModel
    let requests: [QuestionRequest]
    let showAll: () -> Void
    @State private var contentHeight: CGFloat = 250
    var body: some View {
        VStack(spacing: 5) {
            if requests.count > 1 { HStack { Text("\(requests.count) 个问题待回答").font(.caption).foregroundStyle(.secondary); Spacer(); Button("查看全部", action: showAll).font(.caption) }.padding(.horizontal, 8) }
            if let first = requests.first {
                ScrollView { InlineQuestionCard(request: first, compact: true).id(first.id).background(GeometryReader { geometry in Color.clear.preference(key: QuestionDockHeight.self, value: geometry.size.height) }) }.frame(height: min(320, max(110, contentHeight)))
                    .onPreferenceChange(QuestionDockHeight.self) { height in if height > 0, abs(height - contentHeight) > 1 { contentHeight = height } }
            }
        }.padding(.horizontal, 12).padding(.top, 7).accessibilityIdentifier("inline-question-dock")
    }
}

private struct QuestionDockHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct InlineQuestionCard: View {
    @EnvironmentObject private var model: PocketModel
    let request: QuestionRequest
    var compact = false
    @State private var selected: [String: Set<String>] = [:]
    @State private var freeText: [String: String] = [:]
    @State private var editingText = false
    @State private var expandedQuestion = false
    @State private var submitted = false
    @State private var submitting = false
    @FocusState private var answerFocused: Bool
    private var instantChoice: Bool { request.questions.count == 1 && request.questions.first?.multiSelect != true }
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 16) {
            HStack {
                Label("问题", systemImage: "questionmark.circle").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                if submitted { Label("已提交", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green) }
                else if submitting { ProgressView().controlSize(.small) }
                else if compact { Button { withAnimation(.easeOut(duration: 0.15)) { expandedQuestion.toggle() } } label: { Image(systemName: expandedQuestion ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .medium)).frame(width: 28, height: 22) }.foregroundStyle(.secondary).accessibilityLabel(expandedQuestion ? "收起完整问题" : "展开完整问题") }
            }
            if let reason = request.disabledReason { Text(reason).font(.caption).foregroundStyle(.secondary) }
            ForEach(request.questions) { question in
                VStack(alignment: .leading, spacing: 6) {
                    Text(question.question).font(.system(size: compact ? 13 : 16, weight: .medium)).lineLimit(compact && !expandedQuestion ? 3 : nil).frame(maxWidth: .infinity, alignment: .leading)
                        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { expandedQuestion.toggle() } }
                    ForEach(Array((question.options ?? []).enumerated()), id: \.offset) { index, option in
                        Button {
                            guard !submitting, !submitted, !model.working else { return }
                            if instantChoice { send([question.id: [option.label]]) }
                            else {
                                var values = selected[question.id] ?? []
                                if question.multiSelect == true { if values.contains(option.label) { values.remove(option.label) } else { values.insert(option.label) } }
                                else { values = [option.label]; freeText[question.id] = "" }
                                selected[question.id] = values
                            }
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Text(String(index + 1)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).frame(width: 17, height: 17).background(.white, in: RoundedRectangle(cornerRadius: 4)).overlay { RoundedRectangle(cornerRadius: 4).stroke(Color.black.opacity(0.1)) }
                                VStack(alignment: .leading, spacing: 3) { Text(option.label).foregroundStyle(.primary); if !compact, let detail = option.description { Text(detail).font(.caption).foregroundStyle(.secondary) } }.font(.system(size: compact ? 13 : 15)).frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: selected[question.id]?.contains(option.label) == true ? "checkmark.circle.fill" : instantChoice ? "arrow.right" : "circle").font(.system(size: 11)).foregroundStyle(selected[question.id]?.contains(option.label) == true ? navigationBlue : .secondary).padding(.top, 2)
                            }.padding(.horizontal, 10).padding(.vertical, compact ? 8 : 12).background(Color(.systemGray6).opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).disabled(model.working || submitted || submitting || request.supported == false).accessibilityIdentifier("question-option-\(question.id)-\(index)")
                    }
                    if question.allowFreeText != false, editingText || (question.options ?? []).isEmpty {
                        if question.isSecret == true { SecureField("填写回答", text: binding(question.id)).focused($answerFocused).textFieldStyle(.roundedBorder).accessibilityIdentifier("question-custom-" + question.id) }
                        else { TextField("自行撰写回复", text: binding(question.id), axis: .vertical).focused($answerFocused).font(.system(size: 13)).lineLimit(1...3).textFieldStyle(.roundedBorder).submitLabel(.send).onSubmit { if canSubmit { send(answers) } }.accessibilityIdentifier("question-custom-" + question.id) }
                    }
                }
            }
            if !submitted {
                HStack {
                    if request.questions.contains(where: { $0.allowFreeText != false }) { Button { editingText.toggle(); if !editingText { answerFocused = false } } label: { Label(editingText ? "收起文字回复" : "自行撰写回复", systemImage: "pencil").font(.system(size: 11)) }.foregroundStyle(.secondary) }
                    Spacer()
                    if !instantChoice || editingText || request.questions.allSatisfy({ ($0.options ?? []).isEmpty }) { Button("发送回答") { send(answers) }.font(.system(size: 12, weight: .semibold)).buttonStyle(.borderedProminent).tint(navigationBlue).disabled(!canSubmit || model.working || submitting) }
                }
            }
        }.padding(compact ? 12 : 16).background(.white, in: RoundedRectangle(cornerRadius: compact ? 15 : 18)).overlay { RoundedRectangle(cornerRadius: compact ? 15 : 18).stroke(Color.black.opacity(0.09), lineWidth: 1) }
    }
    private func send(_ values: [String: [String]]) {
        guard !submitting, !submitted else { return }; answerFocused = false; submitting = true
        Task { let accepted = await model.answerQuestion(request.id, answers: values); submitting = false; submitted = accepted }
    }
    private var canSubmit: Bool { request.supported != false && !request.questions.isEmpty && request.questions.allSatisfy { !(answers[$0.id] ?? []).isEmpty } }
    private var answers: [String: [String]] {
        Dictionary(uniqueKeysWithValues: request.questions.map { q in
            var values = (q.options ?? []).map(\.label).filter { selected[q.id]?.contains($0) == true }
            let text = (freeText[q.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { values.append(text) }
            return (q.id, values)
        })
    }
    private func binding(_ id: String) -> Binding<String> { Binding(get: { freeText[id] ?? "" }, set: { freeText[id] = $0; if request.questions.first(where: { $0.id == id })?.multiSelect != true { selected[id] = [] } }) }
}
