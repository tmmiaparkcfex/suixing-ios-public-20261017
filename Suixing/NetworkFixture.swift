#if DEBUG && targetEnvironment(simulator)
import Foundation

/// An in-process, deliberately delayed computer for simulator regression only.
/// It never opens a socket, touches real desktop conversations or submits a push.
final class PocketFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var selected = ["codex": "11111111-1111-4111-8111-111111111111", "dsh": "session-a", "workbuddy": "wb-session-a"]
    private static var sequence = 0
    private static var sentText: [String: String] = [:]
    private static var removed: [String: Set<String>] = [:]
    private static var selectedModels: [String: String] = [:]
    private static var selectedEfforts: [String: String] = [:]
    private static let performanceMessages: [[String: Any]] = (0..<100).map { index in
        let paragraph = "这是一段模拟的长对话记录，保留段落和重点，验证手机滑动和后台更新同时出现时的流畅度。"
        let text = "## 第 \(index + 1) 条任务记录\n\n**重点：这是性能验收用的合成内容。**\n\n" + String(repeating: paragraph + "\n\n", count: index == 0 ? 280 : 24) + "\n文件：reference-\(index).txt\n\n| 项目 | 状态 |\n|---|---|\n| 历史 | 完整保留 |\n| 进度 | 独立更新 |"
        return ["role": "assistant", "itemId": "performance-\(index)", "time": 1700000000000 + index * 1000, "text": text]
    }
    private var work: DispatchWorkItem?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "127.0.0.1" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        let engine = components.queryItems?.first(where: { $0.name == "engine" })?.value ?? "codex"
        let route = components.path
        var bodyData = request.httpBody
        if bodyData == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = Data(), buffer = [UInt8](repeating: 0, count: 2048)
            while stream.hasBytesAvailable, bytes.count < 65536 { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; bytes.append(buffer, count: count) }
            bodyData = bytes
        }
        let body = bodyData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        Self.lock.lock()
        if route.hasSuffix("/controls"), !body.isEmpty, !ProcessInfo.processInfo.arguments.contains("--controls-refusal-fixture") {
            if let value = body["modelId"] as? String { Self.selectedModels[engine] = value }
            if let value = body["reasoningEffort"] as? String { Self.selectedEfforts[engine] = value }
        }
        let modelID = Self.selectedModels[engine] ?? engine + "-fixture-a", effort = Self.selectedEfforts[engine] ?? "low"
        if route.hasSuffix("history/open"), let id = body["id"] as? String { Self.selected[engine] = id }
        if route.hasSuffix("history/delete"), let target = body["id"] as? String {
            Self.removed[engine, default: []].insert(target)
            if Self.selected[engine] == target { Self.selected[engine] = engine == "codex" ? "22222222-2222-4222-8222-222222222222" : engine == "dsh" ? "session-b" : "wb-session-b" }
        }
        let id = Self.selected[engine]!
        let removed = Self.removed[engine] ?? []
        if route.hasSuffix("/send"), let text = body["text"] as? String { Self.sentText[engine + ":" + id] = text }
        let sentText = Self.sentText[engine + ":" + id]
        Self.sequence += 1
        let sequence = Self.sequence
        Self.lock.unlock()
        let controls: [String: Any] = ["modelId": modelID, "modelLabel": modelID.hasSuffix("-b") ? "模型 B" : "模型 A", "reasoningEffort": effort, "permissionId": "default", "permissionLabel": "工作区", "confirmed": !ProcessInfo.processInfo.arguments.contains("--controls-refusal-fixture"), "canChangeModel": true, "canChangeReasoning": true, "models": [["id": engine + "-fixture-a", "label": "模型 A", "billingLabel": "0.21×", "reasoningEfforts": ["low", "medium", "high"]], ["id": engine + "-fixture-b", "label": "模型 B", "billingLabel": "0.65×", "reasoningEfforts": ["low", "high"]]], "permissions": []]
        let suffix = id.hasSuffix("222222222222") || id.hasSuffix("session-b") ? "B" : "A"
        let label = PocketEngine.title(engine) + "-" + suffix
        var response: [String: Any] = ["ok": true]
        if route.hasSuffix("/state") {
            response = ["threadId": id, "title": label + " 测试对话", "engine": engine, "cwd": "D:/codex/fixture", "connected": true, "historyReady": true, "csrf": "fixture-csrf", "busy": false, "approvals": [], "questions": [], "events": [],
                "capabilities": ["newSession": true, "deleteSession": engine != "codex", "deleteMode": engine == "workbuddy" ? "delete" : "archive", "deleteDisabledReason": "Codex 归档请在电脑操作"],
                "messages": [["role": "assistant", "itemId": id + "-message", "time": 1700000000000, "text": label + " 会话内容\n\n这是当前会话的真实加载结果标记。"]],
                "controls": controls, "usage": ["totalTokens": 100, "contextTokens": 20, "contextWindow": 1000]]
            if let sentText { var messages = response["messages"] as! [[String: Any]]; messages.append(["role": "user", "itemId": id + "-phone-input", "time": 1700000001000, "text": sentText]); response["messages"] = messages }
        } else if route.hasSuffix("/history") {
            let ids = engine == "codex" ? ["11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222"] : engine == "workbuddy" ? ["wb-session-a", "wb-session-b"] : ["session-a", "session-b"]
            response = ["items": ids.enumerated().filter { !removed.contains($0.element) }.map { index, id in ["id": id, "title": PocketEngine.title(engine) + (index == 0 ? "-A" : "-B") + " 测试对话", "time": 1700000000000, "cwd": "D:/codex/fixture", "busy": false] as [String: Any] }]
        } else if route.hasSuffix("history/delete"), let target = body["id"] as? String {
            response = ["ok": true, "id": target, "operation": engine == "workbuddy" ? "deleted" : "archived"]
        } else if route.hasSuffix("/usage") {
            response = ["threadId": id, "connected": true, "busy": false, "history": ["samples": []], "usage": ["totalTokens": 100]]
        } else if route.hasSuffix("/speech") {
            response = ["text": "帮我整理截图，完成后提醒我。", "source": "仅 DEBUG 模拟器转写流程测试"]
        } else if route.hasSuffix("/account") {
            response = ["kind": engine == "codex" ? "window" : engine == "dsh" ? "money" : "credits", "label": engine == "codex" ? "五小时额度剩余" : engine == "dsh" ? "账户余额" : "剩余积分", "status": "available", "remaining": engine == "workbuddy" ? 1234.5 : 28.36, "remainingPercent": 74, "updatedAt": 1700000000000, "currency": "CNY", "source": "仅 DEBUG 模拟器测试"]
        } else if route.hasSuffix("/files") { response = ["files": []] }
        else if route.hasSuffix("/controls") { response = controls }
        if ProcessInfo.processInfo.arguments.contains("--performance-fixture") {
            if route.hasSuffix("/state") {
                response["messages"] = Self.performanceMessages
                response["usage"] = ["totalTokens": 100000 + sequence, "contextTokens": 20000, "contextWindow": 1000000]
                response["events"] = (0..<200).map { _ in ["method": "item/commandExecution", "time": 1700000000000, "summary": "合成执行记录", "detail": String(repeating: "合成工具输出；", count: 250)] as [String: Any] }
            }
            if route.hasSuffix("/files") { response = ["files": (0..<100).map { ["name": "reference-\($0).txt", "size": 1200, "modified": 1700000000000] as [String: Any] }] }
        }
        let isEvents = route.hasSuffix("/events")
        let data = isEvents ? Data(": fixture\n\n".utf8) : try! JSONSerialization.data(withJSONObject: response)
        let delay = route.hasSuffix("/state") ? (engine == "codex" ? 0.55 : 0.12) : route.hasSuffix("history/open") ? 0.12 : 0.02
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let response = HTTPURLResponse(url: self.request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": isEvents ? "text/event-stream" : "application/json"])!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        work = item; DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: item)
    }
    override func stopLoading() { work?.cancel(); work = nil }
}
#endif
