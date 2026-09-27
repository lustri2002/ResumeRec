import AppKit

// Packaging and size proof for the approved artwork; no screen capture involved.
let resources = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let source = NSBitmapImageRep(data: try Data(contentsOf: resources.appendingPathComponent("Brand/MenuBar-source.png")))!
var minX = source.pixelsWide, minY = source.pixelsHigh, maxX = 0, maxY = 0
for y in 0..<source.pixelsHigh {
    for x in 0..<source.pixelsWide where (source.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
        minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
    }
}
precondition(maxX > minX && maxY > minY, "Template artwork is empty")
let bounds = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
let cropped = source.cgImage!.cropping(to: bounds)!
let mark = NSImage(cgImage: cropped, size: bounds.size)

func bitmap(_ width: Int, _ height: Int, draw: () -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}
func save(_ rep: NSBitmapImageRep, _ path: String) throws {
    try rep.representation(using: .png, properties: [:])!.write(to: resources.appendingPathComponent(path))
}
for scale in [1, 2] {
    let rep = bitmap(26 * scale, 18 * scale) {
        let factor = min(CGFloat(24 * scale) / bounds.width, CGFloat(16 * scale) / bounds.height)
        let size = CGSize(width: bounds.width * factor, height: bounds.height * factor)
        let rect = CGRect(x: (CGFloat(26 * scale) - size.width) / 2,
                          y: (CGFloat(18 * scale) - size.height) / 2, width: size.width, height: size.height)
        mark.draw(in: rect)
        // Template images encode shape solely in alpha; normalize RGB to black.
        NSColor.black.setFill()
        NSRect(x: 0, y: 0, width: 26 * scale, height: 18 * scale).fill(using: .sourceIn)
    }
    try save(rep, scale == 1 ? "MenuBarTemplate.png" : "MenuBarTemplate@2x.png")
}

let app = NSImage(contentsOf: resources.appendingPathComponent("AppIcon.icns"))!
let template = NSImage(contentsOf: resources.appendingPathComponent("MenuBarTemplate.png"))!
let template2x = NSImage(contentsOf: resources.appendingPathComponent("MenuBarTemplate@2x.png"))!
let proof = bitmap(900, 400) {
    NSColor(white: 0.95, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 900, height: 400).fill()
    func label(_ text: String, _ x: CGFloat, _ y: CGFloat) {
        (text as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.black])
    }
    label("ResumeRec — app icon sizes (pixels)", 24, 370)
    var x: CGFloat = 24
    for size in [256, 128, 64, 32, 16] {
        app.draw(in: CGRect(x: x, y: 85, width: CGFloat(size), height: CGFloat(size)))
        label("\(size)", x, 58); x += CGFloat(size + 24)
    }
    label("Menu bar · 1× and 2× assets", 580, 330)
    for (index, background) in [NSColor.white, NSColor(white: 0.13, alpha: 1)].enumerated() {
        let y = CGFloat(265 - index * 75)
        background.setFill(); NSRect(x: 580, y: y, width: 290, height: 52).fill()
        for (image, x, size) in [(template, CGFloat(596), CGSize(width: 26, height: 18)),
                                 (template2x, CGFloat(658), CGSize(width: 52, height: 36))] {
            let tinted = bitmap(Int(size.width), Int(size.height)) {
                image.draw(in: CGRect(origin: .zero, size: size))
                (index == 0 ? NSColor.black : NSColor.white).setFill()
                NSRect(origin: .zero, size: size).fill(using: .sourceIn)
            }
            NSImage(cgImage: tinted.cgImage!, size: size).draw(in: CGRect(x: x, y: y + (52 - size.height) / 2, width: size.width, height: size.height))
        }
    }
}
try save(proof, "Brand/Icon-size-proof.png")
print("Template content bounds: \(bounds). Exported 1×/2× template assets and size proof.")
