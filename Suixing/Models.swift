import Foundation

struct VoiceTranscript: Decodable { let text: String; let source: String? }

enum PocketEngine {
    static let all = ["codex", "dsh", "workbuddy"]
    static func title(_ engine: String) -> String { ["codex": "Codex", "dsh": "DSH", "workbuddy": "WorkBuddy"][engine] ?? engine }
    static func symbol(_ engine: String) -> String { ["codex": "command", "dsh": "sparkles", "workbuddy": "briefcase"][engine] ?? "sparkles" }
}

struct AppUpdateInfo: Decodable {
    let available: Bool
    let installed: AppUpdateVersion
    let latest: AppUpdateRelease?
    let signing: AppUpdateSigning
    let message: String
}
struct AppUpdateVersion: Decodable { let version: String; let build: String }
struct AppUpdateRelease: Decodable {
    let version: String
    let build: String
    let publishedAt: String
    let notes: String
    let sha256: String
    let size: Int
    let minOSVersion: String
}
struct AppUpdateSigning: Decodable {
    let requiresSigning: Bool
    let refreshDays: Int
    let automaticInstall: Bool
}

struct AccountBudget: Decodable, Equatable {
    var kind: String
    var label: String
    var status: String
    var remaining: Double?
    var total: Double?
    var used: Double?
    var remainingPercent: Double?
    var windowMinutes: Double?
    var resetsAt: Double?
    var updatedAt: Double?
    var source: String?
    var message: String?
    var currency: String?
    var stale: Bool?
    var displayValue: Double? { kind == "window" ? remainingPercent : remaining }
    var suffix: String { kind == "window" ? "%" : kind == "credits" ? " 积分" : "" }
    var prefix: String { kind == "money" ? (currency == "CNY" ? "¥" : currency == "USD" ? "$" : (currency.map { $0 + " " } ?? "")) : "" }
    var decimals: Int { kind == "money" ? 2 : kind == "credits" ? 1 : 0 }
    var valueText: String { guard let value = displayValue else { return "暂不可用" }; return prefix + String(format: "%.*f", decimals, value) + suffix }
}

struct NotificationSettings: Decodable {
    var enabled = false
    var complete = true
    var failed = true
    var attention = true
    var taskPreview = true
    var configured = false
    var pendingTasks = 0
    var pendingNotifications = 0
    var lastDelivery: NotificationDelivery?
}
struct NotificationDelivery: Decodable { let time: Double; let kind: String; let engine: String; let success: Bool }

struct PendingImage: Identifiable {
    let id = UUID()
    let name: String
    let data: Data
    var uploadedId: String?
}
struct UploadedImage: Decodable {
    let id: String
}

struct Conversation: Decodable {
    var threadId: String?
    var cwd: String?
    var title: String?
    var engine: String?
    var connected: Bool?
    var historyReady: Bool?
    var desktopSync: Bool?
    var capabilities: EngineCapabilities?
    var controls: EngineControls?
    var usage: TokenUsage?
    var questions: [QuestionRequest]?
    var messages: [Message] = []
    var events: [TaskEvent] = []
    var busy = false
    var error: String?
    var activity: String?
    var csrf: String = ""
    var approvals: [Approval] = []
}

struct Message: Decodable, Equatable {
    let role: String
    let text: String
    let time: Double
    var usage: TokenUsage? = nil
    var itemId: String?
    var phase: String?
    var isTurnUsage: Bool { usage?.source?.contains("turn") == true }
}

struct TokenUsage: Decodable, Equatable {
    var totalTokens: Double?
    var inputTokens: Double?
    var outputTokens: Double?
    var cachedInputTokens: Double?
    var reasoningTokens: Double?
    var lastTurnTokens: Double?
    var contextTokens: Double?
    var contextWindow: Double?
    var contextPercent: Double?
    var tokensPerSecond: Double?
    var cacheHitPercent: Double?
    var steps: Double?
    var turns: Double?
    var updatedAt: Double?
    var source: String?
    var contextRemainingTokens: Double? { ContentGeometry.remaining(window: contextWindow, used: contextTokens) }
    var contextRemainingPercent: Double? {
        guard let remaining = contextRemainingTokens, let window = contextWindow else { return nil }
        return remaining / window * 100
    }
}

struct UsageSample: Decodable, Identifiable {
    let time: Double
    let totalTokens: Double
    var rateTokensPerSecond: Double?
    var generationTokensPerSecond: Double?
    var contextPercent: Double?
    var contextRemainingTokens: Double?
    var cacheHitPercent: Double?
    var segment: Int?
    var id: Double { time }
}
struct UsageHistory: Decodable {
    var samples: [UsageSample] = []
    var observedSince: Double?
    var updatedAt: Double?
    var source: String?
}
struct UsageSnapshot: Decodable {
    var threadId: String?
    var usage: TokenUsage?
    var history: UsageHistory
    var connected: Bool
    var busy: Bool
}

struct EngineModelOption: Decodable, Identifiable {
    let id: String
    let label: String
    var reasoningEfforts: [String]?
}
struct EnginePermissionOption: Decodable, Identifiable {
    let id: String
    let label: String
    var description: String?
}
struct EngineControls: Decodable {
    var modelId: String?
    var modelLabel: String?
    var reasoningEffort: String?
    var permissionId: String?
    var permissionLabel: String?
    var models: [EngineModelOption]?
    var permissions: [EnginePermissionOption]?
    var canChangeModel: Bool?
    var canChangePermissions: Bool?
    var canChangeReasoning: Bool?
    var disabledReason: String?
}

struct QuestionRequest: Decodable, Identifiable {
    let id: String
    var title: String?
    var questions: [QuestionItem]
    var supported: Bool?
    var disabledReason: String?
}
struct QuestionItem: Decodable, Identifiable {
    let id: String
    var header: String?
    let question: String
    var options: [QuestionOption]?
    var multiSelect: Bool?
    var allowFreeText: Bool?
    var isSecret: Bool?
}
struct QuestionOption: Decodable {
    let label: String
    var description: String?
}

func tokenNumber(_ value: Double?) -> String {
    guard let value, value.isFinite, value >= 0 else { return "—" }
    if value >= 1_000_000 { return String(format: "%.2fM", value / 1_000_000) }
    if value >= 1_000 { return String(format: "%.1fK", value / 1_000) }
    return String(format: "%.0f", value)
}
func usagePercent(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "—" }
    return String(format: "%.0f%%", value)
}

struct TaskEvent: Decodable {
    let method: String
    let time: Double
    let summary: String
    let detail: String?
    var fields: [String: Any] {
        guard let detail, let data = detail.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return value
    }
    var itemID: String? { fields["id"] as? String }
    var kind: String {
        if let type = fields["type"] as? String { return type }
        if method.localizedCaseInsensitiveContains("reasoning") { return "reasoning" }
        if method.localizedCaseInsensitiveContains("commandExecution") || method == "Bash" || method == "Shell" { return "commandExecution" }
        if method.localizedCaseInsensitiveContains("fileChange") { return "fileChange" }
        if method.hasPrefix("item/") { return String(method.dropFirst(5)) }
        if !method.hasPrefix("turn/") && !method.hasPrefix("approval/") && !method.hasPrefix("console/") { return "toolCall" }
        return ""
    }
    var icon: String {
        switch kind {
        case "commandExecution": return "terminal"
        case "fileChange": return "doc.badge.gearshape"
        case "reasoning": return "sparkle"
        default: return "circle.dotted"
        }
    }
    var stepTitle: String {
        switch kind {
        case "commandExecution": return "命令"
        case "fileChange": return "文件"
        case "reasoning": return "思考摘要"
        case "toolCall", "mcpToolCall": return "工具"
        case "agentMessage": return "回复"
        default: return title
        }
    }
    var stepSummary: String {
        if let command = fields["command"] as? String { return command }
        if kind == "reasoning" { return summary == "reasoning" ? "整理任务与执行步骤" : summary }
        if kind == "fileChange", let changes = fields["changes"] as? [[String: Any]] {
            return changes.compactMap { $0["path"] as? String }.joined(separator: "、")
        }
        return summary
    }
    var title: String {
        switch method {
        case "turn/started": return "开始任务"
        case "turn/completed": return summary == "interrupted" ? "任务已停止" : "任务结束"
        case "item/started": return "正在执行"
        case "item/completed": return "完成步骤"
        case "console/approval": return "等待你的确认"
        case "console/approvalResolved": return "确认已处理"
        case "error": return "执行提示"
        default: return "进度更新"
        }
    }
}

struct EngineCapabilities: Decodable {
    var newSession: Bool?
    var storedChatNeedsDesktopOwner: Bool?
    var deleteSession: Bool?
    var deleteMode: String?
    var deleteDisabledReason: String?
}

struct SessionDeletion: Decodable { let id: String; let operation: String }

struct Approval: Decodable, Identifiable {
    let id: String
    let method: String
    let details: JSONValue
}

indirect enum JSONValue: Codable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    var pretty: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? String(decoding: encoder.encode(self), as: UTF8.self)) ?? ""
    }
}

struct TaskFile: Decodable, Identifiable, Equatable {
    let name: String
    let size: Int64
    let modified: Double
    var id: String { name }
    var displaySize: String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
    var filename: String { (name as NSString).lastPathComponent }
    var fileExtension: String { (name as NSString).pathExtension.lowercased() }
    var badge: String { fileExtension.isEmpty ? "FILE" : String(fileExtension.uppercased().prefix(4)) }
    var icon: String {
        if ["png", "jpg", "jpeg", "webp", "heic"].contains(fileExtension) { return "photo" }
        if ["zip", "gz", "tar"].contains(fileExtension) { return "doc.zipper" }
        return "doc.fill"
    }
}

struct HistoryItem: Decodable, Identifiable {
    let id: String
    let title: String
    let time: Double
    var cwd: String? = nil
    var busy: Bool? = nil
}

struct FileList: Decodable { let files: [TaskFile] }
struct HistoryList: Decodable { let items: [HistoryItem] }
struct DSHLaunch: Decodable { let url: String }
struct PreviewFile: Identifiable { let id = UUID(); let url: URL }

enum PocketError: LocalizedError {
    case message(String), expired
    var errorDescription: String? {
        switch self {
        case .message(let s): return s
        case .expired: return "连接凭证已过期，请重新输入电脑控制密码。"
        }
    }
}

func taskDate(_ milliseconds: Double) -> Date { Date(timeIntervalSince1970: milliseconds / 1000) }
