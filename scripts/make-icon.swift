import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]
for (name, size) in sizes {
    let side = CGFloat(size)
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor(calibratedRed: 0.07, green: 0.31, blue: 0.26, alpha: 1).setFill()
    let inset = side * 0.08
    NSBezierPath(roundedRect: CGRect(x: inset, y: inset, width: side - 2 * inset, height: side - 2 * inset),
                 xRadius: side * 0.2, yRadius: side * 0.2).fill()
    if let symbol = NSImage(systemSymbolName: "leaf.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: side * 0.5, weight: .regular)) {
        let rect = CGRect(x: side * 0.22, y: side * 0.23, width: side * 0.56, height: side * 0.54)
        let leaf = NSImage(size: rect.size, flipped: false) { bounds in
            symbol.draw(in: bounds)
            NSColor(calibratedRed: 0.59, green: 0.89, blue: 0.79, alpha: 1).setFill()
            bounds.fill(using: .sourceAtop)
            return true
        }
        leaf.draw(in: rect)
    }
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
}
