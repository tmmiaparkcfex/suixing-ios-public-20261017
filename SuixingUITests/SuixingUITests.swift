import XCTest
import CoreGraphics
import Vision

@MainActor final class SuixingUITests: XCTestCase {
    private func launch(_ extras: [String] = []) -> XCUIApplication {
        let app = XCUIApplication(); app.launchArguments = ["--design-preview", "--engine", "codex", "--reset-overlay-position"] + extras; app.launch(); return app
    }

    func testKeyboardSendSubmitsWhileComputerWorks() {
        let app = XCUIApplication(); app.launchArguments = ["--network-fixture", "--busy-fixture"]; app.launch()
        XCTAssertTrue(app.staticTexts["Codex-A 会话内容"].waitForExistence(timeout: 10))
        let input = app.descendants(matching: .any)["composer-text"]; input.tap(); input.typeText("One tap keyboard message")
        XCTAssertTrue(app.buttons["发送指令"].exists)
        let send = app.keyboards.buttons["Send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5)); send.tap()
        XCTAssertTrue(app.tables["transcript-table"].staticTexts["One tap keyboard message"].waitForExistence(timeout: 10))
        XCTAssertFalse((input.value as? String ?? "").contains("One tap keyboard message"))
    }
    func testRoundSendDoesNotStopTaskBeforeSending() {
        let app = XCUIApplication(); app.launchArguments = ["--network-fixture", "--busy-fixture"]; app.launch()
        XCTAssertTrue(app.staticTexts["Codex-A 会话内容"].waitForExistence(timeout: 10))
        let input = app.descendants(matching: .any)["composer-text"]; input.tap(); input.typeText("One tap working message")
        app.buttons["发送指令"].tap()
        XCTAssertTrue(app.tables["transcript-table"].staticTexts["One tap working message"].waitForExistence(timeout: 10))
    }
    func testQuestionCanCollapseReopenAndSkip() {
        let app = launch(["--show-questions"])
        XCTAssertTrue(app.buttons["关闭问题卡片"].waitForExistence(timeout: 8)); app.buttons["关闭问题卡片"].tap()
        XCTAssertTrue(app.buttons["展开待回答问题"].exists); app.buttons["展开待回答问题"].tap()
        XCTAssertTrue(app.buttons["跳过当前问题"].exists); app.buttons["跳过当前问题"].tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["question-option-preview-scope-0"]); waitForExpectations(timeout: 5)
    }
    func testLibraryPhotoBodyOpensZoomAndDirectEditor() {
        let app = launch(["--show-attachments", "--photo-library-fixture"])
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let permission = NSPredicate(format: "label CONTAINS[c] 'Full Access' OR label CONTAINS[c] 'All Photos' OR label CONTAINS '所有照片' OR label CONTAINS '完全访问'")
        let allow = system.buttons.matching(permission).firstMatch
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        else if app.buttons.matching(permission).firstMatch.waitForExistence(timeout: 2) { app.buttons.matching(permission).firstMatch.tap() }
        let tray = app.descendants(matching: .any)["attachment-tray"]
        let photo = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "放大预览相册照片")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 15), "Photo fixture state: \(tray.value ?? "missing")")
        let before = XCTAttachment(screenshot: app.screenshot()); before.name = "RecentPhotoLibrary"; before.lifetime = .keepAlways; add(before)
        photo.tap()
        XCTAssertTrue(app.buttons["关闭图片"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["编辑图片"].exists); app.buttons["编辑图片"].tap()
        XCTAssertTrue(app.navigationBars.buttons["使用此图"].waitForExistence(timeout: 8)); app.navigationBars.buttons["使用此图"].tap()
        XCTAssertTrue(app.buttons["取消选择这张照片"].firstMatch.waitForExistence(timeout: 8))
    }
    func testScrollCollapsesTrayAndPreservesDraftAndManualArrow() {
        let app = launch(["--show-reading"])
        let input = app.descendants(matching: .any)["composer-text"]; input.tap(); input.typeText("Unsent draft")
        app.buttons["添加照片和文件"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["attachment-tray"].waitForExistence(timeout: 5))
        app.tables["transcript-table"].swipeDown()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.descendants(matching: .any)["attachment-tray"]); waitForExpectations(timeout: 5)
        XCTAssertEqual(input.value as? String, "Unsent draft")
        XCTAssertTrue(app.buttons["展开输入框"].exists); app.buttons["展开输入框"].tap()
        XCTAssertTrue(app.buttons["收起输入框和键盘"].exists)
    }

    func testTechnicalNamesAreLabeledAndReadable() {
        let app = launch(["--show-names"]), table = app.tables["transcript-table"]
        XCTAssertTrue(table.waitForExistence(timeout: 8))
        table.swipeDown(velocity: .fast); table.swipeDown(velocity: .slow)
        let label = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "〔文件〕README.md")).firstMatch
        XCTAssertTrue(label.waitForExistence(timeout: 8))
        let proof = XCTAttachment(screenshot: app.screenshot()); proof.name = "TechnicalNamesAndHeadings"; proof.lifetime = .keepAlways; add(proof)
    }
    func testMarkdownStructure() {
        let app = launch(["--show-formatting"])
        XCTAssertTrue(app.staticTexts["准备已就绪"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["功能"].exists)
        XCTAssertFalse(app.staticTexts["## 准备已就绪"].exists)
        XCTAssertFalse(app.staticTexts["|---|---|"].exists)
    }
    func testTranscriptDesktopImageLoadsAndOpens() {
        let app = launch(["--show-images"])
        let image = app.buttons["conversation-image-preview-desktop"]
        XCTAssertTrue(image.waitForExistence(timeout: 10))
        let loaded = NSPredicate(format: "label BEGINSWITH %@", "查看图片：")
        expectation(for: loaded, evaluatedWith: image)
        waitForExpectations(timeout: 12)
        XCTAssertTrue(app.staticTexts["图片与文字一起显示"].exists)
        XCTAssertFalse(app.staticTexts["![示意图](suixing-image:preview-desktop)"].exists)
        image.tap()
        XCTAssertTrue(app.buttons["关闭图片"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["完成"].exists)
        let photo = app.scrollViews["photo-zoom-surface"]
        XCTAssertTrue(photo.waitForExistence(timeout: 8))
        photo.doubleTap()
        expectation(for: NSPredicate(format: "value == %@", "zoomed"), evaluatedWith: photo)
        waitForExpectations(timeout: 5)
        app.buttons["关闭图片"].tap()
        let table = app.tables["transcript-table"]
        table.swipeUp()
        XCTAssertTrue(app.buttons["conversation-image-preview-phone"].waitForExistence(timeout: 8))
    }
    func testReadingGroupsProgressAndKeepsFinalAnswerSeparate() {
        let app = launch(["--show-reading"])
        XCTAssertTrue(app.staticTexts["检查结果"].waitForExistence(timeout: 8))
        let progress = app.descendants(matching: .any)["round-progress-disclosure"]
        XCTAssertTrue(progress.exists)
        XCTAssertTrue(app.staticTexts["连接正常，可以继续使用。"].exists)
        XCTAssertFalse(app.staticTexts["## 检查结果"].exists)
        let table = app.tables["transcript-table"]
        table.swipeUp()
        XCTAssertTrue(app.staticTexts["重启后这样连接"].waitForExistence(timeout: 8))
        assertVisibleMessage(table)
    }
    func testConversationPDFAndVideoPreview() {
        let app = launch(["--show-media"])
        let pdf = app.buttons["conversation-file-preview-pdf"]
        XCTAssertTrue(pdf.waitForExistence(timeout: 8)); pdf.tap()
        XCTAssertTrue(app.buttons["完成"].waitForExistence(timeout: 10)); app.buttons["完成"].tap()
        app.buttons["conversation-file-preview-video"].tap()
        let player = app.descendants(matching: .any)["conversation-media-player"]
        XCTAssertTrue(player.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "value == %@", "ready"), evaluatedWith: player)
        waitForExpectations(timeout: 15)
        XCTAssertTrue(app.buttons["下载并在其他 App 打开"].exists)
        app.buttons["完成"].tap()
    }
    func testFloatingPanelFollowsFinger() {
        let app = launch(), counter = app.staticTexts["token-total"]
        XCTAssertTrue(counter.waitForExistence(timeout: 8))
        let before = counter.frame
        let start = counter.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)), end = start.withOffset(CGVector(dx: -75, dy: 140))
        start.press(forDuration: 0.1, thenDragTo: end)
        XCTAssertGreaterThan(counter.frame.midY - before.midY, 80)
        XCTAssertLessThan(counter.frame.midX - before.midX, -25)
    }
    func testFooterOpensLiveMarket() {
        let app = launch(), button = app.buttons["打开 Token 实时曲线"]
        XCTAssertTrue(button.waitForExistence(timeout: 8)); button.tap()
        XCTAssertTrue(app.navigationBars["Token 实时行情"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["上下文剩余空间"].exists)
        app.buttons["累计用量"].tap()
        XCTAssertTrue(app.buttons["1小时"].exists)
    }
    func testPhotoEditorToolsAndSave() {
        let app = launch(["--show-editor"])
        XCTAssertTrue(app.navigationBars["编辑图片"].waitForExistence(timeout: 8))
        app.segmentedControls.buttons["裁剪"].tap()
        app.buttons["应用裁剪"].tap()
        app.buttons["旋转"].tap()
        app.buttons["使用此图"].tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.navigationBars["编辑图片"]); waitForExpectations(timeout: 8)
        XCTAssertTrue(app.buttons["裁剪、旋转或标注图片"].exists)
    }
    func testNotificationSetup() {
        let app = launch(["--show-notifications"])
        XCTAssertTrue(app.navigationBars["任务通知"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.secureTextFields.firstMatch.exists)
        XCTAssertTrue(app.switches["开启任务通知"].exists)
        XCTAssertFalse(app.buttons["发送测试通知"].isEnabled)
    }
    func testSoftwareUpdateEntryExplainsDesktopSigning() {
        let app = launch(["--show-updates"])
        XCTAssertTrue(app.navigationBars["软件更新"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["app-update-refresh"].exists)
        XCTAssertTrue(app.buttons["app-update-open-installer"].waitForExistence(timeout: 5))
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["签名与续签"].exists)
        XCTAssertTrue(app.staticTexts["继续使用原个人 Apple ID 和 iLoader，无需重新配置电脑连接或 Bark。"].exists)
    }
    func testBudgetMatchesSelectedEngine() {
        for engine in ["codex", "dsh", "workbuddy"] {
            let app = XCUIApplication(); app.launchArguments = ["--design-preview", "--engine", engine, "--token-expanded"]; app.launch()
            let balance = app.staticTexts["account-overlay-value"]
            XCTAssertTrue(balance.waitForExistence(timeout: 8))
            XCTAssertTrue(balance.label.contains(engine == "codex" ? "%" : engine == "dsh" ? "¥" : "积分"))
            XCTAssertTrue(app.staticTexts[engine == "codex" ? "五小时额度剩余" : engine == "dsh" ? "账户余额" : "剩余积分"].exists)
            app.terminate()
        }
    }
    func testTypingDoesNotInvalidateLongTranscript() {
        executionTimeAllowance = 180
        let app = XCUIApplication(); app.launchArguments = ["--network-fixture", "--performance-fixture"]; app.launch()
        let table = app.tables["transcript-table"]
        XCTAssertTrue(table.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["reference-99.txt"].firstMatch.waitForExistence(timeout: 20))
        let input = app.descendants(matching: .any)["composer-text"]
        XCTAssertTrue(input.waitForExistence(timeout: 8)); input.tap()
        // Wait for keyboard geometry and the initial file catalog to settle;
        // those legitimate viewport changes are separate from keystrokes.
        Thread.sleep(forTimeInterval: 2)
        let before = viewport(table)
        let text = "Typing stays inside the composer while the computer continues working."
        input.typeText(text)
        XCTAssertEqual(input.value as? String, text)
        let after = viewport(table)
        XCTAssertLessThan((after["receivedInputs"] as? Int ?? 0) - (before["receivedInputs"] as? Int ?? 0), 15, "Typing must not publish every keystroke to the full transcript")
        XCTAssertEqual(after["fileMatchPasses"] as? Int, before["fileMatchPasses"] as? Int, "Typing must not rescan the transcript's file references")
        // Multiline typing changes the viewport height, so UIKit may legitimately
        // recycle visible cells. Check expensive history work and actual pixels,
        // rather than treating normal cell reuse as a full-history rebuild.
        assertVisibleMessage(table)
    }
    func testHoldVoiceReleaseDraftCanBeEditedBeforeManualSend() {
        let app = XCUIApplication(); app.launchArguments = ["--network-fixture", "--voice-fixture"]; app.launch()
        XCTAssertTrue(app.staticTexts["Codex-A 会话内容"].waitForExistence(timeout: 10))
        app.buttons["按住语音输入"].press(forDuration: 0.6)
        let input = app.descendants(matching: .any)["composer-text"]
        XCTAssertTrue(app.staticTexts["已转文字，请检查或修改后再发送。"].waitForExistence(timeout: 10))
        XCTAssertEqual(input.value as? String, "帮我整理截图，完成后提醒我。")
        XCTAssertFalse(app.tables["transcript-table"].staticTexts["帮我整理截图，完成后提醒我。"].exists)
        input.tap(); input.typeText(" Please check first.")
        // The actual edit depends on the caret position chosen by the tap.
        let edited = (input.value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(edited.contains("Please check first."))
        XCTAssertTrue(edited.contains("帮我整理截图"))
        XCTAssertNotEqual(edited, "帮我整理截图，完成后提醒我。")
        XCTAssertFalse(app.tables["transcript-table"].staticTexts[edited].exists)
        app.buttons["发送指令"].tap()
        XCTAssertTrue(app.tables["transcript-table"].staticTexts[edited].waitForExistence(timeout: 8))
        XCTAssertNotEqual(input.value as? String, edited)
    }
    func testVoiceModeReturnsToDraftAndPreservesTypedText() {
        let app = XCUIApplication(); app.launchArguments = ["--network-fixture", "--voice-fixture"]; app.launch()
        XCTAssertTrue(app.staticTexts["Codex-A 会话内容"].waitForExistence(timeout: 10))
        let input = app.descendants(matching: .any)["composer-text"]
        input.tap(); input.typeText("Original draft")
        app.buttons["按住语音输入"].tap()
        XCTAssertTrue(app.buttons["切换到键盘输入"].exists)
        app.buttons["按住语音输入"].press(forDuration: 0.6)
        XCTAssertTrue(app.staticTexts["已转文字，请检查或修改后再发送。"].waitForExistence(timeout: 10))
        XCTAssertEqual(input.value as? String, "Original draft\n帮我整理截图，完成后提醒我。")
        XCTAssertFalse(app.tables["transcript-table"].staticTexts["帮我整理截图，完成后提醒我。"].exists)
    }
    func testHoldVoiceSlideUpCancelsWithoutSending() {
        let app = XCUIApplication(); app.launchArguments = ["--network-fixture", "--voice-fixture"]; app.launch()
        XCTAssertTrue(app.staticTexts["Codex-A 会话内容"].waitForExistence(timeout: 10))
        let start = app.buttons["按住语音输入"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.4, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -140)))
        XCTAssertFalse(app.otherElements["voice-recording-overlay"].exists)
        XCTAssertFalse(app.tables["transcript-table"].staticTexts["帮我整理截图，完成后提醒我。"].exists)
        XCTAssertFalse(app.staticTexts["已转文字，请检查或修改后再发送。"].exists)
        let input = app.descendants(matching: .any)["composer-text"]
        XCTAssertNotEqual(input.value as? String, "帮我整理截图，完成后提醒我。")
    }
    func testAttachmentTrayRaisesComposerAndVoiceKeyboardToggle() {
        let app = launch()
        let plus = app.buttons["添加照片和文件"]
        XCTAssertTrue(plus.waitForExistence(timeout: 8)); let before = plus.frame.midY; plus.tap()
        XCTAssertTrue(app.buttons["拍照"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["拍照"].exists); XCTAssertTrue(app.buttons["文件"].exists)
        XCTAssertLessThan(app.buttons["收起附件面板"].frame.midY, before - 100)
        app.buttons["收起附件面板"].tap()
        app.buttons["按住语音输入"].tap()
        XCTAssertTrue(app.buttons["切换到键盘输入"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["composer-text"].exists)
        app.buttons["切换到键盘输入"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["composer-text"].exists)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    }
    func testCompactModelAndReasoningConfirmOriginalState() {
        let app = XCUIApplication(); app.launchArguments = ["--network-fixture"]; app.launch()
        XCTAssertTrue(app.staticTexts["Codex-A 会话内容"].waitForExistence(timeout: 10))
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "切换模型：")).firstMatch.tap()
        XCTAssertTrue(app.buttons["选择模型：模型 B"].waitForExistence(timeout: 5))
        app.buttons["选择模型：模型 B"].tap()
        XCTAssertTrue(app.staticTexts["0.65×"].exists)
        XCTAssertTrue(app.staticTexts["✓ 电脑已确认"].waitForExistence(timeout: 8))
        app.buttons["关闭模型选择"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "切换模型：模型 B")).firstMatch.exists)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "切换模型：")).firstMatch.tap()
        let high = app.buttons["选择推理等级：high"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: high); waitForExpectations(timeout: 8)
        high.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["选择模型：模型 B"]); waitForExpectations(timeout: 8)
        let selector = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "切换模型：模型 B"))
        XCTAssertTrue(selector.firstMatch.exists)
    }
    func testModelRefusalDoesNotPretendChangeSucceeded() {
        let app = XCUIApplication(); app.launchArguments = ["--network-fixture", "--controls-refusal-fixture"]; app.launch()
        XCTAssertTrue(app.staticTexts["Codex-A 会话内容"].waitForExistence(timeout: 10))
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "切换模型：")).firstMatch.tap()
        app.buttons["选择模型：模型 B"].tap()
        XCTAssertTrue(app.staticTexts["电脑尚未确认设置，请重新同步后再发送。"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["选择模型：模型 B"].exists)
        XCTAssertTrue(app.buttons["选择推理等级：high"].exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "切换模型：模型 A")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts["电脑已确认模型设置。"].exists)
    }
    func testInlineSingleChoiceSendsImmediately() {
        let app = launch(["--show-questions"])
        let option = app.buttons["question-option-preview-scope-0"]
        XCTAssertTrue(option.waitForExistence(timeout: 8)); option.tap()
        XCTAssertFalse(app.navigationBars["选择回复"].exists)
        XCTAssertTrue(app.staticTexts["回复：调整界面布局"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["inline-question-dock"].exists)
    }
    func testSidebarSwitchesDirectly() {
        let app = launch(["--show-sidebar"])
        XCTAssertTrue(app.buttons["sidebar-session-preview-2"].waitForExistence(timeout: 8))
        app.buttons["sidebar-session-preview-2"].tap()
        XCTAssertTrue(app.buttons["recent-session-preview-2"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["关闭会话侧栏"].exists)
        assertVisibleMessage(app.tables["transcript-table"])
    }
    func testMultipleChoiceKeepsOptionsWithCustomText() {
        let app = launch(["--show-multiple-questions"])
        let first = app.buttons["question-option-preview-multi-item-0"]
        XCTAssertTrue(first.waitForExistence(timeout: 8)); first.tap()
        app.buttons["question-option-preview-multi-item-1"].tap()
        app.buttons["自行撰写回复"].tap()
        let field = app.descendants(matching: .any)["question-custom-preview-multi-item"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("add shortcuts")
        app.buttons["发送回答"].tap()
        XCTAssertTrue(app.staticTexts["回复：优化界面、修复同步、add shortcuts"].waitForExistence(timeout: 6))
    }
    func testSidebarRemovalConfirmsAndSynchronizesAllEngines() {
        let app = XCUIApplication(); app.launchArguments = ["--network-fixture"]; app.launch()
        XCTAssertTrue(app.staticTexts["Codex-A 会话内容"].waitForExistence(timeout: 10))
        for engine in ["DSH", "WorkBuddy"] {
            if engine != "Codex" { app.buttons["切换 AI 引擎"].tap(); app.buttons[engine].tap() }
            XCTAssertTrue(app.staticTexts[engine + "-A 会话内容"].waitForExistence(timeout: 8))
            app.buttons["会话记录"].tap()
            let id = engine == "Codex" ? "11111111-1111-4111-8111-111111111111" : engine == "DSH" ? "session-a" : "wb-session-a"
            let row = app.buttons["sidebar-session-" + id], action = engine == "WorkBuddy" ? "删除对话" : "归档对话"
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            // The long-press menu and swipe affordance both require a second,
            // explicit destructive confirmation. Cancel preserves the session.
            row.press(forDuration: 0.7); app.buttons[action].firstMatch.tap()
            app.buttons["取消"].tap(); XCTAssertTrue(row.exists)
            row.swipeLeft(); app.buttons[action].firstMatch.tap()
            let confirm = app.sheets.buttons[action]
            XCTAssertTrue(confirm.waitForExistence(timeout: 4)); confirm.tap()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: row)], timeout: 8), .completed)
            app.buttons["刷新侧栏会话"].tap()
            XCTAssertFalse(row.exists)
            app.buttons["关闭会话侧栏"].tap()
            XCTAssertTrue(app.staticTexts[engine + "-B 会话内容"].waitForExistence(timeout: 8))
            assertVisibleMessage(app.tables["transcript-table"])
        }
    }
    func testBusySessionCannotBeRemoved() {
        let app = launch(["--show-sidebar"])
        let row = app.buttons["sidebar-session-design-preview"]
        XCTAssertTrue(row.waitForExistence(timeout: 8)); row.press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["请先停止此对话的任务"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.buttons["请先停止此对话的任务"].isEnabled)
        XCTAssertFalse(app.buttons["归档对话"].exists)
        XCTAssertFalse(app.buttons["删除对话"].exists)
    }
    func testCodexRemovalExplainsDesktopRequirement() {
        let app = XCUIApplication(); app.launchArguments = ["--network-fixture"]; app.launch()
        XCTAssertTrue(app.staticTexts["Codex-A 会话内容"].waitForExistence(timeout: 10))
        app.buttons["会话记录"].tap()
        let row = app.buttons["sidebar-session-11111111-1111-4111-8111-111111111111"]
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["Codex 归档请在电脑操作"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.buttons["Codex 归档请在电脑操作"].isEnabled)
        XCTAssertFalse(app.buttons["删除对话"].exists)
        XCTAssertFalse(app.buttons["归档对话"].exists)
    }
    private func assertVisibleMessage(_ table: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(table.waitForExistence(timeout: 8), file: file, line: line)
        let probe = viewport(table)
        XCTAssertGreaterThan(probe["visibleMessages"] as? Int ?? 0, 0, "Transcript must render actual visible message views", file: file, line: line)
    }
    private func viewport(_ table: XCUIElement) -> [String: Any] {
        guard let raw = table.value as? String, let data = raw.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return value
    }
    private func assertTranscriptPixels(_ app: XCUIApplication, latest: Bool = false, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(6)
        var recognized = ""
        repeat {
            if let image = app.screenshot().image.cgImage {
                let request = VNRecognizeTextRequest(); request.recognitionLanguages = ["zh-Hans", "en-US"]; request.recognitionLevel = .accurate
                do { try VNImageRequestHandler(cgImage: image).perform([request]); recognized = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ") }
                catch { XCTFail(error.localizedDescription, file: file, line: line); return }
                if recognized.contains("最新回复") || (!latest && (recognized.contains("任务记录") || recognized.contains("段落"))) { return }
            }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        let evidence = XCTAttachment(screenshot: app.screenshot()); evidence.name = "MissingTranscriptPixels"; evidence.lifetime = .keepAlways; add(evidence)
        XCTFail("Actual screenshot must contain transcript text. OCR: " + recognized, file: file, line: line)
    }
    func testLongHistoryScrollAndJumpNeverBlanks() {
        executionTimeAllowance = 240
        let app = launch(["--stress-transcript"]), table = app.tables["transcript-table"]
        XCTAssertTrue(table.waitForExistence(timeout: 10)); assertVisibleMessage(table); assertTranscriptPixels(app, latest: true)
        for index in 0..<8 {
            table.swipeDown(velocity: .fast); assertVisibleMessage(table)
            if index % 2 == 0 { assertTranscriptPixels(app) }
            let latest = app.buttons["回到最新回复"]
            XCTAssertTrue(latest.waitForExistence(timeout: 3)); latest.tap()
            if index % 2 == 0 { assertTranscriptPixels(app, latest: true) }
            assertVisibleMessage(table)
        }
    }
    func testStreamingDoesNotMoveHistoryAnchor() {
        let app = launch(["--stress-transcript", "--streaming-transcript"]), table = app.tables["transcript-table"]
        XCTAssertTrue(table.waitForExistence(timeout: 10)); table.swipeDown(velocity: .slow)
        assertVisibleMessage(table)
        let before = viewport(table)
        Thread.sleep(forTimeInterval: 1.5)
        let after = viewport(table)
        XCTAssertEqual(before["firstID"] as? String, after["firstID"] as? String)
        XCTAssertLessThan(abs((after["firstY"] as? Double ?? 0) - (before["firstY"] as? Double ?? 0)), 24)
        assertTranscriptPixels(app)
        assertVisibleMessage(table)
    }
    func testNetworkEngineAndConversationSwitches() {
        let app = XCUIApplication(); app.launchArguments = ["--network-fixture"]; app.launch()
        let table = app.tables["transcript-table"]
        XCTAssertTrue(app.staticTexts["Codex-A 会话内容"].waitForExistence(timeout: 10))
        for engine in ["DSH", "WorkBuddy", "Codex", "WorkBuddy", "DSH", "Codex"] {
            app.buttons["切换 AI 引擎"].tap(); app.buttons[engine].tap()
            XCTAssertTrue(app.staticTexts[engine + "-A 会话内容"].waitForExistence(timeout: 6))
            assertVisibleMessage(table)
            app.buttons["会话记录"].tap()
            let id = engine == "Codex" ? "22222222-2222-4222-8222-222222222222" : engine == "WorkBuddy" ? "wb-session-b" : "session-b"
            let item = app.buttons["sidebar-session-" + id]
            XCTAssertTrue(item.waitForExistence(timeout: 5)); item.tap()
            XCTAssertTrue(app.staticTexts[engine + "-B 会话内容"].waitForExistence(timeout: 6))
            assertVisibleMessage(table)
            app.buttons["会话记录"].tap()
            let first = engine == "Codex" ? "11111111-1111-4111-8111-111111111111" : engine == "WorkBuddy" ? "wb-session-a" : "session-a"
            app.buttons["sidebar-session-" + first].tap()
            XCTAssertTrue(app.staticTexts[engine + "-A 会话内容"].waitForExistence(timeout: 6))
        }
    }
    func testLargeConversationUsageRefreshDoesNotRebuildHistory() {
        executionTimeAllowance = 300
        let app = XCUIApplication(); app.launchArguments = ["--network-fixture", "--performance-fixture"]; app.launch()
        let table = app.tables["transcript-table"]
        XCTAssertTrue(table.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["reference-99.txt"].firstMatch.waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: 2)
        let before = viewport(table)
        Thread.sleep(forTimeInterval: 4)
        let after = viewport(table)
        XCTAssertGreaterThan(after["receivedInputs"] as? Int ?? 0, before["receivedInputs"] as? Int ?? 0, "Real refresh path must continue updating token state")
        XCTAssertEqual(after["fileMatchPasses"] as? Int, before["fileMatchPasses"] as? Int, "Usage refresh must not rescan historical messages against files")
        XCTAssertLessThanOrEqual((after["configuredCells"] as? Int ?? 0) - (before["configuredCells"] as? Int ?? 0), 2, "Unchanged visible messages must not be reconfigured by token updates")
        for _ in 0..<4 {
            let dragStart = table.coordinate(withNormalizedOffset: CGVector(dx: 0.10, dy: 0.25))
            let dragEnd = table.coordinate(withNormalizedOffset: CGVector(dx: 0.10, dy: 0.85))
            print("SCROLL_BEFORE", viewport(table))
            dragStart.press(forDuration: 0.05, thenDragTo: dragEnd)
            print("SCROLL_AFTER", viewport(table))
            assertVisibleMessage(table)
            let latest = app.buttons["回到最新回复"]; XCTAssertTrue(latest.waitForExistence(timeout: 4)); latest.tap(); assertVisibleMessage(table)
        }
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Large-conversation-after-scroll"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
