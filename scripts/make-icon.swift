import AppKit
import Foundation

@main
enum IconRenderer {
static func main() throws {
guard CommandLine.arguments.count == 3, let source = NSImage(contentsOfFile: CommandLine.arguments[2]) else {
    throw NSError(domain: "KeyWooIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Usage: icon-renderer output.iconset source.png"])
}
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
func draw(size: Int, name: String) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    // Fit the untouched, full-bleed artwork into the native app icon frame.
    let inset = Double(size) * 0.06
    let frame = CGRect(x: inset, y: inset, width: Double(size) - inset * 2, height: Double(size) - inset * 2)
    NSBezierPath(roundedRect: frame, xRadius: Double(size) * 0.195, yRadius: Double(size) * 0.195).addClip()
    source.draw(in: frame)
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
}
for size in [16, 32, 128, 256, 512] {
    try draw(size: size, name: "icon_\(size)x\(size).png")
    try draw(size: size * 2, name: "icon_\(size)x\(size)@2x.png")
}

// PNG-backed ICNS chunks are understood directly by modern macOS.
let entries = [("icp4", "icon_16x16.png"), ("icp5", "icon_32x32.png"),
               ("icp6", "icon_32x32@2x.png"), ("ic07", "icon_128x128.png"),
               ("ic08", "icon_256x256.png"), ("ic09", "icon_512x512.png"),
               ("ic10", "icon_512x512@2x.png")]
func lengthBytes(_ length: Int) -> Data {
    var value = UInt32(length).bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
}
var body = Data()
for (kind, filename) in entries {
    let pixels = try Data(contentsOf: directory.appendingPathComponent(filename))
    body.append(Data(kind.utf8))
    body.append(lengthBytes(pixels.count + 8))
    body.append(pixels)
}
var icon = Data("icns".utf8)
icon.append(lengthBytes(body.count + 8))
icon.append(body)
try icon.write(to: directory.deletingLastPathComponent().appendingPathComponent("AppIcon.icns"))

}
}
