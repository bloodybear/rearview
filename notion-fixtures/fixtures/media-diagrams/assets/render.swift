// Deterministic, code-drawn PNG fixtures. Run: swift render.swift <output-directory>
// No generated artwork or third-party image dependency. All Japanese text is authored here.
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".", isDirectory: true)
var labels: [[String: Any]] = []
func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
}
func rect(_ r: NSRect, _ c: UInt32, radius: CGFloat = 0) {
    color(c).setFill()
    NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
}
func text(_ value: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ size: CGFloat = 28, _ hex: UInt32 = 0x1e293b, bold: Bool = false) {
    let font = NSFont(name: bold ? "HiraginoSans-W6" : "HiraginoSans-W3", size: size) ?? .systemFont(ofSize: size)
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byClipping
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color(hex), .paragraphStyle: paragraph]
    let height = size * 1.65
    (value as NSString).draw(in: NSRect(x: x, y: y, width: width, height: height), withAttributes: attributes)
    labels.append(["text": value, "layoutRect": [x, y, width, height]])
}
func line(_ points: [NSPoint], _ hex: UInt32 = 0x64748b, _ width: CGFloat = 4) {
    let path = NSBezierPath(); path.move(to: points[0])
    for p in points.dropFirst() { path.line(to: p) }
    path.lineWidth = width; color(hex).setStroke(); path.stroke()
}
func arrow(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) {
    line([NSPoint(x: x1, y: y1), NSPoint(x: x2, y: y2)])
    let angle = atan2(y2 - y1, x2 - x1)
    line([NSPoint(x: x2 - 16 * cos(angle - .pi / 6), y: y2 - 16 * sin(angle - .pi / 6)), NSPoint(x: x2, y: y2), NSPoint(x: x2 - 16 * cos(angle + .pi / 6), y: y2 - 16 * sin(angle + .pi / 6))])
}
func image(_ name: String, _ width: Int, _ height: Int, _ draw: () -> Void) throws {
    labels = []
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.translateBy(x: 0, y: CGFloat(height)); ctx.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    rect(NSRect(x: 0, y: 0, width: width, height: height), 0xffffff)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
    let metadata: [String: Any] = ["size": [width, height], "origin": "top-left", "note": "Layout rectangles in image pixels, not tight glyph bounds or screen-space AX boxes. Some text is deliberately occluded; see SCENARIOS.md.", "labels": labels]
    try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(name + ".labels.json"))
}
try image("approval-flow", 1400, 720) {
    text("申請から公開までの手順", 54, 26, 1200, 38, bold: true)
    text("確認の完了と、公開の承認は異なります。", 54, 85, 1250, 25)
    let boxes: [(CGFloat, CGFloat, CGFloat, String)] = [(50, 205, 285, "申請を受け付ける"), (410, 205, 300, "資料を確認する"), (800, 205, 240, "承認を待つ"), (1110, 205, 230, "公開する")]
    for (x, y, w, title) in boxes {
        rect(NSRect(x: x, y: y, width: w, height: 105), 0xe0f2fe, radius: 15)
        text(title, x + 15, y + 33, w - 25, 27, bold: true)
    }
    arrow(335, 257, 408, 257); arrow(710, 257, 798, 257); arrow(1040, 257, 1108, 257)
    text("資料あり", 700, 205, 120, 19); text("承認済み", 1030, 205, 140, 19)
    rect(NSRect(x: 410, y: 460, width: 390, height: 110), 0xffedd5, radius: 15)
    text("申請者へ差し戻す", 435, 493, 340, 30, bold: true)
    arrow(560, 310, 560, 457); text("資料が不足", 580, 355, 240, 24)
    line([NSPoint(x: 410, y: 515), NSPoint(x: 192, y: 515), NSPoint(x: 192, y: 313)])
    arrow(192, 515, 192, 313)
    text("修正して再提出", 85, 550, 300, 25)
    text("注意：承認されるまでは公開しないでください。", 54, 640, 1280, 29, 0xb91c1c, bold: true)
}
try image("service-notice", 1120, 760) {
    rect(NSRect(x: 0, y: 0, width: 1120, height: 85), 0x0f172a)
    text("架空サービス｜お知らせ", 38, 20, 1000, 30, 0xffffff, bold: true)
    text("保存しても、まだ公開されません。", 55, 118, 1020, 42, bold: true)
    text("公開する前に、担当者の承認を受けてください。", 55, 195, 1020, 29)
    text("月額 ¥1,280（税込）／受付上限 1,200 件", 55, 260, 1020, 31)
    text("申請番号：JP-2026-1028-001", 55, 322, 1000, 24)
    text("この行の中央は別のパネルで隠れています。公開してはいけません。", 55, 395, 1040, 28)
    rect(NSRect(x: 400, y: 383, width: 360, height: 73), 0xe2e8f0, radius: 8)
    text("確認中のパネル", 420, 400, 320, 27, bold: true)
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(rect: NSRect(x: 55, y: 485, width: 700, height: 52)).addClip()
    text("右端で切れる文章：申請が承認されるまでは公開してはいけません。", 55, 485, 1040, 31)
    NSGraphicsContext.restoreGraphicsState()
    text("小さい注記：途中解約による日割り返金はありません。", 55, 565, 1040, 17, 0x64748b)
    rect(NSRect(x: 755, y: 635, width: 305, height: 75), 0x2563eb, radius: 10)
    text("保存して閉じる", 780, 654, 265, 28, 0xffffff, bold: true)
    text("これは実際に押せるボタンではありません。", 55, 656, 675, 23)
}
try image("comparison-chart", 1320, 790) {
    text("完了件数の比較", 60, 30, 1200, 40, bold: true)
    text("単位：件", 60, 110, 300, 27)
    for (i, value) in [0, 40, 80, 120].enumerated() {
        let y = CGFloat(615 - i * 130)
        line([NSPoint(x: 180, y: y), NSPoint(x: 1230, y: y)], 0xe2e8f0, 2)
        text(String(value), 85, y - 22, 80, 25)
    }
    line([NSPoint(x: 180, y: 170), NSPoint(x: 180, y: 615), NSPoint(x: 1230, y: 615)], 0x334155, 3)
    let bars: [(CGFloat, CGFloat, String, String, UInt32)] = [(300, 260, "変更前", "80 件", 0x3b82f6), (760, 390, "変更後", "120 件", 0x16a34a)]
    for (x, h, title, value, c) in bars {
        rect(NSRect(x: x, y: 615 - h, width: 220, height: h), c, radius: 4)
        text(value, x + 20, 615 - h - 50, 220, 32, bold: true)
        text(title, x + 30, 630, 250, 30)
    }
    text("対象：初回の申請のみ。再申請は含みません。", 60, 700, 1200, 25, 0xb91c1c)
    text("件数が増えたことは、処理時間が長くなったことを意味しません。", 60, 744, 1200, 22)
}
