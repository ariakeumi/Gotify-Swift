import AppKit

let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Design/statusbar-icon-concepts")
let source = folder.appendingPathComponent("winged-envelope-statusbar.svg")

guard let image = NSImage(contentsOf: source) else {
    fatalError("Unable to load the SVG source")
}

func render(size: Int, name: String) throws {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    bitmap.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Unable to encode PNG")
    }
    try png.write(to: folder.appendingPathComponent(name))
}

try render(size: 18, name: "winged-envelope-statusbar.png")
try render(size: 36, name: "winged-envelope-statusbar@2x.png")

let preview = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: 720,
    pixelsHigh: 230,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: preview)
NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: 720, height: 230).fill()
NSColor.white.setFill()
NSRect(x: 82, y: 30, width: 170, height: 170).fill()
image.draw(in: NSRect(x: 82, y: 30, width: 170, height: 170), from: .zero, operation: .destinationIn, fraction: 1)

let labelStyle: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 22, weight: .medium),
    .foregroundColor: NSColor.white
]
NSAttributedString(string: "Winged Envelope", attributes: labelStyle).draw(at: NSPoint(x: 300, y: 135))
NSAttributedString(string: "18 pt macOS menu bar template icon", attributes: [
    .font: NSFont.systemFont(ofSize: 15),
    .foregroundColor: NSColor(calibratedWhite: 0.68, alpha: 1)
]).draw(at: NSPoint(x: 300, y: 101))
NSGraphicsContext.restoreGraphicsState()

guard let previewPNG = preview.representation(using: .png, properties: [:]) else {
    fatalError("Unable to encode preview PNG")
}
try previewPNG.write(to: folder.appendingPathComponent("winged-envelope-statusbar-preview.png"))
