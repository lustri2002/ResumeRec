import AppKit
import AVFoundation
import ScreenCaptureKit
import PausaCore

// Session access is confined to queue; the frame snapshot is protected by lock.
final class CameraSource: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.pausa.camera")
    private let lock = NSLock()
    private var session: AVCaptureSession?
    private var latest: CVPixelBuffer?
    private var lastFrameTime: TimeInterval = 0

    func frame() -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        return ProcessInfo.processInfo.systemUptime - lastFrameTime < 2 ? latest : nil
    }
    func start(deviceID: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                                                  mediaType: .video, position: .unspecified).devices
                    guard let device = deviceID.isEmpty ? AVCaptureDevice.default(for: .video) : devices.first(where: { $0.uniqueID == deviceID }) else {
                        throw RecorderError("The webcam is unavailable. Choose another camera in Settings.")
                    }
                    let session = AVCaptureSession()
                    session.beginConfiguration()
                    if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
                    let input = try AVCaptureDeviceInput(device: device)
                    guard session.canAddInput(input) else { throw RecorderError("Unable to open the webcam.") }
                    session.addInput(input)
                    let output = AVCaptureVideoDataOutput()
                    // Keep the camera's native bi-planar format where available. Both Core Image
                    // and the preview video layer accept it without an intermediate BGRA copy.
                    let formats = output.availableVideoPixelFormatTypes
                    let pixelFormat = [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                       kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                       kCVPixelFormatType_32BGRA].first(where: formats.contains)
                    if let pixelFormat { output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat] }
                    output.alwaysDiscardsLateVideoFrames = true
                    output.setSampleBufferDelegate(self, queue: self.queue)
                    guard session.canAddOutput(output) else { throw RecorderError("Unable to capture webcam video.") }
                    session.addOutput(output)
                    session.commitConfiguration()
                    session.startRunning()
                    self.session = session
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.session?.stopRunning(); self.session = nil
                self.lock.lock(); self.latest = nil; self.lock.unlock()
                continuation.resume()
            }
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        lock.lock(); defer { lock.unlock() }
        latest = CMSampleBufferGetImageBuffer(sampleBuffer)
        lastFrameTime = ProcessInfo.processInfo.systemUptime
    }
}

struct CaptureSource {
    let filter: SCContentFilter
    let pixelSize: CGSize
    let rect: CGRect?
}

enum SourceFactory {
    static func make(preferences p: Preferences) async throws -> CaptureSource {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        if p.mode == .window {
            guard let window = content.windows.first(where: { $0.windowID == p.windowID }) else {
                throw RecorderError("The selected window is unavailable. Choose a window in Settings.")
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let scale = Double(filter.pointPixelScale)
            return CaptureSource(filter: filter, pixelSize: CGSize(width: filter.contentRect.width * scale,
                                                                  height: filter.contentRect.height * scale), rect: nil)
        }
        guard let display = content.displays.first(where: { $0.displayID == p.displayID }) ??
                (p.displayID == 0 ? content.displays.first(where: { $0.displayID == CGMainDisplayID() }) : nil) else {
            throw RecorderError("The selected display is unavailable. Choose a display in Settings.")
        }
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        if p.mode == .region {
            guard let region = p.region else { throw RecorderError("Select a recording region first.") }
            let bounds = filter.contentRect
            let rect = CGRect(x: region.x, y: region.y, width: region.width, height: region.height)
            guard rect.width >= 32, rect.height >= 32,
                  CGRect(origin: .zero, size: bounds.size).contains(rect) else {
                throw RecorderError("The selected region no longer fits this display. Select it again.")
            }
            let scale = Double(filter.pointPixelScale)
            return CaptureSource(filter: filter, pixelSize: CGSize(width: rect.width * scale, height: rect.height * scale), rect: rect)
        }
        return CaptureSource(filter: filter, pixelSize: CGSize(width: filter.contentRect.width * Double(filter.pointPixelScale),
                                                              height: filter.contentRect.height * Double(filter.pointPixelScale)), rect: nil)
    }
}

final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate {
    let camera = CameraSource()
    private let queue = DispatchQueue(label: "local.pausa.capture", qos: .userInitiated, autoreleaseFrequency: .workItem)
    private let timingLock = NSLock()
    private let overlayLock = NSLock()
    private var pendingOverlay: Preferences?
    private var recordingOrigin: CMTime?
    private var stream: SCStream?
    private var timer: DispatchSourceTimer?
    private var writer: SegmentWriter?
    private var screen: CVPixelBuffer?
    private var preferences = Preferences()
    private var startedAt = ProcessInfo.processInfo.systemUptime
    private var reportedFailure = false
    private let backgroundColor = CGColor(gray: 0, alpha: 1)
    var onFailure: ((Error) -> Void)?

    var elapsed: Double {
        timingLock.lock(); let origin = recordingOrigin; timingLock.unlock()
        guard let origin else { return 0 }
        return max(0, (CMClockGetTime(CMClockGetHostTimeClock()) - origin).seconds)
    }

    func start(source: CaptureSource, canvas: CGSize, preferences p: Preferences, url: URL) async throws {
        let config = SCStreamConfiguration()
        config.width = Int(canvas.width); config.height = Int(canvas.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(p.fps))
        config.queueDepth = 5
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = p.showCursor
        config.scalesToFit = true
        config.preservesAspectRatio = true
        config.backgroundColor = backgroundColor
        if let rect = source.rect { config.sourceRect = rect }
        config.capturesAudio = p.systemAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000; config.channelCount = 2
        config.captureMicrophone = p.microphone
        if !p.microphoneID.isEmpty { config.microphoneCaptureDeviceID = p.microphoneID }
        let writer = try SegmentWriter(url: url, size: canvas, preferences: p)
        timingLock.withLock { recordingOrigin = nil }
        overlayLock.withLock { pendingOverlay = nil }
        queue.sync {
            self.writer = writer; self.preferences = p; self.screen = nil
            self.startedAt = ProcessInfo.processInfo.systemUptime; self.reportedFailure = false
        }
        do {
            if p.camera { try await camera.start(deviceID: p.cameraID) }
            let stream = SCStream(filter: source.filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            if p.systemAudio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
            if p.microphone { try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue) }
            self.stream = stream
            try await stream.startCapture()
            queue.sync {
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / p.fps), leeway: .milliseconds(2))
                timer.setEventHandler { [weak self] in self?.renderFrame() }
                self.timer = timer; timer.resume()
            }
        } catch {
            try? await stream?.stopCapture(); stream = nil
            await camera.stop()
            queue.sync { writer.writer.cancelWriting(); self.writer = nil }
            throw error
        }
    }

    func updateOverlay(_ p: Preferences) {
        // Mouse events may arrive faster than the video frame rate. Replace the pending
        // position instead of queueing every intermediate point behind GPU/encoder work.
        overlayLock.withLock { pendingOverlay = p }
    }

    func finish() async throws -> URL {
        let writer: SegmentWriter? = queue.sync {
            timer?.cancel(); timer = nil
            let value = self.writer; self.writer = nil; return value
        }
        // No callback can write after the queue fence above.
        try? await stream?.stopCapture(); stream = nil
        await camera.stop()
        guard let writer else { throw RecorderError("No recording is active.") }
        return try await writer.finish()
    }

    private func renderFrame() {
        guard let writer, !reportedFailure else { return }
        if let p = overlayLock.withLock({ let p = pendingOverlay; pendingOverlay = nil; return p }) {
            preferences.shape = p.shape; preferences.anchor = p.anchor
            preferences.cameraSize = p.cameraSize; preferences.customX = p.customX
            preferences.customY = p.customY; preferences.mirrored = p.mirrored
            preferences.borderWidth = p.borderWidth
        }
        guard let screen else {
            if ProcessInfo.processInfo.systemUptime - startedAt > 8 { fail(RecorderError("The source is not providing video frames. Check that it is visible and screen recording access is allowed.")) }
            return
        }
        let cameraFrame = camera.frame()
        if preferences.camera, cameraFrame == nil, ProcessInfo.processInfo.systemUptime - startedAt > 8 {
            fail(RecorderError("The webcam is not providing video frames. Previously completed segments can still be recovered.")); return
        }
        // A clock-driven renderer keeps the webcam and duration moving on static desktops.
        if preferences.camera && cameraFrame == nil { return }
        writer.append(screen: screen, camera: cameraFrame, at: CMClockGetTime(CMClockGetHostTimeClock()), preferences: preferences)
        timingLock.lock(); recordingOrigin = writer.origin; timingLock.unlock()
        if let error = writer.currentError { fail(error) }
    }
    private func fail(_ error: Error) {
        guard !reportedFailure else { return }
        reportedFailure = true
        DispatchQueue.main.async { [weak self] in self?.onFailure?(error) }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { queue.async { self.fail(error) } }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard sampleBuffer.isValid, let writer else { return }
        switch outputType {
        case .screen:
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let status = attachments.first?[.status] as? Int,
                  status == SCFrameStatus.complete.rawValue else { return }
            screen = CMSampleBufferGetImageBuffer(sampleBuffer)
        case .audio: writer.append(audio: sampleBuffer, kind: 0)
        case .microphone: writer.append(audio: sampleBuffer, kind: 1)
        @unknown default: break
        }
    }
}
