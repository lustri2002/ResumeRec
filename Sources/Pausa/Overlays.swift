import AppKit
import CoreImage
import PausaCore

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class CameraPreview {
    private let panel: NSPanel
    private let previewView = NSView()
    private let imageView = NSImageView()
    private let videoView = WebcamVideoView(frame: .zero)
    private lazy var compositor = Compositor()
    private var timer: Timer?
    private weak var model: RecorderModel?
    private var lastRect: CGRect = .zero
    private var placementArea: CGRect = .zero
    private var dragging = false
    private var dragStartPointer = CGPoint.zero
    private var dragStartFrame = CGRect.zero
    private var cachedWindowID: UInt32 = 0
    private var cachedWindowFrame: Result<CGRect, RecorderError>?
    private var windowCheckedAt = 0.0
    private lazy var example = makeExample()
    private var examplePreferences: Preferences?
    private var exampleSize: CGSize = .zero

    init(model: RecorderModel) {
        self.model = model
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Webcam Preview"
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .floating; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.contentView = previewView
        imageView.autoresizingMask = [.width, .height]
        videoView.autoresizingMask = [.width, .height]
        previewView.addSubview(imageView)
        previewView.addSubview(videoView)
        imageView.imageScaling = .scaleAxesIndependently
        imageView.setAccessibilityLabel("Life-size webcam preview. Drag to reposition.")
        previewView.addGestureRecognizer(NSPanGestureRecognizer(target: self, action: #selector(pan(_:))))
        let timer = Timer(timeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    func hide() {
        if dragging { model?.finishCameraDrag() }
        if panel.isVisible { panel.orderOut(nil) }
        videoView.reset(); dragging = false
    }

    private func sourceFrame(_ p: Preferences) throws -> CGRect {
        if p.mode == .window {
            guard p.windowID != 0 else { throw RecorderError("Select a window in Recording to place the life-size preview.") }
            let now = ProcessInfo.processInfo.systemUptime
            if cachedWindowID == p.windowID, now - windowCheckedAt < 0.2, let cachedWindowFrame {
                return try cachedWindowFrame.get()
            }
            cachedWindowID = p.windowID; windowCheckedAt = now
            let result: Result<CGRect, RecorderError>
            if let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, p.windowID) as? [[String: Any]])?.first,
               info[kCGWindowIsOnscreen as String] as? Bool == true,
               let bounds = info[kCGWindowBounds as String] as? [String: Any],
               let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
               rect.width > 0, rect.height > 0,
               let primary = NSScreen.screens.first {
                result = .success(Geometry.desktopRect(from: rect, desktopTop: primary.frame.maxY))
            } else {
                result = .failure(RecorderError("The selected window is not visible. Restore it or choose another window in Recording."))
            }
            cachedWindowFrame = result
            return try result.get()
        }
        let id = p.displayID == 0 ? CGMainDisplayID() : p.displayID
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) == id
        }) else { throw RecorderError("The selected display is unavailable. Choose a display in Recording.") }
        if p.mode == .region {
            guard let region = p.region else { throw RecorderError("Select a region in Recording to place the life-size preview.") }
            let local = CGRect(x: region.x, y: region.y, width: region.width, height: region.height)
            guard local.width >= 32, local.height >= 32,
                  CGRect(origin: .zero, size: screen.frame.size).contains(local) else {
                throw RecorderError("The selected region no longer fits this display. Select it again in Recording.")
            }
            return CGRect(x: screen.frame.minX + local.minX, y: screen.frame.maxY - local.maxY,
                          width: local.width, height: local.height)
        }
        return screen.frame
    }

    private func refresh() {
        guard let model else { hide(); return }
        let p = model.overlayPreferences
        let configuring = model.isConfiguringWebcam
        let recordingPreview = model.state == .recording && p.camera && p.showPreview
        guard configuring || recordingPreview else {
            hide(); model.updatePreviewPlacementMessage(nil); return
        }
        let source: CGRect
        do { source = try sourceFrame(p) }
        catch { hide(); model.updatePreviewPlacementMessage(error.localizedDescription); return }
        guard let screen = NSScreen.screens.max(by: {
            let lhs = $0.frame.intersection(source), rhs = $1.frame.intersection(source)
            return (lhs.isNull ? 0 : lhs.width * lhs.height) < (rhs.isNull ? 0 : rhs.width * rhs.height)
        }) else { hide(); return }
        let sourcePixels = CGSize(width: source.width * screen.backingScaleFactor,
                                  height: source.height * screen.backingScaleFactor)
        let videoSize = model.state == .idle ? Geometry.canvas(source: sourcePixels, maxHeight: p.resolution) : model.activeCanvas
        if !dragging { placementArea = Geometry.desktopCanvas(videoSize: videoSize, sourceFrame: source) }
        let relative = Geometry.cameraRect(in: placementArea.size, preferences: p)
        let rect = relative.offsetBy(dx: placementArea.minX, dy: placementArea.minY)
        guard NSScreen.screens.contains(where: { $0.frame.intersects(rect) }) else {
            hide()
            model.updatePreviewPlacementMessage("The webcam is outside the visible desktop at this video aspect ratio. Choose another position.")
            return
        }
        let buffer = p.camera ? (model.state == .recording ? model.engine.camera.frame() : model.settingsCamera.camera.frame()) : nil
        if buffer == nil && !configuring { hide(); return }
        var message: String?
        if !NSScreen.screens.contains(where: { $0.frame.contains(rect) }) {
            message = "Part of the life-size preview is outside this display. Choose another position to see it fully."
        } else if p.camera, buffer == nil, case .ready = model.settingsCamera.state {
            message = "Waiting for webcam images. The placeholder shows the actual size and position."
        }
        model.updatePreviewPlacementMessage(message)
        if !dragging && rect != lastRect { panel.setFrame(rect, display: true); lastRect = rect }
        if let buffer {
            imageView.isHidden = true; videoView.isHidden = false
            videoView.display(buffer, preferences: p)
        } else {
            videoView.isHidden = true; videoView.reset(); imageView.isHidden = false
            let renderSize = CGSize(width: max(2, rect.width * screen.backingScaleFactor), height: max(2, rect.height * screen.backingScaleFactor))
            // Position does not change the placeholder's pixels. Do not render it again while dragging.
            if exampleSize != renderSize || examplePreferences?.shape != p.shape ||
                examplePreferences?.borderWidth != p.borderWidth || examplePreferences?.mirrored != p.mirrored {
                let image = compositor.cameraImage(example, size: renderSize, preferences: p)
                if let cg = compositor.context.createCGImage(image, from: CGRect(origin: .zero, size: renderSize)) {
                    imageView.image = NSImage(cgImage: cg, size: rect.size)
                    exampleSize = renderSize; examplePreferences = p
                }
            }
        }
        // Reordering a visible window for every camera frame needlessly involves WindowServer.
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    @objc private func pan(_ recognizer: NSPanGestureRecognizer) {
        guard let model, placementArea.width > 0 else { return }
        switch recognizer.state {
        case .began:
            dragging = true
            dragStartPointer = NSEvent.mouseLocation; dragStartFrame = panel.frame
        case .changed, .ended:
            guard dragging else { return }
            let rect = Geometry.draggedCameraRect(initial: dragStartFrame, pointerStart: dragStartPointer,
                                                  pointerNow: NSEvent.mouseLocation, inside: placementArea)
            if panel.frame.origin != rect.origin { panel.setFrameOrigin(rect.origin) }
            model.updateCameraDrag(position: CGPoint(x: (rect.midX - placementArea.minX) / placementArea.width,
                                                      y: (rect.midY - placementArea.minY) / placementArea.height))
            lastRect = rect
            if recognizer.state == .ended { dragging = false; model.finishCameraDrag() }
        case .cancelled, .failed:
            dragging = false; model.finishCameraDrag()
        default: break
        }
    }

    private func makeExample() -> CIImage {
        let image = NSImage(size: CGSize(width: 320, height: 200), flipped: false) { rect in
            NSGradient(starting: NSColor(calibratedRed: 0.35, green: 0.48, blue: 0.72, alpha: 1),
                       ending: NSColor(calibratedRed: 0.55, green: 0.37, blue: 0.67, alpha: 1))?.draw(in: rect, angle: 0)
            NSColor.white.withAlphaComponent(0.8).setFill()
            NSBezierPath(ovalIn: CGRect(x: 132, y: 103, width: 56, height: 56)).fill()
            NSBezierPath(ovalIn: CGRect(x: 97, y: -18, width: 126, height: 112)).fill()
            return true
        }
        return CIImage(cgImage: image.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
    }
}

final class RegionSelectionView: NSView {
    var selected: ((CGRect?) -> Void)?
    private var origin: CGPoint?
    private var rect: CGRect = .zero
    override var acceptsFirstResponder: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.4).setFill(); bounds.fill()
        if !rect.isEmpty {
            NSColor.white.withAlphaComponent(0.15).setFill(); rect.fill()
            NSColor.white.setStroke(); let path = NSBezierPath(rect: rect); path.lineWidth = 2; path.stroke()
        }
        let text = "Drag to select a region · Esc to cancel"
        let attributes: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 22, weight: .semibold)]
        let size = text.size(withAttributes: attributes)
        text.draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: bounds.height - 90), withAttributes: attributes)
    }
    override func mouseDown(with event: NSEvent) { origin = convert(event.locationInWindow, from: nil) }
    override func mouseDragged(with event: NSEvent) {
        guard let origin else { return }
        let end = convert(event.locationInWindow, from: nil)
        rect = CGRect(x: min(origin.x, end.x), y: min(origin.y, end.y), width: abs(end.x - origin.x), height: abs(end.y - origin.y)).intersection(bounds)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard rect.width >= 32, rect.height >= 32 else { return }
        selected?(CGRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height))
    }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { selected?(nil) } }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
}

@MainActor
final class RegionSelector {
    private var panel: OverlayPanel?
    func select(displayID: UInt32, completion: @escaping (Region?) -> Void) {
        guard let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) == displayID })
            ?? (displayID == 0 ? NSScreen.main : nil) else { completion(nil); return }
        let panel = OverlayPanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = RegionSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.selected = { [weak self] rect in
            self?.panel?.orderOut(nil); self?.panel = nil
            completion(rect.map { Region(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height) })
        }
        panel.contentView = view; self.panel = panel
        NSApp.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(view)
    }
}
