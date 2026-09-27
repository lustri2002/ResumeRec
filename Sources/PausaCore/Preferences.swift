import Foundation
import CoreGraphics

public enum CaptureMode: String, Codable, CaseIterable, Identifiable {
    case display, window, region
    public var id: String { rawValue }
    public var title: String { switch self { case .display: "Display"; case .window: "Window"; case .region: "Region" } }
}
public enum CameraShape: String, Codable, CaseIterable, Identifiable {
    case circle, square, rounded
    public var id: String { rawValue }
    public var title: String { switch self { case .circle: "Circle"; case .square: "Square"; case .rounded: "Rounded rectangle" } }
}
public enum Anchor: String, Codable, CaseIterable, Identifiable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, custom
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .topLeft: "Top left"; case .top: "Top"; case .topRight: "Top right"
        case .right: "Right"; case .bottomRight: "Bottom right"; case .bottom: "Bottom"
        case .bottomLeft: "Bottom left"; case .left: "Left"; case .custom: "Custom"
        }
    }
}
public enum VideoCodec: String, Codable, CaseIterable, Identifiable {
    case h264, hevc
    public var id: String { rawValue }
    public var title: String { self == .h264 ? "H.264 — compatibility" : "HEVC — smaller files" }
}
public struct Region: Codable, Equatable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}
public struct Preferences: Codable, Equatable {
    public var mode: CaptureMode = .display
    public var displayID: UInt32 = 0
    public var windowID: UInt32 = 0
    public var region: Region?
    public var systemAudio = false
    public var microphone = true
    public var microphoneID = ""
    public var camera = false
    public var cameraID = ""
    public var showPreview = true
    public var shape: CameraShape = .circle
    public var anchor: Anchor = .bottomRight
    public var cameraSize = 0.20
    public var customX = 0.80
    public var customY = 0.20
    public var mirrored = true
    public var borderWidth = 3.0
    public var countdown = 3
    public var folder = ""
    public var fps = 30
    /// Maximum output height; 0 preserves source resolution.
    public var resolution = 1080
    public var codec: VideoCodec = .h264
    public var bitRateMbps = 12
    public var showCursor = true
    public var hotkeysEnabled = true
    public var startKey = "R"
    public var pauseKey = "P"
    public var stopKey = "S"
    public init() {}

    public func sanitized() -> Preferences {
        var result = self
        result.cameraSize = cameraSize.isFinite ? min(0.45, max(0.10, cameraSize)) : 0.20
        result.customX = customX.isFinite ? min(1, max(0, customX)) : 0.80
        result.customY = customY.isFinite ? min(1, max(0, customY)) : 0.20
        result.borderWidth = min(12, max(0, borderWidth))
        result.countdown = min(15, max(0, countdown))
        result.fps = [24, 30, 60].contains(fps) ? fps : 30
        result.resolution = [0, 720, 1080, 1440, 2160].contains(resolution) ? resolution : 1080
        result.bitRateMbps = min(80, max(2, bitRateMbps))
        return result
    }
}

public enum Geometry {
    /// Track from fixed desktop coordinates, independent of the moving preview's local space.
    public static func draggedCameraRect(initial: CGRect, pointerStart: CGPoint,
                                         pointerNow: CGPoint, inside canvas: CGRect) -> CGRect {
        var rect = initial.offsetBy(dx: pointerNow.x - pointerStart.x, dy: pointerNow.y - pointerStart.y)
        rect.origin.x = max(canvas.minX, min(canvas.maxX - rect.width, rect.minX))
        rect.origin.y = max(canvas.minY, min(canvas.maxY - rect.height, rect.minY))
        return rect
    }
    /// Converts Core Graphics' top-left screen space into AppKit desktop coordinates.
    public static func desktopRect(from screenRect: CGRect, desktopTop: CGFloat) -> CGRect {
        CGRect(x: screenRect.minX, y: desktopTop - screenRect.maxY,
               width: screenRect.width, height: screenRect.height)
    }
    /// Inverse of the recorder's aspect-fit transform. Does not shrink to the visible work area.
    public static func desktopCanvas(videoSize: CGSize, sourceFrame: CGRect) -> CGRect {
        let content = fit(sourceFrame.size, inside: CGRect(origin: .zero, size: videoSize))
        guard content.width > 0 else { return .zero }
        let scale = sourceFrame.width / content.width
        return CGRect(x: sourceFrame.minX - content.minX * scale,
                      y: sourceFrame.minY - content.minY * scale,
                      width: videoSize.width * scale, height: videoSize.height * scale)
    }
    public static func canvas(source: CGSize, maxHeight: Int) -> CGSize {
        let scale = maxHeight == 0 ? 1 : min(1, Double(maxHeight) / max(1, source.height))
        return CGSize(width: max(2, floor(source.width * scale / 2) * 2),
                      height: max(2, floor(source.height * scale / 2) * 2))
    }
    public static func fit(_ source: CGSize, inside target: CGRect) -> CGRect {
        guard source.width > 0, source.height > 0 else { return .zero }
        let scale = min(target.width / source.width, target.height / source.height)
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        return CGRect(x: target.midX - size.width / 2, y: target.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
    /// Bottom-left coordinates shared by Core Image and AppKit.
    public static func cameraRect(in canvas: CGSize, preferences p: Preferences) -> CGRect {
        let width = min(canvas.width, canvas.height) * p.cameraSize * 1.6
        let height = p.shape == .rounded ? width * 0.625 : width
        let margin = min(canvas.width, canvas.height) * 0.025
        let left = margin, right = canvas.width - width - margin
        let bottom = margin, top = canvas.height - height - margin
        let centerX = (canvas.width - width) / 2, centerY = (canvas.height - height) / 2
        let origin: CGPoint
        switch p.anchor {
        case .topLeft: origin = CGPoint(x: left, y: top)
        case .top: origin = CGPoint(x: centerX, y: top)
        case .topRight: origin = CGPoint(x: right, y: top)
        case .right: origin = CGPoint(x: right, y: centerY)
        case .bottomRight: origin = CGPoint(x: right, y: bottom)
        case .bottom: origin = CGPoint(x: centerX, y: bottom)
        case .bottomLeft: origin = CGPoint(x: left, y: bottom)
        case .left: origin = CGPoint(x: left, y: centerY)
        case .custom:
            origin = CGPoint(x: min(canvas.width - width, max(0, p.customX * canvas.width - width / 2)),
                             y: min(canvas.height - height, max(0, p.customY * canvas.height - height / 2)))
        }
        return CGRect(origin: origin, size: CGSize(width: width, height: height))
    }
}
