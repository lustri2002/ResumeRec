import AppKit
import AVFoundation
import CoreImage
import PausaCore

struct RecorderError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

final class Compositor {
    let context = CIContext(options: [.cacheIntermediates: false, .priorityRequestLow: true])
    private var maskCache: [String: CIImage] = [:]

    func cameraImage(_ image: CIImage, size: CGSize, preferences p: Preferences) -> CIImage {
        let bounds = CGRect(origin: .zero, size: size)
        var input = image
        if p.mirrored {
            input = input.transformed(by: CGAffineTransform(translationX: -input.extent.minX, y: -input.extent.minY))
            input = input.transformed(by: CGAffineTransform(scaleX: -1, y: 1))
                .transformed(by: CGAffineTransform(translationX: image.extent.width, y: 0))
        }
        let scale = max(size.width / input.extent.width, size.height / input.extent.height)
        input = input.transformed(by: CGAffineTransform(translationX: -input.extent.minX, y: -input.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        input = input.transformed(by: CGAffineTransform(translationX: (size.width - input.extent.width) / 2,
                                                       y: (size.height - input.extent.height) / 2)).cropped(to: bounds)
        let transparent = CIImage(color: .clear).cropped(to: bounds)
        let outer = mask(size: size, shape: p.shape, inset: 0)
        let border = CIImage(color: .white).cropped(to: bounds).applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: transparent, kCIInputMaskImageKey: outer
        ])
        let inner = mask(size: size, shape: p.shape, inset: p.borderWidth * size.width / 260)
        let cut = input.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: transparent, kCIInputMaskImageKey: inner
        ])
        return cut.composited(over: border).cropped(to: bounds)
    }

    func compose(screen: CVPixelBuffer, camera: CVPixelBuffer?, size: CGSize, preferences p: Preferences) -> CIImage {
        let bounds = CGRect(origin: .zero, size: size)
        let source = CIImage(cvPixelBuffer: screen)
        let fitted = Geometry.fit(source.extent.size, inside: bounds)
        var result = source
        if source.extent != bounds {
            result = source.transformed(by: CGAffineTransform(scaleX: fitted.width / source.extent.width,
                                                              y: fitted.height / source.extent.height))
            .transformed(by: CGAffineTransform(translationX: fitted.minX, y: fitted.minY))
            .composited(over: CIImage(color: .black).cropped(to: bounds))
        }
        if p.camera, let camera {
            let rect = Geometry.cameraRect(in: size, preferences: p)
            let overlay = cameraImage(CIImage(cvPixelBuffer: camera), size: rect.size, preferences: p)
                .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
            result = overlay.composited(over: result)
        }
        return result.cropped(to: bounds)
    }

    private func mask(size: CGSize, shape: CameraShape, inset: Double) -> CIImage {
        let key = "\(size.width)-\(size.height)-\(shape)-\(inset)"
        if let cached = maskCache[key] { return cached }
        let w = max(2, Int(ceil(size.width))), h = max(2, Int(ceil(size.height)))
        let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.setFillColor(gray: 1, alpha: 1)
        let rect = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
        switch shape {
        case .circle: context.fillEllipse(in: rect)
        case .square: context.fill(rect)
        case .rounded:
            context.addPath(CGPath(roundedRect: rect, cornerWidth: size.width * 0.09,
                                   cornerHeight: size.width * 0.09, transform: nil))
            context.fillPath()
        }
        let image = CIImage(cgImage: context.makeImage()!)
        if maskCache.count > 20 { maskCache.removeAll() }
        maskCache[key] = image
        return image
    }
}

/// All methods, except finalization, run on CaptureEngine.queue.
final class SegmentWriter {
    let url: URL
    let size: CGSize
    let writer: AVAssetWriter
    let video: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var audio: [Int: AVAssetWriterInput] = [:]
    private lazy var compositor = Compositor()
    private(set) var origin: CMTime?
    private var lastVideo: CMTime = .invalid
    private var lastAudio: [Int: CMTime] = [:]
    private var failure: Error?
    private let fps: Int
    private var droppedFrames = 0
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    // A single retained result avoids re-rendering identical screen/camera snapshots.
    // Retaining inputs also prevents their capture pools from recycling them under this cache.
    private var cachedScreen: CVPixelBuffer?
    private var cachedCamera: CVPixelBuffer?
    private var cachedPreferences: Preferences?
    private var cachedOutput: CVPixelBuffer?

    init(url: URL, size: CGSize, preferences p: Preferences) throws {
        self.url = url; self.size = size; fps = p.fps
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: p.codec == .h264 ? AVVideoCodecType.h264 : AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: p.bitRateMbps * 1_000_000,
                                               AVVideoExpectedSourceFrameRateKey: p.fps,
                                               AVVideoMaxKeyFrameIntervalKey: p.fps * 2],
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                         AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                         AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        ])
        video.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        guard writer.canAdd(video) else { throw RecorderError("Unsupported video format.") }
        writer.add(video)
        for kind in [0, 1] where kind == 0 ? p.systemAudio : p.microphone {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000
            ])
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw RecorderError("Unsupported audio format.") }
            writer.add(input); audio[kind] = input
        }
        guard writer.startWriting() else { throw writer.error ?? RecorderError("Unable to start writing the video file.") }
        writer.startSession(atSourceTime: .zero)
    }

    func append(screen: CVPixelBuffer, camera: CVPixelBuffer?, at hostTime: CMTime, preferences: Preferences) {
        guard failure == nil else { return }
        if origin == nil { origin = hostTime }
        let time = CMTimeSubtract(hostTime, origin!)
        guard !lastVideo.isValid || time > lastVideo else { return }
        guard video.isReadyForMoreMediaData else {
            droppedFrames += 1
            if droppedFrames > fps * 5 { failure = RecorderError("The encoder cannot keep up with recording. Lower the resolution or frame rate.") }
            return
        }
        droppedFrames = 0
        let output: CVPixelBuffer
        if !preferences.camera, CVPixelBufferGetWidth(screen) == Int(size.width),
           CVPixelBufferGetHeight(screen) == Int(size.height) {
            // ScreenCaptureKit has already sized this frame. No compositing is needed.
            output = screen
            cachedScreen = nil; cachedCamera = nil; cachedOutput = nil; cachedPreferences = nil
        } else if cachedScreen === screen, cachedCamera === camera,
                  cachedPreferences == preferences, let cachedOutput {
            output = cachedOutput
        } else {
            guard let rendered = render(screen: screen, camera: camera, preferences: preferences) else { return }
            output = rendered
            cachedScreen = screen; cachedCamera = camera; cachedPreferences = preferences; cachedOutput = output
        }
        if adaptor.append(output, withPresentationTime: time) { lastVideo = time }
        else { failure = writer.error ?? RecorderError("Video writing was interrupted.") }
    }

    private func render(screen: CVPixelBuffer, camera: CVPixelBuffer?, preferences: Preferences) -> CVPixelBuffer? {
        guard let pool = adaptor.pixelBufferPool else { failure = RecorderError("Video buffer unavailable."); return nil }
        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output) == kCVReturnSuccess, let output else {
            failure = RecorderError("Video memory unavailable."); return nil
        }
        let image = compositor.compose(screen: screen, camera: camera, size: size, preferences: preferences)
        compositor.context.render(image, to: output, bounds: CGRect(origin: .zero, size: size), colorSpace: colorSpace)
        return output
    }

    func append(audio buffer: CMSampleBuffer, kind: Int) {
        guard failure == nil, let origin, let input = audio[kind] else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer) - origin
        guard pts >= .zero, lastAudio[kind] == nil || pts > lastAudio[kind]! else { return }
        guard input.isReadyForMoreMediaData else {
            failure = RecorderError("Audio writing cannot keep up. Check free disk space or lower the recording quality."); return
        }
        var count = 0
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = Array(repeating: CMSampleTimingInfo(), count: count)
        let status = timing.withUnsafeMutableBufferPointer {
            CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: count, arrayToFill: $0.baseAddress, entriesNeededOut: &count)
        }
        guard status == noErr else { failure = RecorderError("Unable to read audio timestamps."); return }
        for index in timing.indices {
            timing[index].presentationTimeStamp = timing[index].presentationTimeStamp - origin
            if timing[index].decodeTimeStamp.isValid { timing[index].decodeTimeStamp = timing[index].decodeTimeStamp - origin }
        }
        var copy: CMSampleBuffer?
        let copyStatus = timing.withUnsafeBufferPointer {
            CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: buffer,
                                                 sampleTimingEntryCount: count, sampleTimingArray: $0.baseAddress!, sampleBufferOut: &copy)
        }
        guard copyStatus == noErr, let copy, input.append(copy) else {
            failure = writer.error ?? RecorderError("Audio writing was interrupted."); return
        }
        lastAudio[kind] = pts
    }

    func finish() async throws -> URL {
        if let failure { writer.cancelWriting(); throw failure }
        guard lastVideo.isValid else { writer.cancelWriting(); throw RecorderError("No video frames were captured. Check the source and screen recording permission.") }
        writer.endSession(atSourceTime: lastVideo + CMTime(value: 1, timescale: CMTimeScale(fps)))
        video.markAsFinished()
        audio.values.forEach { $0.markAsFinished() }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? RecorderError("Unable to save the recording segment.") }
        return url
    }

    var currentError: Error? { failure ?? writer.error }
}

enum MovieExporter {
    static func export(segments: [URL], to output: URL, codec: VideoCodec) async throws {
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw RecorderError("Unable to create the video track.")
        }
        let audioTracks = (0..<2).compactMap { _ in
            composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        }
        var cursor = CMTime.zero
        for url in segments {
            let asset = AVURLAsset(url: url)
            guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else {
                throw RecorderError("A segment contains no video: \(url.lastPathComponent)")
            }
            let range = try await sourceVideo.load(.timeRange)
            try video.insertTimeRange(range, of: sourceVideo, at: cursor)
            let sources = try await asset.loadTracks(withMediaType: .audio)
            for (index, source) in sources.prefix(2).enumerated() {
                let available = try await source.load(.timeRange)
                let intersection = CMTimeRangeGetIntersection(range, otherRange: available)
                if intersection.duration > .zero {
                    try audioTracks[index].insertTimeRange(intersection, of: source,
                                                          at: cursor + intersection.start - range.start)
                }
            }
            cursor = cursor + range.duration
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = audioTracks.map { track in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            // Headroom prevents clipping when both inputs are loud.
            parameters.setVolume(0.7, at: .zero)
            return parameters
        }
        let preset = codec == .h264 ? AVAssetExportPresetHighestQuality : AVAssetExportPresetHEVCHighestQuality
        guard let session = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw RecorderError("MP4 export is unavailable.")
        }
        session.audioMix = mix
        session.shouldOptimizeForNetworkUse = false
        try await session.export(to: output, as: .mp4)
    }
}
