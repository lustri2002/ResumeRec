import AppKit
import AVFoundation
import Combine
import ScreenCaptureKit
import PausaCore

enum RecorderState: String {
    case idle, countdown, starting, recording, pausing, paused, saving
    var title: String {
        switch self {
        case .idle: "Ready"; case .countdown: "Countdown"; case .starting: "Starting"
        case .recording: "Recording"; case .pausing: "Pausing"; case .paused: "Paused"; case .saving: "Saving"
        }
    }
}
struct DeviceChoice: Identifiable { let id: String; let name: String }
struct DisplayChoice: Identifiable { let id: UInt32; let name: String }
struct WindowChoice: Identifiable { let id: UInt32; let name: String; let size: CGSize }
struct RecoveryManifest: Codable {
    let version: Int
    var segments: [String]
    let outputName: String
    let codec: VideoCodec
}

@MainActor
final class RecorderModel: ObservableObject {
    @Published var preferences: Preferences {
        didSet {
            if let encoded = try? JSONEncoder().encode(preferences) { defaults.set(encoded, forKey: "preferences.v1") }
            engine.updateOverlay(preferences)
            if oldValue.camera != preferences.camera || oldValue.cameraID != preferences.cameraID { reconcileSettingsCamera() }
            onPreferencesChanged?()
        }
    }
    @Published private(set) var state: RecorderState = .idle
    @Published private(set) var displays: [DisplayChoice] = []
    @Published private(set) var windows: [WindowChoice] = []
    @Published private(set) var cameras: [DeviceChoice] = []
    @Published private(set) var microphones: [DeviceChoice] = []
    @Published var errorMessage: String?
    @Published private(set) var needsScreenAccess = false
    @Published private(set) var lastOutput: URL?
    @Published private(set) var remainingCountdown = 0
    // Only the AppKit menu bar displays elapsed time. Publishing it on this model
    // invalidated the entire SwiftUI settings tree four times a second, even hidden.
    private(set) var elapsed = 0.0 {
        didSet {
            if Int(oldValue) != Int(elapsed) { onClockChanged?() }
        }
    }
    @Published var shortcutMessage = ""
    @Published private(set) var settingsVisible = false
    @Published private(set) var webcamTabVisible = false
    @Published var showSettingsPreview = true { didSet { reconcileSettingsCamera() } }
    @Published private(set) var previewPlacementMessage: String?
    let settingsCamera = SettingsCameraFeed()
    let engine = CaptureEngine()
    var onPreferencesChanged: (() -> Void)?
    var onStateChanged: (() -> Void)?
    var onClockChanged: (() -> Void)?
    var onScreenAccessRequest: (() -> Void)?
    private let screenAccess: ScreenAccess
    private var timer: Timer?
    private var countdownTask: Task<Void, Never>?
    private var activeSince: TimeInterval?
    private var completedDuration = 0.0
    private var sessionDirectory: URL?
    private var segments: [URL] = []
    private var recordingPreferences: Preferences?
    private var canvas = CGSize(width: 1920, height: 1080)
    private var outputURL: URL?
    private var sleepActivity: NSObjectProtocol?
    private let defaults: UserDefaults
    // Drag updates are transient: no SwiftUI publication, JSON encoding or disk writes per event.
    private var draggedCameraPosition: CGPoint?

    var overlayPreferences: Preferences {
        var p = preferences
        if let position = draggedCameraPosition {
            p.anchor = .custom; p.customX = position.x; p.customY = position.y
        }
        return p
    }
    func updateCameraDrag(position: CGPoint) {
        draggedCameraPosition = position
        engine.updateOverlay(overlayPreferences)
    }
    func finishCameraDrag() {
        guard draggedCameraPosition != nil else { return }
        let final = overlayPreferences
        draggedCameraPosition = nil
        if preferences != final { preferences = final }
    }

    init(defaults: UserDefaults = .standard, screenAccess: ScreenAccess? = nil) {
        self.defaults = defaults
        self.screenAccess = screenAccess ?? ScreenAccess()
        if let data = defaults.data(forKey: "preferences.v1"),
           let saved = try? JSONDecoder().decode(Preferences.self, from: data) { preferences = saved.sanitized() }
        else { preferences = Preferences() }
        engine.onFailure = { [weak self] error in
            Task { @MainActor in
                guard let self, self.state == .recording else { return }
                await self.pause()
                self.errorMessage = error.localizedDescription
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.state == .recording { self.updateElapsed(self.completedDuration + self.engine.elapsed) }
                else if self.state == .paused { self.updateElapsed(self.completedDuration) }
            }
        }
        refreshDevices()
        refreshDisplays()
    }

    func updateElapsed(_ value: TimeInterval) {
        elapsed = value
    }

    var canChangeSource: Bool { state == .idle || state == .paused }
    var canChangeOutput: Bool { state == .idle }
    var activeCanvas: CGSize { canvas }
    var isConfiguringWebcam: Bool {
        settingsVisible && webcamTabVisible && showSettingsPreview &&
        (state == .idle || state == .paused || state == .recording)
    }
    func updatePreviewPlacementMessage(_ message: String?) {
        if previewPlacementMessage != message { previewPlacementMessage = message }
    }
    func setSettingsVisible(_ visible: Bool) {
        guard settingsVisible != visible else { return }
        settingsVisible = visible
        reconcileSettingsCamera()
    }
    func setWebcamTabVisible(_ visible: Bool) {
        guard webcamTabVisible != visible else { return }
        webcamTabVisible = visible
        reconcileSettingsCamera()
    }
    private func reconcileSettingsCamera() {
        let wantsCamera = isConfiguringWebcam && preferences.camera && canChangeSource
        settingsCamera.request(deviceID: wantsCamera ? preferences.cameraID : nil)
    }
    var timeLabel: String {
        let seconds = Int(elapsed)
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
    var temporaryDirectory: URL? { sessionDirectory }

    private func transition(_ next: RecorderState) {
        finishCameraDrag()
        state = next
        reconcileSettingsCamera()
        onStateChanged?()
    }

    func refreshDevices() {
        cameras = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                                   mediaType: .video, position: .unspecified).devices.map { DeviceChoice(id: $0.uniqueID, name: $0.localizedName) }
        microphones = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio,
                                                       position: .unspecified).devices.map { DeviceChoice(id: $0.uniqueID, name: $0.localizedName) }
    }
    func refreshDisplays() {
        displays = NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { return nil }
            return DisplayChoice(id: id, name: screen.localizedName)
        }
        if preferences.displayID == 0 { preferences.displayID = CGMainDisplayID() }
    }
    func refreshWindows() async throws {
        try requireScreenAccess()
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            windows = content.windows.filter {
                $0.windowLayer == 0 && $0.frame.width > 40 && $0.frame.height > 40 &&
                $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier
            }.map { WindowChoice(id: $0.windowID, name: "\($0.owningApplication?.applicationName ?? "App") — \($0.title ?? "Window")", size: $0.frame.size) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch {
            if ScreenAccess.isPermissionError(error) { throw ScreenAccessRequired() }
            throw RecorderError("Unable to list windows.\n\n\(error.localizedDescription)")
        }
    }

    private func requireScreenAccess() throws {
        do {
            try screenAccess.require { onScreenAccessRequest?() }
            needsScreenAccess = false
        } catch {
            needsScreenAccess = true
            throw error
        }
    }

    func recheckScreenAccess() {
        if needsScreenAccess && screenAccess.isAuthorized { needsScreenAccess = false }
    }

    func presentError(_ error: Error) {
        if ScreenAccess.isPermissionError(error) {
            needsScreenAccess = true
        } else {
            errorMessage = error.localizedDescription
        }
    }

    func openScreenAccessSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"; panel.message = "Where would you like to save your recordings?"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { preferences.folder = url.path }
    }

    func start() {
        guard state == .idle else { return }
        errorMessage = nil
        guard !preferences.folder.isEmpty else { errorMessage = "Choose a save folder in Settings first."; return }
        transition(.starting)
        countdownTask = Task {
            do {
                try await checkPermissions()
                let source = try await SourceFactory.make(preferences: preferences)
                let snapshot = preferences.sanitized()
                recordingPreferences = snapshot
                canvas = Geometry.canvas(source: source.pixelSize, maxHeight: snapshot.resolution)
                remainingCountdown = snapshot.countdown
                if remainingCountdown > 0 {
                    transition(.countdown)
                    while remainingCountdown > 0 {
                        try await Task.sleep(for: .seconds(1))
                        remainingCountdown -= 1
                    }
                }
                try Task.checkCancellation()
                transition(.starting)
                let folder = URL(fileURLWithPath: snapshot.folder, isDirectory: true)
                guard FileManager.default.isWritableFile(atPath: folder.path) else { throw RecorderError("The selected folder is not writable or is no longer available.") }
                let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
                let identifier = UUID().uuidString.prefix(6)
                outputURL = folder.appendingPathComponent("ResumeRec_\(formatter.string(from: Date()))_\(identifier).mp4")
                let directory = folder.appendingPathComponent(".ResumeRec-session-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                sessionDirectory = directory; segments = []; completedDuration = 0; elapsed = 0
                try saveManifest()
                try await startSegment(source: source)
            } catch is CancellationError { transition(.idle) }
            catch { presentError(error); transition(.idle) }
            countdownTask = nil
        }
    }

    func cancelCountdown() {
        guard state == .countdown else { return }
        countdownTask?.cancel(); countdownTask = nil
        remainingCountdown = 0; transition(.idle)
    }

    private func checkPermissions() async throws {
        try requireScreenAccess()
        if preferences.camera, !(await AVCaptureDevice.requestAccess(for: .video)) {
            throw RecorderError("Allow camera access in System Settings → Privacy & Security → Camera.")
        }
        if preferences.microphone, !(await AVCaptureDevice.requestAccess(for: .audio)) {
            throw RecorderError("Allow microphone access in System Settings → Privacy & Security → Microphone.")
        }
        if preferences.microphone, !preferences.microphoneID.isEmpty,
           !microphones.contains(where: { $0.id == preferences.microphoneID }) {
            throw RecorderError("The selected microphone is unavailable. Choose another microphone.")
        }
    }

    private func startSegment(source: CaptureSource) async throws {
        await settingsCamera.stop()
        guard let sessionDirectory, let fixed = recordingPreferences else { throw RecorderError("Recording session unavailable.") }
        var current = preferences.sanitized()
        current.fps = fixed.fps; current.codec = fixed.codec; current.bitRateMbps = fixed.bitRateMbps
        let url = sessionDirectory.appendingPathComponent("segment-\(UUID().uuidString).mov")
        try await engine.start(source: source, canvas: canvas, preferences: current, url: url)
        activeSince = ProcessInfo.processInfo.systemUptime
        sleepActivity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .idleDisplaySleepDisabled], reason: "ResumeRec recording in progress")
        transition(.recording)
    }

    func pause() async {
        guard state == .recording else { return }
        transition(.pausing)
        do {
            try await finishActiveSegment()
        } catch { errorMessage = "\(error.localizedDescription)\nCompleted segments remain in the temporary folder." }
        transition(.paused)
    }
    private func finishActiveSegment() async throws {
        freezeClock()
        let segment = try await engine.finish()
        segments.append(segment)
        try saveManifest()
        let asset = AVURLAsset(url: segment)
        completedDuration += (try? await asset.load(.duration).seconds) ?? 0
        elapsed = completedDuration
    }
    func resume() async {
        guard state == .paused else { return }
        transition(.starting)
        do {
            refreshDevices()
            try await checkPermissions()
            let source = try await SourceFactory.make(preferences: preferences)
            try await startSegment(source: source)
        } catch { presentError(error); transition(.paused) }
    }
    func stop() async {
        guard state == .recording || state == .paused else { return }
        let wasRecording = state == .recording
        transition(.saving)
        if wasRecording {
            do { try await finishActiveSegment() }
            catch {
                errorMessage = "\(error.localizedDescription)\nPrevious segments remain available. Choose Stop & Save to save the completed segments."
                transition(.paused); return
            }
        }
        guard !segments.isEmpty, let outputURL, let fixed = recordingPreferences else {
            errorMessage = "There are no completed segments to save."; transition(.idle); return
        }
        do {
            let staging = outputURL.deletingPathExtension().appendingPathExtension("partial.mp4")
            if FileManager.default.fileExists(atPath: staging.path) { try FileManager.default.removeItem(at: staging) }
            try await MovieExporter.export(segments: segments, to: staging, codec: fixed.codec)
            try FileManager.default.moveItem(at: staging, to: outputURL)
            lastOutput = outputURL
            if let sessionDirectory { try? FileManager.default.removeItem(at: sessionDirectory) }
            self.sessionDirectory = nil; segments = []; transition(.idle)
        } catch {
            errorMessage = "Unable to save: \(error.localizedDescription)\nYour segments have been preserved. Choose Stop & Save to try again."
            transition(.paused)
        }
    }

    private func freezeClock() {
        activeSince = nil
        if let sleepActivity { ProcessInfo.processInfo.endActivity(sleepActivity); self.sleepActivity = nil }
    }
    private func saveManifest() throws {
        guard let sessionDirectory, let outputURL, let recordingPreferences else { return }
        let manifest = RecoveryManifest(version: 1, segments: segments.map(\.lastPathComponent), outputName: outputURL.lastPathComponent,
                                        codec: recordingPreferences.codec)
        try JSONEncoder().encode(manifest).write(to: sessionDirectory.appendingPathComponent("session.json"), options: .atomic)
    }

    func recover() async {
        guard state == .idle else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.showsHiddenFiles = true
        panel.message = "Select a .ResumeRec-session folder, or a .Pausa-session folder from an earlier version, inside your recordings folder."
        if !preferences.folder.isEmpty { panel.directoryURL = URL(fileURLWithPath: preferences.folder) }
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        transition(.saving)
        do {
            let manifest = try JSONDecoder().decode(RecoveryManifest.self, from: Data(contentsOf: folder.appendingPathComponent("session.json")))
            guard manifest.version == 1 else { throw RecorderError("Unsupported recovery format version.") }
            // Scan finalized movie files as well: a crash can precede the manifest write.
            let candidates = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])
                .filter { $0.pathExtension == "mov" }
                .sorted { ((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) <
                          ((try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) }
            let known = manifest.segments.compactMap { name in candidates.first { $0.lastPathComponent == name } }
            let remaining = candidates.filter { !known.contains($0) }
            var valid: [URL] = []
            for candidate in known + remaining {
                let asset = AVURLAsset(url: candidate)
                if let duration = try? await asset.load(.duration), duration.isNumeric, duration.seconds > 0 { valid.append(candidate) }
            }
            guard !valid.isEmpty else { throw RecorderError("No completed segments could be recovered. A segment interrupted while being written may be unreadable.") }
            let recovered = folder.deletingLastPathComponent().appendingPathComponent("ResumeRec_recovered_\(UUID().uuidString.prefix(8)).mp4")
            try await MovieExporter.export(segments: valid, to: recovered, codec: manifest.codec)
            lastOutput = recovered
        } catch { errorMessage = error.localizedDescription }
        transition(.idle)
    }
}
