import AppKit
import AVFoundation
import PausaCore

/// Displays the camera's existing pixel buffers directly, without a Core Image → CGImage
/// round trip on the UI thread. The layer tree supplies the same crop, mask and border.
@MainActor
final class WebcamVideoView: NSView {
    private let videoLayer = AVSampleBufferDisplayLayer()
    private let contentMask = CAShapeLayer()
    private let outerMask = CAShapeLayer()
    private var format: CMVideoFormatDescription?
    private var lastBuffer: CVPixelBuffer?
    private var currentAppearance: Appearance?
    private var showingVideo = false

    private struct Appearance: Equatable {
        let size: CGSize
        let shape: CameraShape
        let border: Double
        let mirrored: Bool
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.mask = outerMask
        layer?.addSublayer(videoLayer)
        videoLayer.videoGravity = .resizeAspectFill
        videoLayer.mask = contentMask
        setAccessibilityElement(true)
        setAccessibilityLabel("Life-size webcam preview. Drag to reposition.")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func display(_ buffer: CVPixelBuffer, preferences: Preferences) {
        updateAppearance(preferences)
        let renderer = videoLayer.sampleBufferRenderer
        if renderer.requiresFlushToResumeDecoding || renderer.status == .failed {
            renderer.flush(); lastBuffer = nil
        }
        guard lastBuffer !== buffer, renderer.isReadyForMoreMediaData else { return }
        if format == nil || !CMVideoFormatDescriptionMatchesImageBuffer(format!, imageBuffer: buffer) {
            var description: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer,
                                                                formatDescriptionOut: &description) == noErr else { return }
            format = description
        }
        guard let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                       presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                       decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer,
                                                       formatDescription: format, sampleTiming: &timing,
                                                       sampleBufferOut: &sample) == noErr, let sample else { return }
        // Sample-level attachment (not a buffer-level CMSetAttachment).
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        renderer.enqueue(sample)
        lastBuffer = buffer; showingVideo = true
    }

    func reset() {
        guard showingVideo else { return }
        videoLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        lastBuffer = nil; format = nil; showingVideo = false
    }

    private func updateAppearance(_ p: Preferences) {
        let next = Appearance(size: bounds.size, shape: p.shape, border: p.borderWidth, mirrored: p.mirrored)
        guard next != currentAppearance else { return }
        currentAppearance = next
        CATransaction.begin(); CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        videoLayer.setAffineTransform(CGAffineTransform(scaleX: p.mirrored ? -1 : 1, y: 1))
        outerMask.frame = bounds; contentMask.frame = bounds
        outerMask.path = Self.maskPath(bounds, shape: p.shape, radius: bounds.width * 0.09)
        let inset = p.borderWidth * bounds.width / 260
        contentMask.path = Self.maskPath(bounds.insetBy(dx: inset, dy: inset), shape: p.shape, radius: bounds.width * 0.09)
        CATransaction.commit()
    }

    private static func maskPath(_ rect: CGRect, shape: CameraShape, radius: CGFloat) -> CGPath {
        switch shape {
        case .circle: return CGPath(ellipseIn: rect, transform: nil)
        case .square: return CGPath(rect: rect, transform: nil)
        case .rounded: return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }
    }
}
