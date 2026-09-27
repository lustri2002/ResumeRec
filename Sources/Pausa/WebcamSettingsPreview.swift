import AppKit
import AVFoundation
import Combine
import CoreImage
import SwiftUI
import PausaCore

/// Owns the camera only while configuring it; recording continues to own its own source.
@MainActor
final class SettingsCameraFeed: ObservableObject {
    enum State { case off, starting, ready, unavailable(String) }
    @Published private(set) var state: State = .off
    let camera = CameraSource()
    private var requestedDevice: String?
    private var transition: Task<Void, Never>?

    func request(deviceID: String?) {
        guard requestedDevice != deviceID else { return }
        requestedDevice = deviceID
        let previous = transition
        previous?.cancel()
        state = deviceID == nil ? .off : .starting
        transition = Task { [weak self] in
            // Serialize stop/start even if device changes or the view closes during startup.
            await previous?.value
            guard let self else { return }
            await self.camera.stop()
            guard !Task.isCancelled, let deviceID else { return }
            let allowed = await AVCaptureDevice.requestAccess(for: .video)
            guard !Task.isCancelled else { return }
            guard allowed else {
                self.state = .unavailable("Allow camera access in System Settings → Privacy & Security → Camera.")
                return
            }
            do {
                try await self.camera.start(deviceID: deviceID)
                if Task.isCancelled { await self.camera.stop(); return }
                self.state = .ready
            } catch {
                if !Task.isCancelled { self.state = .unavailable(error.localizedDescription) }
            }
        }
    }

    func stop() async {
        request(deviceID: nil)
        await transition?.value
    }
}

struct WebcamSettingsPreview: View {
    @ObservedObject var model: RecorderModel
    @ObservedObject var feed: SettingsCameraFeed

    private var caption: String {
        if !model.showSettingsPreview { return "Enable the preview to adjust the webcam directly on your desktop." }
        if let message = model.previewPlacementMessage { return message }
        if !model.preferences.camera { return "Sample image at recording size. Enable the webcam to see yourself." }
        if model.state == .recording { return "Live recording feed, shown at its actual size and position." }
        switch feed.state {
        case .off: return "No recording in progress."
        case .starting: return "Starting webcam…"
        case .ready: return "Live webcam at recording size. No recording in progress."
        case .unavailable(let message): return message
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Show preview while configuring", isOn: $model.showSettingsPreview)
            Text(caption).font(.caption).foregroundStyle(.secondary)
            Text("Adjust the webcam directly on your recording source. Drag it to change its position.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
