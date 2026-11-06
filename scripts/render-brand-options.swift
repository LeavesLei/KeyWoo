import AppKit
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "design", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}

func icon(_ variant: Int, in rect: CGRect, canvasHeight: CGFloat, context: CGContext) {
    context.saveGState()
    context.translateBy(x: rect.minX, y: canvasHeight - rect.minY)
    context.scaleBy(x: rect.width / 1024, y: -rect.height / 1024)
    let backgrounds: [UInt32] = [0x244B40, 0xF3EFE5, 0x252842]
    let foregrounds: [UInt32] = [0xF4F0E6, 0x315548, 0xF3B5A6]
    context.setFillColor(color(backgrounds[variant]).cgColor)
    context.addPath(CGPath(roundedRect: CGRect(x: 62, y: 62, width: 900, height: 900), cornerWidth: 205, cornerHeight: 205, transform: nil))
    context.fillPath()
    context.setStrokeColor(color(foregrounds[variant]).cgColor)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setLineWidth([66, 64, 62][variant])
    switch variant {
    case 0:
        context.addPath(CGPath(roundedRect: CGRect(x: 260, y: 466, width: 350, height: 286), cornerWidth: 78, cornerHeight: 78, transform: nil))
        context.strokePath()
        context.move(to: CGPoint(x: 610, y: 610))
        context.addLine(to: CGPoint(x: 610, y: 242))
        context.addCurve(to: CGPoint(x: 756, y: 434), control1: CGPoint(x: 610, y: 332), control2: CGPoint(x: 770, y: 302))
        context.strokePath()
    case 1:
        context.move(to: CGPoint(x: 675, y: 590))
        context.addLine(to: CGPoint(x: 675, y: 665))
        context.addQuadCurve(to: CGPoint(x: 590, y: 750), control: CGPoint(x: 675, y: 750))
        context.addLine(to: CGPoint(x: 350, y: 750))
        context.addQuadCurve(to: CGPoint(x: 265, y: 665), control: CGPoint(x: 265, y: 750))
        context.addLine(to: CGPoint(x: 265, y: 465))
        context.addQuadCurve(to: CGPoint(x: 350, y: 380), control: CGPoint(x: 265, y: 380))
        context.addLine(to: CGPoint(x: 590, y: 380))
        context.addQuadCurve(to: CGPoint(x: 675, y: 465), control: CGPoint(x: 675, y: 380))
        context.addLine(to: CGPoint(x: 675, y: 505))
        context.addCurve(to: CGPoint(x: 750, y: 525), control1: CGPoint(x: 675, y: 545), control2: CGPoint(x: 715, y: 555))
        context.addCurve(to: CGPoint(x: 790, y: 420), control1: CGPoint(x: 790, y: 490), control2: CGPoint(x: 800, y: 455))
        context.strokePath()
    default:
        context.addPath(CGPath(roundedRect: CGRect(x: 220, y: 502, width: 220, height: 220), cornerWidth: 56, cornerHeight: 56, transform: nil))
        context.strokePath()
        context.addPath(CGPath(roundedRect: CGRect(x: 580, y: 402, width: 220, height: 220), cornerWidth: 56, cornerHeight: 56, transform: nil))
        context.strokePath()
        context.move(to: CGPoint(x: 440, y: 610))
        context.addLine(to: CGPoint(x: 440, y: 270))
        context.addLine(to: CGPoint(x: 800, y: 210))
        context.addLine(to: CGPoint(x: 800, y: 510))
        context.strokePath()
    }
    context.restoreGState()
}

func render(width: Int, height: Int, filename: String, drawing: (CGContext) -> Void) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    graphics.cgContext.setShouldAntialias(true)
    drawing(graphics.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(filename))
}

for variant in 0..<3 {
    try render(width: 1024, height: 1024, filename: "icon-concept-\(["a", "b", "c"][variant]).png") { context in
        icon(variant, in: CGRect(x: 0, y: 0, width: 1024, height: 1024), canvasHeight: 1024, context: context)
    }
}

try render(width: 1440, height: 900, filename: "brand-options.png") { context in
    let height: CGFloat = 900
    color(0xF7F7F3).setFill()
    NSRect(x: 0, y: 0, width: 1440, height: 900).fill()
    func text(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular, hex: UInt32 = 0x253C34) {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        (value as NSString).draw(at: NSPoint(x: x, y: height - y - size * 1.25), withAttributes: [.font: font, .foregroundColor: color(hex)])
    }
    text("KEYBOARD → MUSIC", x: 72, y: 52, size: 14, weight: .medium, hex: 0x6A7C73)
    text("一个按键，一点旋律。", x: 72, y: 84, size: 36, weight: .semibold)
    text("图标先表达产品；名字可以慢慢选。", x: 72, y: 141, size: 16, hex: 0x728078)
    let captions = ["一键成音", "留一点余音", "两键成句"]
    let subtitles = ["键帽成为音符，不需要额外装饰。", "一笔延展，像声音轻轻散开。", "把连续敲击，连成一句音乐。"]
    let topLabels = ["A / RECOMMENDED", "B / A SMALL SUSTAIN", "C / TWO KEYS, ONE PHRASE"]
    for i in 0..<3 {
        let x = CGFloat(60 + i * 448)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: height - 700, width: 424, height: 496), xRadius: 24, yRadius: 24).fill()
        text(topLabels[i], x: x + 32, y: 231, size: 13, weight: .medium, hex: 0x6A7C73)
        icon(i, in: CGRect(x: x + 84, y: 270, width: 256, height: 256), canvasHeight: height, context: context)
        text(captions[i], x: x + 32, y: 539, size: 22, weight: .semibold)
        text(subtitles[i], x: x + 32, y: 575, size: 14, hex: 0x728078)
        icon(i, in: CGRect(x: x + 32, y: 631, width: 16, height: 16), canvasHeight: height, context: context)
        icon(i, in: CGRect(x: x + 80, y: 623, width: 32, height: 32), canvasHeight: height, context: context)
        icon(i, in: CGRect(x: x + 144, y: 607, width: 64, height: 64), canvasHeight: height, context: context)
        text("16 / 32 / 64 px", x: x + 236, y: 627, size: 12, hex: 0x8A948D)
    }
    text("SHORT NAMES · TWO SYLLABLES", x: 72, y: 742, size: 14, weight: .medium, hex: 0x6A7C73)
    let names = ["Keyli  轻律", "Keva  键歌", "Toki  叩音"]
    let pronunciation = ["key-lee · 目前推荐的命名方向", "keh-vah · 更抽象，短而顺口", "toh-kee · 好念，但已有同名应用"]
    for i in 0..<3 {
        let x = CGFloat(72 + i * 448)
        text(names[i], x: x, y: 777, size: 26, weight: .medium)
        text(pronunciation[i], x: x, y: 817, size: 14, hex: 0x728078)
    }
    text("Names are proposals. Limited web collision check only; no availability or trademark claim. The app has not been renamed.", x: 72, y: 864, size: 11, hex: 0x8A948D)
}
print(output.appendingPathComponent("brand-options.png").path)
