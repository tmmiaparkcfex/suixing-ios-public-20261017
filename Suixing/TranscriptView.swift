import SwiftUI
import UIKit

/// A native, self-sizing transcript. Message identity never depends on its current text.
/// UIKit owns recycling and scrolling; model snapshots are held while a finger or inertia
/// is moving the list, so streaming cannot invalidate a visible scrolling anchor.
@MainActor
struct NativeTranscriptView: UIViewControllerRepresentable {
    let model: PocketModel
    let conversationKey: String
    let jumpToken: Int
    var initialFollowLatest = true
    var progress: AnyView? = nil
    var progressRevision = ""
    let emptyState: AnyView
    let onFollowingLatest: (Bool) -> Void

    func makeUIViewController(context: Context) -> TranscriptController {
        let controller = TranscriptController()
        controller.receive(self)
        return controller
    }

    func updateUIViewController(_ controller: TranscriptController, context: Context) {
        controller.receive(self)
    }

    static func dismantleUIViewController(_ controller: TranscriptController, coordinator: ()) {
        controller.dispose()
    }
}

private struct TranscriptEntry {
    enum Content {
        case message(Message, [TaskFile])
        case supplementary(AnyView)
    }
    let id: String
    let revision: Int
    let content: Content
}

private struct TranscriptSnapshot {
    let key: String
    let engine: String
    let model: PocketModel
    let entries: [TranscriptEntry]
}

private struct CachedTranscriptMessage {
    let message: Message
    let filesVersion: Int
    let files: [TaskFile]
    let entry: TranscriptEntry
}

private struct TranscriptAnchor {
    let id: String
    /// Offset from the viewport's top to the row's top; can be negative inside a tall row.
    let offset: CGFloat
}

@MainActor
final class TranscriptController: UIViewController, UITableViewDelegate {
    private let table = TranscriptTable(frame: .zero, style: .plain)
    private var source: UITableViewDiffableDataSource<Int, String>!
    private var snapshot: TranscriptSnapshot?
    private var entryMap: [String: TranscriptEntry] = [:]
    private var pending: TranscriptSnapshot?
    private var pendingInput: NativeTranscriptView?
    private var messageCache: [String: CachedTranscriptMessage] = [:]
    private var previousFiles: [TaskFile] = []
    private var filesVersion = 0
    private var fileMatchPasses = 0
    private var configuredCells = 0
    private var receivedInputs = 0
    private var applying = false
    private var disposed = false
    private var generation = 0
    private var jumpToken: Int?
    private var requestedJump = false
    private var following = true
    private var onFollowingLatest: ((Bool) -> Void)?
    private var lastPublishedFollowing: Bool?
    private var anchor: TranscriptAnchor?
    private var heightCache: [String: CGFloat] = [:]
    private var lastWidth: CGFloat = 0
    private var maintenanceScheduled = false

    override func loadView() {
        view = table
        table.backgroundColor = .systemBackground
        table.separatorStyle = .none
        table.allowsSelection = false
        table.alwaysBounceVertical = true
        table.keyboardDismissMode = .interactive
        table.contentInsetAdjustmentBehavior = .never
        table.contentInset = UIEdgeInsets(top: 9, left: 0, bottom: 9, right: 0)
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 160
        table.sectionHeaderTopPadding = 0
        table.delegate = self
        table.accessibilityIdentifier = "transcript-table"
        table.register(UITableViewCell.self, forCellReuseIdentifier: "transcript")
        source = UITableViewDiffableDataSource<Int, String>(tableView: table) { [weak self] table, path, id in
            let cell = table.dequeueReusableCell(withIdentifier: "transcript", for: path)
            guard let self, let entry = self.entryMap[id], let model = self.snapshot?.model else { return cell }
            self.configuredCells += 1
            let content: AnyView
            switch entry.content {
            case .message(let message, let files):
                content = AnyView(MessageBubble(engine: self.snapshot?.engine ?? "codex", message: message, files: files))
                cell.accessibilityIdentifier = "transcript-message-" + id
            case .supplementary(let value):
                content = value
                cell.accessibilityIdentifier = id == "special:progress" ? "transcript-progress" : "transcript-empty"
            }
            let openURL = OpenURLAction { [weak model] url in
                guard let model else { return .discarded }
                let raw = url.relativeString.removingPercentEncoding ?? url.relativeString
                if let file = model.files.first(where: { $0.name == raw || raw.hasSuffix("/" + $0.name) }) {
                    Task { await model.previewFile(file.name) }
                    return .handled
                }
                return url.scheme == "https" || url.scheme == "http" ? .systemAction : .discarded
            }
            cell.contentConfiguration = UIHostingConfiguration {
                content.environmentObject(model).environment(\.openURL, openURL)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }.margins(.horizontal, 14).margins(.vertical, 9)
            cell.backgroundConfiguration = UIBackgroundConfiguration.clear()
            cell.selectionStyle = .none
            return cell
        }
        table.layoutChanged = { [weak self] in self?.scheduleMaintenance() }
    }

    func receive(_ input: NativeTranscriptView) {
        guard !disposed else { return }
        loadViewIfNeeded()
        receivedInputs += 1
        onFollowingLatest = input.onFollowingLatest
        let changedConversation = snapshot?.key != input.conversationKey
        let wantsJump = jumpToken != nil && jumpToken != input.jumpToken
        jumpToken = input.jumpToken
        // Do not scan/hash the history on a gesture's main-thread frames.
        if !changedConversation, interacting, !wantsJump {
            pendingInput = input
            return
        }
        if changedConversation {
            snapshot?.model.interactingWithTranscript = false
            generation += 1
            pending = nil
            pendingInput = nil
            messageCache.removeAll(keepingCapacity: true)
            anchor = nil
            heightCache.removeAll(keepingCapacity: true)
            following = input.initialFollowLatest
            requestedJump = following
            table.setContentOffset(table.contentOffset, animated: false)
            // An in-flight diffable completion is ignored using its generation. Keeping
            // `applying` until that completion prevents overlapping table snapshots.
        }
        if wantsJump {
            following = true
            requestedJump = true
            table.setContentOffset(table.contentOffset, animated: false)
        }
        pending = makeSnapshot(input)
        publishFollowing()
        drain()
    }

    private func makeSnapshot(_ input: NativeTranscriptView) -> TranscriptSnapshot {
        var repetitions: [String: Int] = [:]
        var entries: [TranscriptEntry] = []
        if previousFiles != input.model.files {
            previousFiles = input.model.files
            filesVersion += 1
        }
        var retained = Set<String>()
        for message in input.model.conversation.messages {
            let base: String
            if let itemId = message.itemId, !itemId.isEmpty { base = "item:" + itemId }
            else { base = "time:" + message.role + ":" + String(message.time.bitPattern) }
            let occurrence = repetitions[base, default: 0]
            repetitions[base] = occurrence + 1
            let id = "message:" + input.conversationKey + ":" + base + ":" + String(occurrence)
            retained.insert(id)
            let cached = messageCache[id]
            if let cached, cached.message == message, cached.filesVersion == filesVersion {
                entries.append(cached.entry)
                continue
            }
            let files: [TaskFile]
            if let cached, cached.message.text == message.text, cached.filesVersion == filesVersion {
                files = cached.files
            } else {
                files = input.model.files(for: message)
                fileMatchPasses += 1
            }
            var revision = Hasher()
            revision.combine(message.role)
            revision.combine(message.text)
            revision.combine(message.time)
            revision.combine(message.phase)
            if let images = message.images { for image in images { revision.combine(image.id); revision.combine(image.width); revision.combine(image.height); revision.combine(image.inline); revision.combine(image.remoteURL) } }
            if let usage = message.usage {
                revision.combine(usage.totalTokens); revision.combine(usage.inputTokens)
                revision.combine(usage.outputTokens); revision.combine(usage.cachedInputTokens)
                revision.combine(usage.reasoningTokens); revision.combine(usage.lastTurnTokens)
                revision.combine(usage.contextTokens); revision.combine(usage.contextWindow)
                revision.combine(usage.contextPercent); revision.combine(usage.tokensPerSecond)
                revision.combine(usage.cacheHitPercent); revision.combine(usage.turns)
                revision.combine(usage.steps); revision.combine(usage.updatedAt); revision.combine(usage.source)
            }
            for file in files { revision.combine(file.name); revision.combine(file.size); revision.combine(file.modified) }
            let entry = TranscriptEntry(id: id, revision: revision.finalize(), content: .message(message, files))
            entries.append(entry)
            messageCache[id] = CachedTranscriptMessage(message: message, filesVersion: filesVersion, files: files, entry: entry)
        }
        if messageCache.count != retained.count { messageCache = messageCache.filter { retained.contains($0.key) } }
        if entries.isEmpty {
            entries.append(TranscriptEntry(id: "special:empty", revision: input.conversationKey.hashValue, content: .supplementary(input.emptyState)))
        }
        if let progress = input.progress {
            entries.append(TranscriptEntry(id: "special:progress", revision: input.progressRevision.hashValue, content: .supplementary(progress)))
        }
        return TranscriptSnapshot(key: input.conversationKey, engine: input.model.engine, model: input.model, entries: entries)
    }

    private var interacting: Bool { table.isTracking || table.isDragging || table.isDecelerating }

    private func drain() {
        guard !applying, !interacting, let next = pending, !disposed else { return }
        pending = nil
        let old = snapshot
        let sameConversation = old?.key == next.key
        let preservedAnchor = sameConversation && !following ? (captureAnchor() ?? anchor) : nil
        let oldMap = entryMap
        let ids = next.entries.map(\.id)
        let changed = next.entries.filter { oldMap[$0.id]?.revision != $0.revision }.map(\.id)
        let changedSet = Set(changed)
        let sameStructure = sameConversation && old?.entries.map(\.id) == ids
        if sameStructure && changed.isEmpty {
            snapshot = next
            if requestedJump { scrollToLatest() }
            updateAccessibilityProbe()
            return
        }
        snapshot = next
        entryMap = Dictionary(uniqueKeysWithValues: next.entries.map { ($0.id, $0) })
        for id in changed { heightCache.removeValue(forKey: id) }
        if !sameConversation { heightCache.removeAll(keepingCapacity: true) }
        var update = NSDiffableDataSourceSnapshot<Int, String>()
        update.appendSections([0])
        update.appendItems(ids)
        // Empty/progress rows deliberately retain simple identifiers for accessibility;
        // reconfigure them on an engine switch even if their numeric revision matches.
        update.reconfigureItems(next.entries.filter {
            oldMap[$0.id] != nil && (!sameConversation || changedSet.contains($0.id))
        }.map(\.id))
        applying = true
        let currentGeneration = generation
        UIView.performWithoutAnimation {
            source.apply(update, animatingDifferences: false) { [weak self] in
                guard let self, !self.disposed else { return }
                self.applying = false
                guard self.generation == currentGeneration else { self.drain(); return }
                self.table.layoutIfNeeded()
                if self.following || self.requestedJump { self.scrollToLatest() }
                else if let preservedAnchor { self.restore(preservedAnchor) }
                self.anchor = self.captureAnchor()
                self.updateAccessibilityProbe()
                self.publishFollowing()
                self.drain()
            }
        }
    }

    private func captureAnchor() -> TranscriptAnchor? {
        guard let path = table.indexPathsForVisibleRows?.sorted().first,
              let id = source.itemIdentifier(for: path) else { return nil }
        return TranscriptAnchor(id: id, offset: table.rectForRow(at: path).minY - table.contentOffset.y)
    }

    private func restore(_ anchor: TranscriptAnchor) {
        guard let path = source.indexPath(for: anchor.id) else { return }
        let y = table.rectForRow(at: path).minY - anchor.offset
        setOffset(y)
    }

    private func setOffset(_ y: CGFloat) {
        let lower = -table.adjustedContentInset.top
        let upper = max(lower, table.contentSize.height - table.bounds.height + table.adjustedContentInset.bottom)
        let clamped = min(upper, max(lower, y))
        if abs(table.contentOffset.y - clamped) > 0.5 {
            table.setContentOffset(CGPoint(x: 0, y: clamped), animated: false)
        }
    }

    private func scrollToLatest() {
        guard !interacting, let id = snapshot?.entries.last?.id,
              let path = source.indexPath(for: id), table.bounds.height > 0 else { return }
        requestedJump = false
        table.layoutIfNeeded()
        // A real last row remains materialized; there is no zero-height SwiftUI sentinel.
        if table.indexPathsForVisibleRows?.contains(path) != true { table.scrollToRow(at: path, at: .bottom, animated: false) }
        table.layoutIfNeeded()
        setOffset(table.contentSize.height - table.bounds.height + table.adjustedContentInset.bottom)
        updateAccessibilityProbe()
    }

    private func scheduleMaintenance() {
        guard !maintenanceScheduled, !disposed else { return }
        maintenanceScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.disposed else { return }
            self.maintenanceScheduled = false
            guard !self.interacting, !self.applying else { return }
            if abs(self.lastWidth - self.table.bounds.width) > 0.5 {
                self.lastWidth = self.table.bounds.width
                self.heightCache.removeAll(keepingCapacity: true)
            }
            if self.following { self.scrollToLatest() }
            else if let anchor = self.anchor { self.restore(anchor) }
            self.anchor = self.captureAnchor()
            self.updateAccessibilityProbe()
        }
    }

    private func publishFollowing() {
        guard lastPublishedFollowing != following else { return }
        lastPublishedFollowing = following
        let value = following
        // updateUIViewController cannot mutate its parent SwiftUI state synchronously.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.disposed, self.following == value else { return }
            self.onFollowingLatest?(value)
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        snapshot?.model.interactingWithTranscript = true
        following = false
        requestedJump = false
        anchor = captureAnchor()
        publishFollowing()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard interacting, !applying else { return }
        let bottom = max(-table.adjustedContentInset.top, table.contentSize.height - table.bounds.height + table.adjustedContentInset.bottom)
        following = table.contentOffset.y >= bottom - 2
        anchor = captureAnchor()
        publishFollowing()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { finishInteraction() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { finishInteraction() }

    private func finishInteraction() {
        snapshot?.model.interactingWithTranscript = false
        anchor = captureAnchor()
        if let input = pendingInput { pendingInput = nil; receive(input) }
        drain()
        if following { scrollToLatest() }
        publishFollowing()
        updateAccessibilityProbe()
    }

    private func updateAccessibilityProbe() {
        #if DEBUG && targetEnvironment(simulator)
        let visible = table.visibleCells.filter { cell in
            guard cell.accessibilityIdentifier?.hasPrefix("transcript-message-") == true else { return false }
            let rect = table.convert(cell.bounds, from: cell)
            return rect.intersects(table.bounds) && cell.bounds.height > 2 && !cell.contentView.subviews.isEmpty
        }.sorted { table.convert($0.bounds, from: $0).minY < table.convert($1.bounds, from: $1).minY }
        var value: [String: Any] = ["visibleMessages": visible.count, "following": following, "receivedInputs": receivedInputs, "configuredCells": configuredCells, "fileMatchPasses": fileMatchPasses]
        if let cell = visible.first { if let id = cell.accessibilityIdentifier { value["firstID"] = id }; value["firstY"] = Double(table.convert(cell.bounds, from: cell).minY - table.contentOffset.y) }
        if let data = try? JSONSerialization.data(withJSONObject: value), let text = String(data: data, encoding: .utf8), table.accessibilityValue != text { table.accessibilityValue = text }
        #endif
    }

    func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        guard let id = source.itemIdentifier(for: indexPath) else { return 160 }
        return heightCache[id] ?? 160
    }

    func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if let id = cell.accessibilityIdentifier?.replacingOccurrences(of: "transcript-message-", with: ""), cell.bounds.height > 0 {
            heightCache[id] = cell.bounds.height
        }
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if let id = source.itemIdentifier(for: indexPath), cell.bounds.height > 0 { heightCache[id] = cell.bounds.height }
    }

    func dispose() {
        disposed = true
        pending = nil
        pendingInput = nil
        snapshot?.model.interactingWithTranscript = false
        messageCache.removeAll()
        table.layoutChanged = nil
        table.delegate = nil
        onFollowingLatest = nil
    }
}

@MainActor
private final class TranscriptTable: UITableView {
    var layoutChanged: (() -> Void)?
    private var lastLayoutSize: CGSize = .zero
    private var lastContentSize: CGSize = .zero
    override func layoutSubviews() {
        super.layoutSubviews()
        if abs(bounds.width - lastLayoutSize.width) > 0.5 || abs(bounds.height - lastLayoutSize.height) > 0.5 || abs(contentSize.height - lastContentSize.height) > 0.5 || abs(contentSize.width - lastContentSize.width) > 0.5 {
            lastLayoutSize = bounds.size
            lastContentSize = contentSize
            layoutChanged?()
        }
    }
}
