import SwiftUI
import PausaCore

struct SettingsView: View {
    static let windowSize = CGSize(width: 440, height: 640)
    @ObservedObject var model: RecorderModel
    var selectRegion: () -> Void
    // Explicit wrapper avoids the SDK 27 State macro when building with Command Line Tools.
    private typealias PageState = SwiftUI.State<Page>
    @PageState private var selectedPage: Page = .recording
    @FocusState private var focusedPage: Page?

    private enum Page: String, CaseIterable {
        case recording = "Recording", webcam = "Webcam", output = "Output", controls = "Controls"
        var symbol: String {
            switch self {
            case .recording: "display"; case .webcam: "video"
            case .output: "folder"; case .controls: "slider.horizontal.3"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            navigation
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if model.needsScreenAccess { screenAccessNotice }
                    switch selectedPage {
                    case .recording: capture
                    case .webcam: webcam
                    case .output: output
                    case .controls: controls
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .id(selectedPage)
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            footer
        }
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
        .toggleStyle(SettingsSwitchStyle())
        .controlSize(.small)
        .alert("ResumeRec", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let icon = BrandAssets.appIcon {
                Image(nsImage: icon).resizable().frame(width: 30, height: 30)
            }
            Text("ResumeRec").font(.system(size: 16, weight: .semibold))
            Spacer(minLength: 12)
            HStack(spacing: 5) {
                Circle().fill(model.state == .recording ? Color.red : Color.secondary.opacity(0.7))
                    .frame(width: 5, height: 5)
                Text(model.state.title).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 12)
    }

    private var navigation: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Page.allCases, id: \.self) { page in
                    Button {
                        selectedPage = page
                        focusedPage = page
                    } label: {
                        VStack(spacing: 0) {
                            HStack(spacing: 5) {
                                Image(systemName: page.symbol).font(.system(size: 12))
                                Text(page.rawValue).font(.system(size: 11, weight: .medium))
                            }
                            .frame(maxWidth: .infinity).padding(.top, 5).padding(.bottom, 12)
                            .foregroundStyle(selectedPage == page ? Color.primary : Color.secondary)
                            Capsule()
                                .fill(selectedPage == page ? Color.accentColor : Color.clear)
                                .frame(height: 2).padding(.horizontal, 12)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focused($focusedPage, equals: page)
                    .focusEffectDisabled()
                    .accessibilityLabel(page.rawValue)
                    .accessibilityValue(selectedPage == page ? "Selected" : "")
                }
            }.padding(.horizontal, 18)
            Divider()
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                switch model.state {
                case .idle:
                    primaryButton("Start Recording", symbol: "record.circle") { model.start() }
                case .paused:
                    primaryButton("Resume", symbol: "play.fill") { Task { await model.resume() } }
                    Button("Stop & Save") { Task { await model.stop() } }.controlSize(.large)
                case .recording:
                    Button("Pause") { Task { await model.pause() } }.controlSize(.large)
                    primaryButton("Stop & Save", symbol: "stop.fill") { Task { await model.stop() } }
                case .countdown:
                    Text("Starting in \(model.remainingCountdown)…").foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { model.cancelCountdown() }.controlSize(.large)
                case .starting, .pausing, .saving:
                    ProgressView().controlSize(.small)
                    Text("\(model.state.title)…").foregroundStyle(.secondary)
                    Spacer()
                }
            }.frame(minHeight: 32)
            Label("Saved automatically · Everything stays on your Mac", systemImage: "lock")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(.horizontal, 18).padding(.vertical, 12)
    }

    private func primaryButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: symbol).frame(maxWidth: .infinity) }
            .buttonStyle(.borderedProminent).controlSize(.large)
    }

    private var screenAccessNotice: some View {
        card("Screen access", symbol: "lock.shield") {
            note("Allow ResumeRec in the macOS prompt or in Privacy & Security → Screen & System Audio Recording. Then try again; reopen the app if macOS asks.")
            Button("Open System Settings…") { model.openScreenAccessSettings() }
        }
    }

    private var capture: some View {
        Group {
            card("Source", symbol: "display") {
                Picker("Capture", selection: $model.preferences.mode) {
                    ForEach(CaptureMode.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().controlSize(.regular)
                if model.preferences.mode == .window {
                    refreshingPicker("Window", selection: $model.preferences.windowID,
                                     options: windowOptions, placeholder: "Choose a window") {
                        try await model.refreshWindows()
                        return windowOptions
                    }
                } else {
                    refreshingPicker("Display", selection: $model.preferences.displayID,
                                     options: displayOptions, placeholder: "Choose a display") {
                        model.refreshDisplays()
                        return displayOptions
                    }.onChange(of: model.preferences.displayID) { _, _ in model.preferences.region = nil }
                }
                if model.preferences.mode == .region {
                    HStack {
                        Button("Select Region…", action: selectRegion)
                        Spacer()
                        if let r = model.preferences.region { Text("\(Int(r.width)) × \(Int(r.height)) pt").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Divider()
                Toggle("Show cursor", isOn: $model.preferences.showCursor)
            }.disabled(!model.canChangeSource)
            card("Audio", symbol: "waveform") {
                Toggle("System audio", isOn: $model.preferences.systemAudio)
                Divider()
                Toggle("Microphone", isOn: $model.preferences.microphone)
                if model.preferences.microphone {
                    refreshingPicker("Input", selection: $model.preferences.microphoneID,
                                     options: microphoneOptions, placeholder: "Microphone unavailable") {
                        model.refreshDevices()
                        return microphoneOptions
                    }
                }
            }.disabled(!model.canChangeSource)
            note("Change sources and devices while paused. Video dimensions stay fixed.")
        }
    }

    private var webcam: some View {
        Group {
            card("Webcam", symbol: "video") {
                Toggle("Include in recording", isOn: $model.preferences.camera).disabled(!model.canChangeSource)
                if model.preferences.camera {
                    refreshingPicker("Camera", selection: $model.preferences.cameraID,
                                     options: cameraOptions, placeholder: "Webcam unavailable") {
                        model.refreshDevices()
                        return cameraOptions
                    }.disabled(!model.canChangeSource)
                }
                Divider()
                Toggle("Show preview while recording", isOn: $model.preferences.showPreview)
                note("The webcam stays in your video even when its preview is hidden.")
            }
            card("Life-size preview", symbol: "arrow.up.left.and.arrow.down.right") {
                WebcamSettingsPreview(model: model, feed: model.settingsCamera)
            }
            card("Appearance", symbol: "slider.horizontal.3") {
                row("Shape") {
                    Picker("Shape", selection: $model.preferences.shape) {
                        ForEach(CameraShape.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden()
                }
                row("Position") {
                    Picker("Position", selection: $model.preferences.anchor) {
                        ForEach(Anchor.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden()
                }
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Size").font(.callout)
                    Slider(value: $model.preferences.cameraSize, in: 0.10...0.45)
                        .accessibilityLabel("Webcam size")
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("White border").font(.callout)
                        Spacer()
                        Text("\(Int(model.preferences.borderWidth))").monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: $model.preferences.borderWidth, in: 0...12, step: 1)
                        .accessibilityLabel("White border width")
                }
                Toggle("Mirror image", isOn: $model.preferences.mirrored)
                note("Changes appear immediately in the floating preview. Drag it to reposition.")
            }
        }
        .onAppear { model.setWebcamTabVisible(true) }
        .onDisappear { model.setWebcamTabVisible(false) }
    }

    private var output: some View {
        Group {
            card("Save location", symbol: "folder") {
                Text(model.preferences.folder.isEmpty ? "Choose a folder for your recordings" : model.preferences.folder)
                    .font(.callout).lineLimit(3).truncationMode(.middle).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Choose Folder…") { model.chooseFolder() }.disabled(!model.canChangeOutput)
                note("Timestamped MP4 files, saved when you stop. Pauses are removed automatically.")
            }
            card("Video quality", symbol: "sparkles.tv") {
                row("Resolution") {
                    Picker("Resolution", selection: $model.preferences.resolution) {
                        Text("Original").tag(0); Text("720p").tag(720); Text("1080p").tag(1080)
                        Text("1440p").tag(1440); Text("2160p / 4K").tag(2160)
                    }.labelsHidden()
                }
                row("Frame rate") {
                    Picker("Frame rate", selection: $model.preferences.fps) {
                        ForEach([24, 30, 60], id: \.self) { Text("\($0) fps").tag($0) }
                    }.labelsHidden()
                }
                row("Codec") {
                    Picker("Codec", selection: $model.preferences.codec) {
                        ForEach(VideoCodec.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden()
                }
                Divider()
                Stepper(value: $model.preferences.bitRateMbps, in: 2...80, step: 2) {
                    Text("Bitrate: \(model.preferences.bitRateMbps) Mbps").frame(maxWidth: .infinity, alignment: .leading)
                }
                note("Bitrate applies to captured segments. Final export uses the codec’s highest-quality preset.")
            }.disabled(!model.canChangeOutput)
            card("Recovery", symbol: "arrow.counterclockwise") {
                Button("Recover a Session…") { Task { await model.recover() } }.disabled(model.state != .idle)
                if let folder = model.temporaryDirectory {
                    Button("Show Temporary Folder") { NSWorkspace.shared.open(folder) }
                }
            }
        }
    }

    private var controls: some View {
        Group {
            card("Startup", symbol: "timer") {
                Stepper(value: $model.preferences.countdown, in: 0...15) {
                    Text(model.preferences.countdown == 0 ? "Countdown off" : "Countdown: \(model.preferences.countdown) seconds")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }.disabled(!model.canChangeOutput)
            card("Keyboard shortcuts", symbol: "keyboard") {
                Toggle("Enable shortcuts", isOn: $model.preferences.hotkeysEnabled)
                Divider()
                hotkey("Start", selection: $model.preferences.startKey)
                hotkey("Pause / Resume", selection: $model.preferences.pauseKey)
                hotkey("Stop & Save", selection: $model.preferences.stopKey)
                note("Hold ⌃ Control + ⌥ Option + ⌘ Command. Choose three different letters.")
                if !model.shortcutMessage.isEmpty { Text(model.shortcutMessage).font(.caption).foregroundStyle(.red) }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("ResumeRec 0.2.8 · Development preview").font(.caption.weight(.medium))
                note("No account, tracking or online services.")
            }.padding(.horizontal, 2)
        }
    }

    private func card<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.06), lineWidth: 1))
        .pickerStyle(.menu)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func hotkey(_ title: String, selection: Binding<String>) -> some View {
        row(title) {
            Picker(title, selection: selection) {
                ForEach(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ").map(String.init), id: \.self) { Text("⌃⌥⌘ " + $0).tag($0) }
            }.labelsHidden().disabled(!model.preferences.hotkeysEnabled)
        }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            content()
        }
    }

    private var windowOptions: [PickerOption<UInt32>] {
        model.windows.map { PickerOption(value: $0.id, title: $0.name) }
    }
    private var displayOptions: [PickerOption<UInt32>] {
        model.displays.map { PickerOption(value: $0.id, title: $0.name) }
    }
    private var microphoneOptions: [PickerOption<String>] {
        [PickerOption(value: "", title: "System default")] + model.microphones.map { PickerOption(value: $0.id, title: $0.name) }
    }
    private var cameraOptions: [PickerOption<String>] {
        [PickerOption(value: "", title: "System default")] + model.cameras.map { PickerOption(value: $0.id, title: $0.name) }
    }
    private func refreshingPicker<Value: Hashable>(
        _ title: String, selection: Binding<Value>, options: [PickerOption<Value>], placeholder: String,
        load: @escaping @MainActor () async throws -> [PickerOption<Value>]
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            RefreshingPicker(label: title, selection: selection, options: options, placeholder: placeholder,
                             loadOptions: load, onError: { model.presentError($0) })
                .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

private struct SettingsSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(isOn: configuration.$isOn) {
            configuration.label.frame(maxWidth: .infinity, alignment: .leading)
        }.toggleStyle(.switch)
    }
}
