import AppKit

@MainActor
enum BrandAssets {
    static let appIcon: NSImage? = {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") else { return nil }
        return NSImage(contentsOf: url)
    }()

    static let menuBar: NSImage? = {
        let size = NSSize(width: 26, height: 18)
        let image = NSImage(size: size)
        for name in ["MenuBarTemplate", "MenuBarTemplate@2x"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
                  let data = try? Data(contentsOf: url),
                  let rep = NSBitmapImageRep(data: data) else { continue }
            rep.size = size
            image.addRepresentation(rep)
        }
        guard !image.representations.isEmpty else { return nil }
        image.isTemplate = true
        image.accessibilityDescription = "ResumeRec: Ready"
        return image
    }()
}
