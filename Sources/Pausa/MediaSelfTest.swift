import AVFoundation
import CoreImage
import PausaCore

enum MediaSelfTest {
    /// Synthetic media only: no desktop, microphone, or camera access.
    static func run() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pausa-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        var preferences = Preferences()
        preferences.microphone = true; preferences.systemAudio = true; preferences.camera = true
        preferences.bitRateMbps = 2
        let size = CGSize(width: 320, height: 240)
        let camera = try buffer(size: CGSize(width: 80, height: 80), color: CIColor(red: 0, green: 1, blue: 0))
        var segments: [URL] = []
        for segment in 0..<2 {
            let writer = try SegmentWriter(url: folder.appendingPathComponent("part-\(segment).mov"), size: size, preferences: preferences)
            let screen = try buffer(size: size, color: segment == 0 ? CIColor(red: 1, green: 0, blue: 0) : CIColor(red: 0, green: 0, blue: 1))
            // The second segment's source clock is 11 seconds later: only 2 seconds should remain.
            let origin = CMTime(seconds: 100 + Double(segment) * 11, preferredTimescale: 48_000)
            for frame in 0..<30 {
                let time = origin + CMTime(value: Int64(frame), timescale: 30)
                writer.append(screen: screen, camera: camera, at: time, preferences: preferences)
                writer.append(audio: try audio(at: time, frequency: 440), kind: 0)
                writer.append(audio: try audio(at: time, frequency: 880), kind: 1)
                // Let the real-time encoder drain; this is a media integration test.
                try await Task.sleep(for: .milliseconds(34))
            }
            segments.append(try await writer.finish())
        }
        let output = folder.appendingPathComponent("result.mp4")
        try await MovieExporter.export(segments: segments, to: output, codec: .h264)
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        guard abs(duration - 2) < 0.12 else { throw RecorderError("Pause was not removed: duration \(duration)") }
        guard try await asset.loadTracks(withMediaType: .video).count == 1 else { throw RecorderError("Video track missing.") }
        guard try await asset.loadTracks(withMediaType: .audio).count == 1 else { throw RecorderError("The mix must produce exactly one audio track.") }
        let generator = AVAssetImageGenerator(asset: asset)
        let first = try await generator.image(at: CMTime(seconds: 0.4, preferredTimescale: 600)).image
        let second = try await generator.image(at: CMTime(seconds: 1.4, preferredTimescale: 600)).image
        try assertColor(first, point: CGPoint(x: 30, y: 30), expected: 0)
        try assertColor(second, point: CGPoint(x: 30, y: 30), expected: 2)
        let overlay = Geometry.cameraRect(in: size, preferences: preferences)
        try assertColor(first, point: CGPoint(x: overlay.midX, y: overlay.midY), expected: 1)
        try await assertAudioMix(asset)
        print("Verified: two segments, 10-second pause removed, continuous video, baked webcam, single mixed audio track (440 + 880 Hz).")
        try await assertOptimizedPaths(in: folder)
    }
    private static func buffer(size: CGSize, color: CIColor, yuv: Bool = false) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let format = yuv ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_32BGRA
        let status = CVPixelBufferCreate(nil, Int(size.width), Int(size.height), format,
                                        [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw RecorderError("Unable to create the test buffer.") }
        CIContext().render(CIImage(color: color).cropped(to: CGRect(origin: .zero, size: size)), to: buffer)
        return buffer
    }
    private static func assertOptimizedPaths(in folder: URL) async throws {
        let size = CGSize(width: 320, height: 240)
        let screen = try buffer(size: size, color: CIColor(red: 1, green: 0, blue: 0))
        let camera = try buffer(size: CGSize(width: 80, height: 80), color: CIColor(red: 0, green: 1, blue: 0), yuv: true)
        let changedCamera = try buffer(size: CGSize(width: 80, height: 80), color: CIColor(red: 0, green: 0, blue: 1), yuv: true)
        var p = Preferences(); p.camera = false; p.microphone = false; p.systemAudio = false
        let bottom = Geometry.cameraRect(in: size, preferences: p)
        let writer = try SegmentWriter(url: folder.appendingPathComponent("optimized-paths.mov"), size: size, preferences: p)
        for frame in 0..<120 {
            // Identical retained inputs must keep advancing time. Style and input changes
            // must invalidate the cache, while camera-off frames bypass compositing.
            p.camera = frame >= 30
            if frame >= 60 { p.anchor = .topLeft }
            writer.append(screen: screen, camera: frame >= 90 ? changedCamera : camera,
                          at: CMTime(value: Int64(frame), timescale: 30), preferences: p)
            try await Task.sleep(for: .milliseconds(34))
        }
        let asset = AVURLAsset(url: try await writer.finish())
        let duration = try await asset.load(.duration).seconds
        guard abs(duration - 4) < 0.1 else { throw RecorderError("Unchanged frames lost duration: \(duration)") }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let top = Geometry.cameraRect(in: size, preferences: p)
        for (second, bottomColor, topColor) in [(0.4, 0, 0), (1.4, 1, 0), (2.4, 0, 1), (3.4, 0, 2)] {
            let image = try await generator.image(at: CMTime(seconds: second, preferredTimescale: 600)).image
            try assertColor(image, point: CGPoint(x: bottom.midX, y: bottom.midY), expected: bottomColor)
            try assertColor(image, point: CGPoint(x: top.midX, y: top.midY), expected: topColor)
        }
        print("Verified: direct screen path, native YUV camera, repeated-frame duration, live position change, changed camera frame.")
    }
    private static func assertColor(_ image: CGImage, point: CGPoint, expected: Int) throws {
        var rgba = [UInt8](repeating: 0, count: 4)
        CIContext().render(CIImage(cgImage: image), toBitmap: &rgba, rowBytes: 4,
                           bounds: CGRect(x: point.x, y: point.y, width: 1, height: 1), format: .RGBA8,
                           colorSpace: CGColorSpaceCreateDeviceRGB())
        guard rgba[expected] > 170 else { throw RecorderError("Unexpected video pixel: \(rgba)") }
    }
    private static func audio(at time: CMTime, frequency: Double) throws -> CMSampleBuffer {
        let frames = 1600
        var samples = [Int16](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            let value = Int16(sin(2 * .pi * frequency * (time.seconds + Double(frame) / 48_000)) * 6000)
            samples[frame * 2] = value; samples[frame * 2 + 1] = value
        }
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                               mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                        magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        var block: CMBlockBuffer?
        let bytes = samples.count * 2
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block)
        guard let block, let format else { throw RecorderError("Test audio buffer unavailable.") }
        samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var result: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: frames,
                                               sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                               sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &result)
        guard status == noErr, let result else { throw RecorderError("Test CMSampleBuffer unavailable.") }
        return result
    }
    private static func assertAudioMix(_ asset: AVAsset) async throws {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw RecorderError("Audio track missing.") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2
        ])
        reader.add(output); reader.startReading()
        var samples: [Double] = []
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            let length = CMBlockBufferGetDataLength(block)
            var pcm = [Int16](repeating: 0, count: length / 2)
            pcm.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            samples.append(contentsOf: stride(from: 0, to: pcm.count, by: 2).map { Double(pcm[$0]) })
        }
        guard reader.status == .completed, !samples.isEmpty else { throw RecorderError("Audio decoding failed.") }
        for frequency in [440.0, 880.0] {
            var sine = 0.0, cosine = 0.0
            for (index, value) in samples.enumerated() {
                let angle = 2 * .pi * frequency * Double(index) / 48_000
                sine += value * sin(angle); cosine += value * cos(angle)
            }
            let amplitude = hypot(sine, cosine) / Double(samples.count)
            guard amplitude > 500 else { throw RecorderError("Audio source \(frequency) Hz missing from the mix: \(amplitude)") }
        }
    }
}
