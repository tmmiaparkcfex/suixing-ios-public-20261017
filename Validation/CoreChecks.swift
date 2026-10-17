import Foundation
import CoreGraphics

@main struct CoreChecks {
    static func main() {
        let link = NotificationDestination.parse(URL(string: "suixing://chat?engine=dsh&id=session_123")!)
        precondition(link?.engine == "dsh" && link?.threadId == "session_123")
        precondition(NotificationDestination.parse(URL(string: "suixing://chat?engine=workbuddy&id=wb-session-123")!)?.engine == "workbuddy")
        precondition(NotificationDestination.parse(URL(string: "https://chat?engine=codex")!) == nil)
        precondition(NotificationDestination.parse(URL(string: "suixing://chat?engine=codex&engine=dsh")!) == nil)
        precondition(NotificationDestination.parse(URL(string: "suixing://chat?engine=other")!) == nil)
        precondition(NotificationDestination.parse(URL(string: "suixing://chat?engine=codex&id=../../file")!) == nil)
        let fixture = "## 准备已就绪\n\n| 项 | 值 |\n|---|---|\n| 操作 | **点击绿框**，再确认 |\n| 路径 | `D:\\codex` |\n\n1. 第一项\n2. 第二项\n  - 子项\n\n> 注意：确认后继续\n\n```swift\nlet example = \"# not a heading\"\n```\n\n结束。"
        let blocks = ContentParser.parse(fixture)
        precondition(blocks.first == .heading(2, "准备已就绪"))
        precondition(blocks.contains(.table([["项", "值"], ["操作", "**点击绿框**，再确认"], ["路径", "`D:\\codex`"]])))
        precondition(blocks.contains(.listItem("1.", "第一项", 0)))
        precondition(blocks.contains(.listItem("•", "子项", 1)))
        precondition(blocks.contains(.quote("注意：确认后继续")))
        precondition(blocks.contains(.code("swift", "let example = \"# not a heading\"")))
        precondition(ContentParser.parse("第一段。\n仍是第一段。\n\n另一段。") == [.paragraph("第一段。\n仍是第一段。"), .paragraph("另一段。")])
        precondition(ContentParser.parse("```txt\n尚在流式生成") == [.code("txt", "尚在流式生成")])
        precondition(ContentParser.cells("| `a|b` | c\\|d |") == ["`a|b`", "c\\|d"])
        precondition(ContentGeometry.remaining(window: 1000, used: 400) == 600)
        precondition(ContentGeometry.remaining(window: 1000, used: 1200) == 0)
        precondition(ContentGeometry.remaining(window: nil, used: 100) == nil)
        let fitted = ContentGeometry.imageRect(in: CGSize(width: 300, height: 300), image: CGSize(width: 400, height: 200))
        precondition(fitted == CGRect(x: 0, y: 75, width: 300, height: 150))
        let crop = ContentGeometry.cropRect(start: CGPoint(x: -10, y: 20), end: CGPoint(x: 200, y: 100), imageBounds: CGRect(x: 0, y: 0, width: 150, height: 150))
        precondition(crop == CGRect(x: 0, y: 20, width: 150, height: 80))
        precondition(ContentGeometry.cropRect(start: .zero, end: CGPoint(x: 2, y: 2), imageBounds: CGRect(x: 0, y: 0, width: 100, height: 100)) == nil)
        print("PASS: markdown structure, table escapes, streamed code, remaining context, image fitting and crop boundaries")
    }
}
