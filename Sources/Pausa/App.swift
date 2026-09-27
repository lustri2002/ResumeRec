import AppKit
import SwiftUI
import Combine

@main
enum ResumeRecApp {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--permission-self-test") {
            Task { @MainActor in
                do { try await PermissionSelfTest.run(); print("PERMISSION SELF TEST PASSED"); exit(0) }
                catch { fputs("PERMISSION SELF TEST FAILED: \(error)\n", stderr); exit(1) }
            }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--drag-self-test") {
            do { try DragSelfTest.run(); print("DRAG SELF TEST PASSED"); exit(0) }
            catch { fputs("DRAG SELF TEST FAILED: \(error)\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--media-self-test") {
            Task {
                do { try await MediaSelfTest.run(); print("MEDIA SELF TEST PASSED"); exit(0) }
                catch { fputs("MEDIA SELF TEST FAILED: \(error)\n", stderr); exit(1) }
            }
            dispatchMain()
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private let model = RecorderModel()
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var cameraPreview: CameraPreview!
    private let regionSelector = RegionSelector()
    private let hotkeys = Hotkeys()
    private var shortcutSignature = ""
    private var statusSignature = ""
    private var subscriptions = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem(title: "ResumeRec", action: nil, keyEquivalent: "")
        let appMenu = NSMenu()
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit ResumeRec", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        appMenu.addItem(quitItem)
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        NSApp.mainMenu = mainMenu
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu(); menu.delegate = self; statusItem.menu = menu
        cameraPreview = CameraPreview(model: model)
        model.onScreenAccessRequest = { [weak self] in self?.showSettings() }
        model.onPreferencesChanged = { [weak self] in self?.updateHotkeys() }
        model.onClockChanged = { [weak self] in self?.refreshStatus() }
        model.onStateChanged = { [weak self] in
            guard let self else { return }
            if self.model.state == .countdown || self.model.state == .recording {
                self.model.setSettingsVisible(false)
                self.settingsWindow?.orderOut(nil)
            }
        }
        model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshStatus() }
        }.store(in: &subscriptions)
        model.$errorMessage.compactMap { $0 }.sink { [weak self] _ in
            DispatchQueue.main.async { self?.showSettings() }
        }.store(in: &subscriptions)
        hotkeys.action = { [weak self] id in
            Task { @MainActor in
                guard let self else { return }
                switch id { case 0: self.model.start(); case 1: self.pauseResume(); case 2: self.stop(); default: break }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        updateHotkeys(); refreshStatus()
        if model.preferences.folder.isEmpty { showSettings() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }
    private func updateHotkeys() {
        let p = model.preferences
        let signature = "\(p.hotkeysEnabled)-\(p.startKey)-\(p.pauseKey)-\(p.stopKey)"
        guard signature != shortcutSignature else { return }
        shortcutSignature = signature
        model.shortcutMessage = hotkeys.configure(p)
    }
    private func refreshStatus() {
        guard let button = statusItem.button else { return }
        let signature = "\(model.state.rawValue)-\(model.timeLabel)-\(model.remainingCountdown)"
        guard statusSignature != signature else { return }
        statusSignature = signature
        let symbol: String
        switch model.state {
        case .recording: symbol = "record.circle.fill"
        case .paused, .pausing: symbol = "pause.circle.fill"
        case .saving: symbol = "arrow.down.circle"
        default: symbol = "record.circle"
        }
        if model.state == .idle, let image = BrandAssets.menuBar {
            button.image = image
        } else {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "ResumeRec: \(model.state.title)")
        }
        button.contentTintColor = model.state == .recording ? .systemRed : nil
        switch model.state {
        case .recording, .paused, .pausing: button.title = " " + model.timeLabel
        case .countdown: button.title = " \(model.remainingCountdown)"
        case .saving: button.title = " Saving…"
        case .starting: button.title = " Starting…"
        default: button.title = ""
        }
        button.toolTip = "ResumeRec — \(model.state.title)"
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let header = NSMenuItem(title: "ResumeRec · \(model.state.title)", action: nil, keyEquivalent: "")
        header.isEnabled = false; menu.addItem(header); menu.addItem(.separator())
        switch model.state {
        case .idle: item("Start Recording", #selector(start), in: menu)
        case .recording: item("Pause Recording", #selector(pauseResume), in: menu); item("Stop & Save", #selector(stop), in: menu)
        case .paused: item("Resume Recording", #selector(pauseResume), in: menu); item("Stop & Save", #selector(stop), in: menu)
        case .countdown: item("Cancel Countdown", #selector(cancel), in: menu)
        default: break
        }
        if model.preferences.camera && model.state == .recording {
            item(model.preferences.showPreview ? "Hide Webcam Preview" : "Show Webcam Preview", #selector(togglePreview), in: menu)
        }
        menu.addItem(.separator())
        item("Settings…", #selector(showSettings), in: menu)
        if model.needsScreenAccess { item("Allow Screen Recording…", #selector(openScreenAccessSettings), in: menu) }
        if model.lastOutput != nil { item("Show Last Recording", #selector(revealLast), in: menu) }
        if !model.preferences.folder.isEmpty { item("Open Recordings Folder", #selector(openFolder), in: menu) }
        menu.addItem(.separator())
        item("Quit ResumeRec", #selector(quit), in: menu)
    }
    private func item(_ title: String, _ action: Selector, in menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
    }
    @objc private func start() { model.start() }
    @objc private func openScreenAccessSettings() { model.openScreenAccessSettings() }
    @objc private func stop() { Task { await model.stop() } }
    @objc private func cancel() { model.cancelCountdown() }
    @objc private func pauseResume() {
        Task { if model.state == .recording { await model.pause() } else if model.state == .paused { await model.resume() } }
    }
    @objc private func togglePreview() { model.preferences.showPreview.toggle() }
    @objc private func revealLast() { if let url = model.lastOutput { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
    @objc private func openFolder() { NSWorkspace.shared.open(URL(fileURLWithPath: model.preferences.folder)) }
    @objc private func willSleep() { if model.state == .recording { Task { await model.pause() } } }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func showSettings() {
        if settingsWindow == nil {
            let view = SettingsView(model: model) { [weak self] in self?.selectRegion() }
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: SettingsView.windowSize),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "ResumeRec — Settings"; window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: view); window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true); settingsWindow?.makeKeyAndOrderFront(nil)
        model.setSettingsVisible(true)
    }
    func windowWillClose(_ notification: Notification) { model.setSettingsVisible(false) }
    func windowDidMiniaturize(_ notification: Notification) { model.setSettingsVisible(false) }
    func windowDidDeminiaturize(_ notification: Notification) { model.setSettingsVisible(true) }
    func windowDidChangeOcclusionState(_ notification: Notification) {
        model.setSettingsVisible(!NSApp.isHidden && settingsWindow?.isVisible == true && settingsWindow?.isMiniaturized == false)
    }
    func applicationDidHide(_ notification: Notification) { model.setSettingsVisible(false) }
    func applicationDidBecomeActive(_ notification: Notification) { model.recheckScreenAccess() }
    func applicationDidUnhide(_ notification: Notification) {
        model.setSettingsVisible(settingsWindow?.isVisible == true && settingsWindow?.isMiniaturized == false)
    }
    private func selectRegion() {
        model.setSettingsVisible(false)
        settingsWindow?.orderOut(nil)
        regionSelector.select(displayID: model.preferences.displayID) { [weak self] region in
            if let region { self?.model.preferences.region = region }
            self?.showSettings()
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model.state == .idle { return .terminateNow }
        if model.state == .countdown { model.cancelCountdown(); return .terminateNow }
        if model.state == .starting || model.state == .pausing || model.state == .saving { return .terminateCancel }
        let alert = NSAlert()
        alert.messageText = "Save before quitting?"
        alert.informativeText = "Your recording will be saved to the selected folder."
        alert.addButton(withTitle: "Save & Quit"); alert.addButton(withTitle: "Keep Recording")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        Task { await model.stop(); NSApp.reply(toApplicationShouldTerminate: model.state == .idle) }
        return .terminateLater
    }
}
