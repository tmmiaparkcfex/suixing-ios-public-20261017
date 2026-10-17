import SwiftUI
import UIKit
import QuickLook

@main struct SuixingApp: App {
    @StateObject private var model = PocketModel()
    var body: some Scene { WindowGroup { RootView().environmentObject(model) } }
}

private let accent = Color(red: 0.31, green: 0.44, blue: 0.91)
private let surface = Color(red: 0.97, green: 0.98, blue: 1)

struct RootView: View {
    @EnvironmentObject private var model: PocketModel
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        Group {
            if model.loggedIn { WorkspaceView() } else { LoginView() }
        }
        .tint(accent)
        .task { await model.restore() }
        .onOpenURL { url in Task { await model.receiveNotificationLink(url) } }
        .onChange(of: scenePhase) { phase in
            if phase == .active, model.loggedIn { model.beginUpdates() }
            else if phase == .background { model.stopUpdates() }
        }
        .alert("随行", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("知道了") { model.notice = nil }
        } message: { Text(model.notice ?? "") }

    }
}

struct LoginView: View {
    @EnvironmentObject private var model: PocketModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("随").font(.system(size: 32, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 68, height: 68).background(accent, in: RoundedRectangle(cornerRadius: 20))
                Text("工作继续，\n随时随行。 ").font(.system(size: 36, weight: .semibold))
                Text("手机发指令，电脑继续工作。\n连接同一蒲公英组网后即可使用。")
                    .font(.subheadline).foregroundStyle(.secondary).lineSpacing(6)
                VStack(alignment: .leading, spacing: 10) {
                    Text("电脑蒲公英地址").font(.caption).foregroundStyle(.secondary)
                    TextField("http://172.16.3.70:8789", text: $model.server)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                    Text("电脑控制密码").font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                    SecureField("在电脑的手机连接信息文件中查看", text: $model.password)
                        .textContentType(.password).textFieldStyle(.roundedBorder)
                    Button { Task { await model.login() } } label: {
                        HStack { Text("连接我的电脑"); Spacer(); if model.working { ProgressView().tint(.white) } else { Image(systemName: "arrow.up.right") } }
                            .padding(10).frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).disabled(model.working || model.password.isEmpty)
                }
                Divider()
                Label("连接凭证保存在 iPhone 钥匙串", systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(.secondary)
                Text("模型账号继续由电脑端管理。手机退出后，任务仍由电脑执行；电脑需保持开机和联网。")
                    .font(.caption).foregroundStyle(.secondary).lineSpacing(5)
            }.padding(28).padding(.top, 35)
        }.background(surface).scrollDismissesKeyboard(.interactively)
    }
}

struct FilesView: View {
    @EnvironmentObject private var model: PocketModel
    var body: some View {
        List {
            Section { Text("电脑任务目录中的成果可在这里打开，并通过分享菜单保存到手机。").font(.caption).foregroundStyle(.secondary) }
            if model.files.isEmpty { Text("暂时没有文件，下拉刷新。").foregroundStyle(.secondary) }
            ForEach(model.files) { file in
                Button { Task { await model.previewFile(file.name) } } label: {
                    HStack(spacing: 13) {
                        Image(systemName: "doc.text").font(.title2).foregroundStyle(accent)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(file.name).font(.subheadline).foregroundStyle(.primary).lineLimit(2)
                            Text("\(file.displaySize) · \(taskDate(file.modified).formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 5)
                }.disabled(model.fileLoading)
            }
        }.navigationTitle("文件").navigationBarTitleDisplayMode(.inline)
            .refreshable { await model.loadFiles() }.task { await model.loadFiles() }
            .toolbar { if model.fileLoading { ProgressView() } else { Button { Task { await model.loadFiles() } } label: { Image(systemName: "arrow.clockwise") } } }
    }
}

struct HistoryView: View {
    @EnvironmentObject private var model: PocketModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            Section { Text("选择电脑上的同一会话，查看进度或继续追问。").font(.caption).foregroundStyle(.secondary) }
            if model.history.isEmpty { Text("暂时没有可用会话，请在电脑端新建，或下拉重新同步。").foregroundStyle(.secondary) }
            ForEach(model.history) { item in
                Button { Task { await model.openHistory(item.id); if model.notice == nil { dismiss() } } } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.title).font(.subheadline).foregroundStyle(.primary).lineLimit(2)
                        Text(taskDate(item.time), style: .date).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 6)
                }.disabled(model.working)
            }
        }.navigationTitle("电脑会话 · \(model.engineTitle)").navigationBarTitleDisplayMode(.inline)
            .refreshable { await model.loadHistory() }.task { await model.loadHistory() }
    }
}

struct QuickLookView: UIViewControllerRepresentable {
    let url: URL
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController { let controller = QLPreviewController(); controller.dataSource = context.coordinator; return controller }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct FilePreviewSheet: View {
    let url: URL
    @State private var sharing = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            QuickLookView(url: url).navigationTitle(url.lastPathComponent).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) { Button("完成") { dismiss() } }
                    ToolbarItem(placement: .navigationBarTrailing) { Button { sharing = true } label: { Image(systemName: "square.and.arrow.up") } }
                }
                .sheet(isPresented: $sharing) { ShareSheet(url: url) }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: PocketModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("连接的电脑") { Text(model.server).font(.subheadline); Label(model.connected ? "已连接" : "等待重连", systemImage: model.connected ? "checkmark.circle" : "wifi.exclamationmark") }
                Section("提醒") { NavigationLink { NotificationSettingsView() } label: { Label("任务通知 · Bark", systemImage: "bell.badge") } }
                Section("软件") { NavigationLink { AppUpdateView() } label: { Label("软件更新", systemImage: "arrow.down.app") } }
                Section("任务运行") { Text("任务在电脑执行。手机锁屏、退出或网络断开都不会主动取消任务。回来后会同步电脑端进度。"); Text("电脑需保持开机、联网且不休眠。电脑关机或后台服务关闭，会中断正在执行的任务。") }
                Section("数据") { Text("控制凭证使用 iPhone 钥匙串保存；文件和任务记录留在电脑。预览文件会下载到本 App 的临时目录。"); Text("切换 Codex、DSH 或 WorkBuddy 后，可从会话记录中选择电脑上的对话。") }
                Section { Button("退出连接", role: .destructive) { Task { await model.logout(); dismiss() } } }
            }.navigationTitle("连接设置").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("完成") { dismiss() } }
        }
    }
}

struct AppUpdateView: View {
    @EnvironmentObject private var model: PocketModel
    @State private var info: AppUpdateInfo?
    @State private var checking = false
    @State private var opening = false
    @State private var result: String?
    @State private var failed = false
    var body: some View {
        Form {
            Section("当前安装") {
                LabeledContent("随行", value: model.installedAppVersion + "（" + model.installedAppBuild + "）").accessibilityIdentifier("app-installed-version")
                Button { Task { await refresh() } } label: {
                    HStack { Label("检查更新", systemImage: "arrow.clockwise"); Spacer(); if checking { ProgressView() } }
                }.disabled(checking || opening).accessibilityIdentifier("app-update-refresh")
            }
            if let info {
                Section("电脑发布的版本") {
                    if let latest = info.latest {
                        Label(info.available ? "发现新版本 " + latest.version : "当前已是已发布的最新版本", systemImage: info.available ? "arrow.down.circle" : "checkmark.circle").foregroundStyle(info.available ? Color.blue : Color.green)
                        LabeledContent("版本", value: latest.version + "（" + latest.build + "）")
                        LabeledContent("安装包", value: ByteCountFormatter.string(fromByteCount: Int64(latest.size), countStyle: .file))
                        Text(latest.notes).font(.subheadline).lineSpacing(4)
                        Button { Task { await openInstaller() } } label: {
                            HStack { Label("在电脑打开更新助手", systemImage: "desktopcomputer"); Spacer(); if opening { ProgressView() } }
                        }.disabled(checking || opening).accessibilityIdentifier("app-update-open-installer")
                        Text("电脑会选取并核验最新 IPA，打开 iLoader 和安装包所在位置。请在电脑将安装包拖入 iLoader，完成签名覆盖安装。").font(.caption).foregroundStyle(.secondary)
                    } else { Text(info.message).font(.subheadline).foregroundStyle(.secondary) }
                }
                Section("签名与续签") {
                    Text("继续使用原个人 Apple ID 和 iLoader，无需重新配置电脑连接或 Bark。").font(.subheadline)
                    Text("免费个人 Apple ID 的安装签名有效期为 \(info.signing.refreshDays) 天。在线更新会减少查找安装包的步骤，签名与覆盖安装仍需在 iLoader 中完成。").font(.caption).foregroundStyle(.secondary)
                    Text("电脑需保持开机，且手机能通过蒲公英连接。安装时 iLoader 还需能识别 iPhone，例如用数据线连接。不要卸载原来的随行。").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let result { Section { Label(result, systemImage: failed ? "exclamationmark.circle" : "checkmark.circle").font(.subheadline).foregroundColor(failed ? .red : .secondary) } }
        }.navigationTitle("软件更新").navigationBarTitleDisplayMode(.inline).task { await refresh() }
    }
    private func refresh() async {
        guard !checking else { return }
        checking = true; defer { checking = false }
        do { info = try await model.checkAppUpdates(); result = nil; failed = false }
        catch { failed = true; result = error.localizedDescription }
    }
    private func openInstaller() async {
        guard !opening else { return }
        opening = true; defer { opening = false }
        do { try await model.openDesktopUpdateInstaller(); failed = false; result = "电脑更新助手已打开，请在电脑完成签名安装。" }
        catch { failed = true; result = error.localizedDescription }
    }
}

struct NotificationSettingsView: View {
    @EnvironmentObject private var model: PocketModel
    @State private var settings = NotificationSettings()
    @State private var barkURL = ""
    @State private var loading = true
    @State private var saving = false
    @State private var result: String?
    @State private var failed = false
    private func show(_ text: String, error: Bool = false) { result = text; failed = error }
    var body: some View {
        Form {
            Section {
                Label("离开 App，完成也有提醒", systemImage: "bell.badge.fill").font(.headline)
                Text("电脑在后台监测手机发起的任务。手机锁屏、退出随行后，由 Bark 接收苹果推送；请允许 Bark 的声音、锁屏和横幅通知。").font(.subheadline)
                Link("① 安装或打开 Bark", destination: URL(string: "https://apps.apple.com/app/id1403753865")!)
            }
            Section("② 粘贴 Bark 推送地址") {
                SecureField(settings.configured ? "已保存，留空保留原地址" : "https://api.day.app/你的设备Key", text: $barkURL).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                Text("从 Bark 首页复制完整地址。地址只用于通知，保存后不会在此显示。当前支持 Bark 默认服务器 api.day.app。").font(.caption).foregroundStyle(.secondary)
                if settings.configured { Label("电脑已保存通知地址", systemImage: "checkmark.shield").foregroundStyle(.green) }
            }
            Section("③ 选择提醒并保存") {
                Toggle("开启任务通知", isOn: $settings.enabled)
                Toggle("任务完成", isOn: $settings.complete)
                Toggle("任务失败", isOn: $settings.failed)
                Toggle("需要回答或确认权限", isOn: $settings.attention)
                Toggle("通知显示简短任务内容", isOn: $settings.taskPreview)
                Text("显示你交给 AI 的简短任务描述，帮助区分长时间执行的任务；不发送 AI 的完整回复。可关闭此项，只显示任务状态。").font(.caption).foregroundStyle(.secondary)
                Button("保存通知设置") {
                    Task { saving = true; defer { saving = false }; do { settings = try await model.saveNotifications(settings, barkURL: barkURL); barkURL = ""; show("已保存。通知设置适用于 Codex、DSH 和 WorkBuddy。") } catch { show(error.localizedDescription, error: true) } }
                }.disabled(saving || loading)
                Button("发送测试通知") {
                    Task { saving = true; defer { saving = false }; do { try await model.testNotifications(); show("Bark 已接受测试推送，请查看手机通知。未看到时，检查 Bark 通知权限和专注模式。") } catch { show(error.localizedDescription, error: true) } }
                }.disabled(saving || loading || !settings.enabled || !settings.configured || !barkURL.isEmpty)
                if saving || loading { ProgressView() }
                if let result { Text(result).font(.subheadline).foregroundStyle(failed ? Color.red : Color.blue) }
            }
            Section("通知状态") {
                LabeledContent("后台监测任务", value: String(settings.pendingTasks))
                LabeledContent("等待发送通知", value: String(settings.pendingNotifications))
                if let delivery = settings.lastDelivery { Label(delivery.success ? "最近通知已提交至 Bark" : "最近通知发送失败，请测试通道", systemImage: delivery.success ? "checkmark.circle" : "exclamationmark.triangle"); Text(taskDate(delivery.time), style: .time).font(.caption).foregroundStyle(.secondary) }
                Text("按开关发送简短任务描述，不发送完整聊天、图片或文件；疑似凭证与长链接会尽量遮盖。点通知可通过 Bark 打开随行，并定位原会话。电脑必须开机联网，通知可能受网络、手机通知设置或专注模式影响。").font(.caption).foregroundStyle(.secondary)
            }
            if settings.configured { Section { Button("移除通知地址并关闭提醒", role: .destructive) { Task { saving = true; defer { saving = false }; do { settings = try await model.saveNotifications(settings, barkURL: "", remove: true); barkURL = ""; show("通知地址已移除。") } catch { show(error.localizedDescription, error: true) } } }.disabled(saving) } }
        }.navigationTitle("任务通知").navigationBarTitleDisplayMode(.inline)
            .task { do { settings = try await model.loadNotifications() } catch { show(error.localizedDescription, error: true) }; loading = false }
    }
}


