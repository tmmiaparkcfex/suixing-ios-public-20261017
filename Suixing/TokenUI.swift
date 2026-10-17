import SwiftUI
import UIKit
import Charts

private let marketGreen = Color(red: 0.20, green: 0.88, blue: 0.65)
private let marketBackground = Color(red: 0.035, green: 0.052, blue: 0.075)

enum UsageMetric: String, CaseIterable {
    case rate = "消耗速率", total = "累计用量", context = "上下文", cache = "缓存命中"
    var isPercent: Bool { self == .context || self == .cache }
    func value(_ sample: UsageSample) -> Double? {
        switch self { case .rate: return sample.rateTokensPerSecond; case .total: return sample.totalTokens; case .context: return sample.contextPercent; case .cache: return sample.cacheHitPercent }
    }
    var unit: String { isPercent ? "%" : self == .rate ? "tok/s" : "tok" }
}

struct UsageMarketView: View {
    @EnvironmentObject private var model: PocketModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var metric = UsageMetric.rate
    @State private var window: Double = 300
    @State private var selected: UsageSample?
    @AppStorage("pocket.tokenOverlay") private var tokenOverlay = true
    private var usage: TokenUsage? { model.conversation.usage }
    private var latestTime: Double { model.usageHistory.samples.last?.time ?? Date().timeIntervalSince1970 * 1000 }
    private var points: [UsageSample] { model.usageHistory.samples.filter { $0.time >= latestTime - window * 1000 } }
    private var shown: UsageSample? { selected ?? points.last }
    private var domain: ClosedRange<Double> {
        let values = points.compactMap { metric.value($0) }
        guard let maximum = values.max() else { return 0...1 }
        if metric.isPercent { return 0...max(100, maximum) }
        let minimum = metric == .total ? (values.min() ?? 0) : 0
        let padding = max(1, (maximum - minimum) * 0.15)
        return max(0, minimum - padding)...max(minimum + 1, maximum + padding)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 21) {
                headline
                AccountBudgetCard(budget: model.accountBudget, engine: model.engine)
                metricPicker
                chartCard
                rangePicker
                remainingCard
                detailGrid
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("显示悬浮面板", isOn: $tokenOverlay).font(.subheadline).tint(marketGreen)
                    Text("上下文余量与账号余额分别显示。账号积分、金额或五小时额度按对应引擎提供的数据更新，不用 Token 用量推算余额。").font(.caption).foregroundStyle(.secondary).lineSpacing(4)
                    Text("曲线从电脑开始采样后记录；每约 2 秒采样。消耗速率按累计用量差值计算，模型尚未上报时保持真实数值。长按拖动曲线查看采样点。").font(.caption2).foregroundStyle(.secondary).lineSpacing(4)
                }.padding(16).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16))
            }.padding(20)
        }.background(marketBackground).preferredColorScheme(.dark).navigationTitle("Token 实时行情").navigationBarTitleDisplayMode(.inline)
            .onAppear { model.usagePanelVisible = true; Task { await model.loadUsage() } }
            .onDisappear { model.usagePanelVisible = false }
            .onChange(of: model.engine) { _ in selected = nil }
    }
    private var headline: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(model.engineTitle.uppercased()).font(.system(size: 12, weight: .bold, design: .rounded)).tracking(2).foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 5) { Circle().fill(model.connected ? marketGreen : .orange).frame(width: 6, height: 6); Text(model.connected ? "LIVE  实时采样" : "连接中 · 显示上次数据").font(.system(size: 10, weight: .medium)) }.foregroundStyle(model.connected ? marketGreen : .orange)
            }
            Text("当前会话累计用量").font(.caption).foregroundStyle(.secondary)
            AnimatedTokenText(value: usage?.totalTokens, size: 35, color: .white, full: true).frame(height: 43).accessibilityLabel("累计用量 " + tokenNumber(usage?.totalTokens))
            HStack(spacing: 7) {
                Image(systemName: model.conversation.busy ? "waveform.path" : "pause.circle")
                Text(model.conversation.busy ? "电脑正在工作" : "任务空闲 · 保留真实采样")
                Spacer()
                if let time = model.usageHistory.updatedAt { Text(taskDate(time), style: .time).monospacedDigit() }
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
    private var metricPicker: some View {
        HStack(spacing: 4) {
            ForEach(UsageMetric.allCases, id: \.self) { choice in
                Button { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { metric = choice; selected = nil } } label: {
                    Text(choice.rawValue).font(.system(size: 12, weight: metric == choice ? .semibold : .regular)).frame(maxWidth: .infinity).padding(.vertical, 10).background(metric == choice ? marketGreen.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 9)).foregroundStyle(metric == choice ? marketGreen : .secondary)
                }.buttonStyle(.plain)
            }
        }.padding(4).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }
    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(metric.rawValue).font(.caption).foregroundStyle(.secondary)
                Text(metric.isPercent ? usagePercent(shown.flatMap { metric.value($0) }) : tokenNumber(shown.flatMap { metric.value($0) })).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(marketGreen)
                Text(metric.unit).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if let selected { Text(taskDate(selected.time), style: .time).font(.caption2).foregroundStyle(.secondary) }
            }
            if points.isEmpty {
                VStack(spacing: 12) { Image(systemName: "waveform.path.ecg").font(.system(size: 34)).foregroundStyle(marketGreen.opacity(0.7)); Text("开始采样后，真实曲线会出现在这里").font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity).frame(height: 215)
            } else { marketChart.frame(height: 215) }
        }.padding(16).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 18))
    }
    private var marketChart: some View {
        Chart {
            ForEach(points) { sample in
                if let value = metric.value(sample) {
                    AreaMark(x: .value("时间", taskDate(sample.time)), yStart: .value("基线", metric == .total ? domain.lowerBound : 0), yEnd: .value("用量", value), series: .value("采样段", sample.segment ?? 0))
                        .foregroundStyle(LinearGradient(colors: [marketGreen.opacity(0.30), marketGreen.opacity(0.01)], startPoint: .top, endPoint: .bottom)).interpolationMethod(metric == .total ? .stepEnd : .monotone)
                    LineMark(x: .value("时间", taskDate(sample.time)), y: .value("用量", value), series: .value("采样段", sample.segment ?? 0))
                        .foregroundStyle(marketGreen).lineStyle(StrokeStyle(lineWidth: 2.3, lineCap: .round, lineJoin: .round)).interpolationMethod(metric == .total ? .stepEnd : .monotone)
                }
            }
            if let value = shown, let number = metric.value(value) {
                PointMark(x: .value("时间", taskDate(value.time)), y: .value("用量", number)).foregroundStyle(marketGreen).symbolSize(selected == nil ? 22 : 45)
                if selected != nil { RuleMark(x: .value("选择时间", taskDate(value.time))).foregroundStyle(.white.opacity(0.35)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4])) }
            }
        }
        .chartYScale(domain: domain)
        .chartXScale(domain: taskDate(latestTime - window * 1000)...taskDate(latestTime))
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) { value in
            AxisGridLine().foregroundStyle(.white.opacity(0.07))
            AxisValueLabel { if let date = value.as(Date.self) { Text(date, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)).font(.system(size: 9)).foregroundStyle(.secondary) } }
        } }
        .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
            AxisGridLine().foregroundStyle(.white.opacity(0.07))
            AxisValueLabel { if let number = value.as(Double.self) { Text(metric.isPercent ? String(format: "%.0f%%", number) : tokenNumber(number)).font(.system(size: 9)).foregroundStyle(.secondary) } }
        } }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    let frame = geometry[proxy.plotAreaFrame], x = max(0, min(frame.width, value.location.x - frame.minX))
                    if let date: Date = proxy.value(atX: x) { let time = date.timeIntervalSince1970 * 1000; selected = points.min(by: { abs($0.time - time) < abs($1.time - time) }) }
                }.onEnded { _ in selected = nil })
            }
        }
        .animation(reduceMotion ? nil : .linear(duration: 0.35), value: model.usageHistory.samples.last?.time)
    }
    private var rangePicker: some View {
        HStack(spacing: 10) {
            ForEach([60.0, 300, 900, 3600], id: \.self) { seconds in
                Button { selected = nil; window = seconds } label: { Text(seconds == 3600 ? "1小时" : "\(Int(seconds / 60))分钟").font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 9).background(window == seconds ? .white.opacity(0.10) : .clear, in: Capsule()).foregroundStyle(window == seconds ? .white : .secondary) }.buttonStyle(.plain)
            }
        }
    }
    private var remainingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Label("上下文剩余空间", systemImage: "circle.lefthalf.filled").font(.subheadline.weight(.medium)); Spacer(); Text(usagePercent(usage?.contextRemainingPercent)).font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(marketGreen) }
            if let remaining = usage?.contextRemainingPercent { ProgressView(value: min(1, max(0, remaining / 100))).tint(marketGreen) }
            else { Text("等待引擎提供上下文窗口数据").font(.caption).foregroundStyle(.secondary) }
            HStack { Text(tokenNumber(usage?.contextRemainingTokens) + " tok 可用").font(.system(size: 18, weight: .semibold, design: .rounded)); Spacer(); Text("窗口 " + tokenNumber(usage?.contextWindow)).font(.caption).foregroundStyle(.secondary) }
        }.padding(16).background(marketGreen.opacity(0.07), in: RoundedRectangle(cornerRadius: 17))
    }
    private var detailGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
            stat("输入用量", tokenNumber(usage?.inputTokens)); stat("输出用量", tokenNumber(usage?.outputTokens))
            stat("缓存命中", usagePercent(usage?.cacheHitPercent)); stat("生成速度", usage?.tokensPerSecond.map { String(format: "%.0f tok/s", $0) } ?? "未提供")
            stat("最近一轮", tokenNumber(usage?.lastTurnTokens)); stat("上下文已用", tokenNumber(usage?.contextTokens))
        }
    }
    private func stat(_ name: String, _ value: String) -> some View { VStack(alignment: .leading, spacing: 8) { Text(name).font(.caption).foregroundStyle(.secondary); Text(value).font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit() }.frame(maxWidth: .infinity, alignment: .leading).padding(15).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 13)) }
}

struct AccountBudgetCard: View {
    let budget: AccountBudget?
    let engine: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(budget?.label ?? (engine == "workbuddy" ? "剩余积分" : engine == "dsh" ? "账户余额" : "五小时额度剩余"), systemImage: engine == "workbuddy" ? "bolt.circle" : engine == "dsh" ? "yensign.circle" : "clock.arrow.circlepath").font(.subheadline)
                Spacer()
                if budget?.stale == true { Text("上次数据").font(.caption).foregroundStyle(.orange) }
            }
            BudgetAnimatedText(budget: budget).frame(height: 32).accessibilityIdentifier("account-budget-value")
            if let percent = budget?.remainingPercent { ProgressView(value: min(1, max(0, percent / 100))).tint(marketGreen) }
            if let reset = budget?.resetsAt { HStack { Text("下次重置"); Text(taskDate(reset), format: .dateTime.month().day().hour().minute()) }.font(.caption).foregroundStyle(.secondary) }
            if let message = budget?.message, !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
            if let updated = budget?.updatedAt { HStack { Text("余额采样于"); Text(taskDate(updated), style: .time) }.font(.caption2).foregroundStyle(.secondary) }
        }.padding(16).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct BudgetAnimatedText: UIViewRepresentable {
    let budget: AccountBudget?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeUIView(context: Context) -> RollingTokenLabel { let view = RollingTokenLabel(); view.font = .monospacedDigitSystemFont(ofSize: 26, weight: .semibold); view.textColor = .white; return view }
    func updateUIView(_ view: RollingTokenLabel, context: Context) { view.full = true; view.prefix = budget?.prefix ?? ""; view.suffix = budget?.suffix ?? ""; view.decimals = budget?.decimals ?? 0; view.setValue(budget?.displayValue, animated: !reduceMotion); if budget?.displayValue == nil { view.text = "暂不可用" } }
}

struct AnimatedTokenText: UIViewRepresentable {
    let value: Double?
    var size: CGFloat = 13
    var color: UIColor = .label
    var full = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeUIView(context: Context) -> RollingTokenLabel { let label = RollingTokenLabel(); label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal); return label }
    func updateUIView(_ view: RollingTokenLabel, context: Context) { view.font = .monospacedDigitSystemFont(ofSize: size, weight: .semibold); view.textColor = color; view.full = full; view.setValue(value, animated: !reduceMotion) }
}

final class RollingTokenLabel: UILabel {
    var full = false
    var prefix = "", suffix: String?, decimals = 0
    private var target: Double?, shown: Double = 0, startValue: Double = 0, started: CFTimeInterval = 0
    private var link: CADisplayLink?
    private let formatter: NumberFormatter = { let formatter = NumberFormatter(); formatter.numberStyle = .decimal; formatter.maximumFractionDigits = 0; return formatter }()
    func setValue(_ value: Double?, animated: Bool) {
        if value == nil { text = "—" }
        guard value != target else { if value != nil { render() }; return }
        let hadValue = target != nil; target = value; link?.invalidate(); link = nil
        guard let value else { text = "—"; return }
        if !hadValue || !animated || window == nil { shown = value; render(); return }
        startValue = shown; started = CACurrentMediaTime()
        let display = CADisplayLink(target: self, selector: #selector(step(_:))); display.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60); display.add(to: .main, forMode: .common); link = display
    }
    @objc private func step(_ display: CADisplayLink) {
        let progress = min(1, (CACurrentMediaTime() - started) / 0.42), eased = 1 - pow(1 - progress, 3)
        shown = startValue + ((target ?? 0) - startValue) * eased; render()
        if progress >= 1 { link?.invalidate(); link = nil }
    }
    private func render() { formatter.maximumFractionDigits = decimals; formatter.minimumFractionDigits = decimals; text = prefix + (full ? (formatter.string(from: NSNumber(value: shown)) ?? "—") : tokenNumber(shown)) + (suffix ?? (full ? "" : " tok")) }
    override func didMoveToWindow() { super.didMoveToWindow(); if window == nil { link?.invalidate(); link = nil; if let target { shown = target; render() } } }
    deinit { link?.invalidate() }
}

struct FloatingTokenPanel: View {
    @EnvironmentObject private var model: PocketModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("pocket.tokenOverlay") private var visible = true
    let openDetails: () -> Void
    var body: some View {
        NativeTokenOverlay(usage: model.conversation.usage, budget: model.accountBudget, engine: model.engine, samples: model.usageHistory.samples, busy: model.conversation.busy, connected: model.connected, motion: !reduceMotion,
            openDetails: openDetails, close: { visible = false }, dragging: { model.draggingTokenPanel = $0 })
    }
}

struct NativeTokenOverlay: UIViewRepresentable {
    let usage: TokenUsage?
    let budget: AccountBudget?
    let engine: String
    let samples: [UsageSample]
    let busy: Bool, connected: Bool, motion: Bool
    let openDetails: () -> Void
    let close: () -> Void
    let dragging: (Bool) -> Void
    func makeUIView(context: Context) -> TokenOverlayView { TokenOverlayView() }
    func updateUIView(_ view: TokenOverlayView, context: Context) { view.openDetails = openDetails; view.closePanel = close; view.draggingChanged = dragging; view.update(usage: usage, budget: budget, engine: engine, samples: samples, busy: busy, connected: connected, motion: motion) }
    static func dismantleUIView(_ view: TokenOverlayView, coordinator: ()) { view.stopAnimation() }
}

@MainActor private final class TokenPulseTarget: NSObject {
    weak var owner: TokenOverlayView?
    @objc func step(_ link: CADisplayLink) { owner?.animatePulse(link) }
}

final class TokenOverlayView: UIView, UIGestureRecognizerDelegate {
    var openDetails: (() -> Void)?, closePanel: (() -> Void)?, draggingChanged: ((Bool) -> Void)?
    private let card = UIView(), counter = RollingTokenLabel(), chevron = UIImageView(), detail = UIButton(type: .system), closeButton = UIButton(type: .system)
    private let title = UILabel(), remaining = UILabel(), status = UILabel(), latestChange = UILabel()
    private let budgetTitle = UILabel(), budgetCounter = RollingTokenLabel(), resetLabel = UILabel()
    private var budget: AccountBudget?, engine = ""
    private let wave = CAShapeLayer(), glow = CAShapeLayer(), activityDot = UIView()
    private var expanded = false, panning = false, busy = false, motion = true, connected = true
    private var xFraction = UserDefaults.standard.object(forKey: "pocket.tokenOverlayX") as? Double ?? 0.76
    private var yFraction = UserDefaults.standard.object(forKey: "pocket.tokenOverlayY") as? Double ?? 0.15
    private var origin = CGPoint.zero, pulse: CADisplayLink?, pulseTarget = TokenPulseTarget()
    private var values: [UsageSample] = [], current: TokenUsage?
    private var cardSize: CGSize { expanded ? CGSize(width: 250, height: 246) : CGSize(width: 198, height: 70) }
    override init(frame: CGRect) {
        super.init(frame: frame); backgroundColor = .clear
        card.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.98); card.layer.cornerRadius = 16; card.layer.borderWidth = 0.7; card.layer.borderColor = UIColor.separator.withAlphaComponent(0.35).cgColor
        card.layer.shadowColor = UIColor.black.cgColor; card.layer.shadowOpacity = 0.10; card.layer.shadowRadius = 8; card.layer.shadowOffset = CGSize(width: 0, height: 3); addSubview(card)
        counter.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold); counter.accessibilityIdentifier = "token-total"; counter.isAccessibilityElement = true; card.addSubview(counter)
        title.text = "TOKEN 实时用量"; title.font = .systemFont(ofSize: 9, weight: .semibold); title.textColor = .secondaryLabel; card.addSubview(title)
        chevron.image = UIImage(systemName: "chevron.down"); chevron.tintColor = .secondaryLabel; chevron.contentMode = .scaleAspectFit; card.addSubview(chevron)
        remaining.font = .systemFont(ofSize: 12, weight: .medium); card.addSubview(remaining)
        status.font = .systemFont(ofSize: 10); status.textColor = .secondaryLabel; card.addSubview(status)
        latestChange.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium); latestChange.textColor = .systemBlue; card.addSubview(latestChange)
        budgetTitle.font = .systemFont(ofSize: 10, weight: .medium); budgetTitle.textColor = .secondaryLabel; card.addSubview(budgetTitle)
        budgetCounter.full = true; budgetCounter.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold); budgetCounter.textColor = .systemBlue; budgetCounter.accessibilityIdentifier = "account-overlay-value"; budgetCounter.isAccessibilityElement = true; card.addSubview(budgetCounter)
        resetLabel.font = .systemFont(ofSize: 9); resetLabel.textColor = .secondaryLabel; card.addSubview(resetLabel)
        activityDot.backgroundColor = .systemGreen; activityDot.layer.cornerRadius = 3; card.addSubview(activityDot)
        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal); closeButton.addTarget(self, action: #selector(closePressed), for: .touchUpInside); closeButton.accessibilityLabel = "关闭 Token 面板"; card.addSubview(closeButton)
        detail.setTitle("实时曲线  ↗", for: .normal); detail.titleLabel?.font = .systemFont(ofSize: 11, weight: .medium); detail.addTarget(self, action: #selector(detailsPressed), for: .touchUpInside); card.addSubview(detail)
        wave.fillColor = UIColor.clear.cgColor; wave.strokeColor = UIColor.systemBlue.cgColor; wave.lineWidth = 2; wave.lineCap = .round; wave.lineJoin = .round; card.layer.addSublayer(wave)
        glow.fillColor = UIColor.systemBlue.cgColor; card.layer.addSublayer(glow)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(drag(_:))); card.addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(target: self, action: #selector(toggle)); tap.delegate = self; tap.require(toFail: pan); card.addGestureRecognizer(tap)
        pulseTarget.owner = self
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--token-expanded") { expanded = true }
        #endif
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { card.frame.contains(point) ? super.hitTest(point, with: event) : nil }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var view = touch.view
        while let current = view, current !== card { if current is UIControl { return false }; view = current.superview }
        return true
    }
    override func layoutSubviews() {
        super.layoutSubviews(); guard !panning else { return }
        card.bounds = CGRect(origin: .zero, size: cardSize); card.center = clamped(CGPoint(x: bounds.width * xFraction, y: bounds.height * yFraction))
        card.layer.shadowPath = UIBezierPath(roundedRect: card.bounds, cornerRadius: 16).cgPath
        layoutCard()
    }
    private func layoutCard() {
        counter.frame = expanded ? CGRect(x: 14, y: 30, width: 208, height: 28) : CGRect(x: 40, y: 3, width: 140, height: 26)
        counter.font = .monospacedDigitSystemFont(ofSize: expanded ? 20 : 12, weight: .semibold)
        title.frame = CGRect(x: 14, y: 9, width: 182, height: 18); title.isHidden = !expanded
        chevron.frame = expanded ? CGRect(x: 203, y: 13, width: 10, height: 9) : CGRect(x: 182, y: 14, width: 8, height: 7); chevron.transform = expanded ? CGAffineTransform(rotationAngle: .pi) : .identity
        budgetTitle.frame = expanded ? CGRect(x: 14, y: 63, width: 222, height: 17) : CGRect(x: 13, y: 29, width: 172, height: 13)
        budgetCounter.frame = expanded ? CGRect(x: 14, y: 81, width: 222, height: 26) : CGRect(x: 13, y: 43, width: 172, height: 21)
        budgetCounter.font = .monospacedDigitSystemFont(ofSize: expanded ? 21 : 13, weight: .semibold)
        resetLabel.frame = CGRect(x: 14, y: 108, width: 222, height: 17); resetLabel.isHidden = !expanded
        remaining.frame = CGRect(x: 14, y: 133, width: 222, height: 20); remaining.isHidden = !expanded
        latestChange.frame = CGRect(x: 14, y: 158, width: 222, height: 17); latestChange.isHidden = !expanded
        activityDot.frame = CGRect(x: 14, y: 221, width: 6, height: 6)
        status.frame = CGRect(x: 25, y: 214, width: 115, height: 19); status.isHidden = !expanded
        detail.frame = CGRect(x: 145, y: 205, width: 96, height: 34); detail.isHidden = !expanded
        closeButton.frame = CGRect(x: 216, y: 2, width: 32, height: 34); closeButton.isHidden = !expanded
        drawWave()
    }
    func update(usage: TokenUsage?, budget: AccountBudget?, engine: String, samples: [UsageSample], busy: Bool, connected: Bool, motion: Bool) {
        let changedEngine = self.engine != engine
        self.engine = engine; self.budget = budget
        current = usage; values = Array(samples.suffix(36)); self.busy = busy; self.connected = connected; self.motion = motion
        guard !panning else { return }
        counter.setValue(usage?.totalTokens, animated: motion)
        budgetTitle.text = (budget?.label ?? (engine == "workbuddy" ? "剩余积分" : engine == "dsh" ? "账户余额" : "五小时额度剩余")) + (budget?.stale == true ? " · 上次数据" : "")
        if changedEngine { budgetCounter.setValue(nil, animated: false) }
        budgetCounter.prefix = budget?.prefix ?? ""; budgetCounter.suffix = budget?.suffix ?? ""; budgetCounter.decimals = budget?.decimals ?? 0
        budgetCounter.setValue(budget?.displayValue, animated: motion && !changedEngine)
        if budget?.displayValue == nil { budgetCounter.text = "暂不可用" }
        if let reset = budget?.resetsAt { resetLabel.text = "下次重置 " + taskDate(reset).formatted(date: .abbreviated, time: .shortened) }
        else { resetLabel.text = budget?.message ?? "读取对应 AI 的真实账户数据" }
        remaining.text = "上下文剩余  " + tokenNumber(usage?.contextRemainingTokens) + " tok · " + usagePercent(usage?.contextRemainingPercent)
        let delta: Double? = values.count >= 2 ? max(0, values.last!.totalTokens - values[values.count - 2].totalTokens) : nil
        latestChange.text = delta.map { "最近采样 +" + tokenNumber($0) + " tok" } ?? "正在采集真实用量"
        status.text = !connected ? "连接中" : busy ? "电脑正在工作" : "空闲 · 已同步"
        activityDot.backgroundColor = !connected ? .systemOrange : busy ? .systemGreen : .systemGray
        drawWave(); configurePulse()
    }
    private func drawWave() {
        let rect = expanded ? CGRect(x: 15, y: 180, width: 219, height: 22) : CGRect(x: 12, y: 7, width: 20, height: 18)
        let numbers = values.map { $0.rateTokensPerSecond ?? 0 }, maximum = max(1, numbers.max() ?? 1)
        let path = UIBezierPath(); var last = CGPoint(x: rect.maxX, y: rect.maxY)
        if numbers.count > 1 { for (index, number) in numbers.enumerated() { let point = CGPoint(x: rect.minX + rect.width * CGFloat(index) / CGFloat(numbers.count - 1), y: rect.maxY - rect.height * CGFloat(number / maximum)); index == 0 ? path.move(to: point) : path.addLine(to: point); last = point } }
        else { path.move(to: CGPoint(x: rect.minX, y: rect.midY)); path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY)); last.y = rect.midY }
        CATransaction.begin(); CATransaction.setDisableActions(true); wave.path = path.cgPath; wave.opacity = expanded ? 1 : 0.7
        glow.path = UIBezierPath(ovalIn: CGRect(x: last.x - 2.5, y: last.y - 2.5, width: 5, height: 5)).cgPath; CATransaction.commit()
        activityDot.isHidden = !expanded
    }
    private func clamped(_ point: CGPoint) -> CGPoint { CGPoint(x: max(cardSize.width / 2 + 6, min(point.x, bounds.width - cardSize.width / 2 - 6)), y: max(cardSize.height / 2 + 6, min(point.y, bounds.height - cardSize.height / 2 - 6))) }
    @objc private func drag(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began { panning = true; origin = card.center; draggingChanged?(true); stopAnimation() }
        if gesture.state == .changed { let delta = gesture.translation(in: self); card.center = clamped(CGPoint(x: origin.x + delta.x, y: origin.y + delta.y)) }
        if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
            panning = false; xFraction = card.center.x / max(1, bounds.width); yFraction = card.center.y / max(1, bounds.height)
            UserDefaults.standard.set(xFraction, forKey: "pocket.tokenOverlayX"); UserDefaults.standard.set(yFraction, forKey: "pocket.tokenOverlayY"); draggingChanged?(false)
            update(usage: current, budget: budget, engine: engine, samples: values, busy: busy, connected: connected, motion: motion)
        }
    }
    @objc private func toggle(_ gesture: UITapGestureRecognizer) {
        if expanded && gesture.location(in: card).y > 55 { return }
        expanded.toggle(); let changes = { self.setNeedsLayout(); self.layoutIfNeeded() }
        motion ? UIView.animate(withDuration: 0.24, delay: 0, usingSpringWithDamping: 0.88, initialSpringVelocity: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: changes) : changes()
    }
    @objc private func closePressed() { stopAnimation(); closePanel?() }
    @objc private func detailsPressed() { openDetails?() }
    override func didMoveToWindow() { super.didMoveToWindow(); configurePulse() }
    private func configurePulse() {
        guard window != nil, busy, motion, !panning else { stopAnimation(); return }
        if pulse == nil { let link = CADisplayLink(target: pulseTarget, selector: #selector(TokenPulseTarget.step(_:))); link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60); link.add(to: .main, forMode: .common); pulse = link }
    }
    func animatePulse(_ link: CADisplayLink) { let alpha = Float(0.65 + 0.35 * sin(link.timestamp * 4)); CATransaction.begin(); CATransaction.setDisableActions(true); glow.opacity = alpha; activityDot.alpha = CGFloat(alpha); CATransaction.commit() }
    func stopAnimation() { pulse?.invalidate(); pulse = nil; glow.opacity = 1; activityDot.alpha = 1 }
    deinit { pulse?.invalidate() }
}
