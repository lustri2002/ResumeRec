import Foundation
import Combine
import PausaCore

enum DragSelfTest {
    /// Exercise the actual model with isolated preferences, without starting capture.
    @MainActor static func run() throws {
        let suite = "local.pausa.drag-test.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw RecorderError("Test preferences unavailable.") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RecorderModel(defaults: defaults)
        let initial = model.preferences
        let initialData = defaults.data(forKey: "preferences.v1")
        var notifications = 0
        let subscription = model.objectWillChange.sink { notifications += 1 }
        defer { subscription.cancel() }
        for index in 0..<10_000 {
            model.updateCameraDrag(position: CGPoint(x: Double(index) / 10_000, y: 0.42))
        }
        guard model.preferences == initial, defaults.data(forKey: "preferences.v1") == initialData, notifications == 0 else {
            throw RecorderError("Dragging published or persisted intermediate settings.")
        }
        guard model.overlayPreferences.anchor == .custom, model.overlayPreferences.customX == 0.9999,
              model.overlayPreferences.customY == 0.42 else { throw RecorderError("The latest drag position was lost.") }
        model.finishCameraDrag()
        guard notifications == 1, let data = defaults.data(forKey: "preferences.v1") else {
            throw RecorderError("Drag completion must publish and save once.")
        }
        let saved = try JSONDecoder().decode(Preferences.self, from: data)
        guard saved == model.preferences, saved == model.overlayPreferences, saved.anchor == .custom,
              saved.customX == 0.9999, saved.customY == 0.42 else { throw RecorderError("Final drag position was not saved correctly.") }
        model.finishCameraDrag()
        guard notifications == 1 else { throw RecorderError("Finishing the same drag twice must be a no-op.") }
        print("Verified: 10,000 transient positions, zero intermediate publications/writes, final position saved once, repeat finish is a no-op.")
        var clockNotifications = 0
        model.onClockChanged = { clockNotifications += 1 }
        let persisted = defaults.data(forKey: "preferences.v1")
        for tick in 1...240 { model.updateElapsed(Double(tick) / 4) }
        guard notifications == 1, clockNotifications == 60, model.timeLabel == "01:00",
              defaults.data(forKey: "preferences.v1") == persisted else {
            throw RecorderError("Recording clock invalidated settings or refreshed more than once per second.")
        }
        model.updateElapsed(0)
        guard clockNotifications == 61, model.timeLabel == "00:00", notifications == 1 else {
            throw RecorderError("Recording clock did not reset independently of settings.")
        }
        print("Verified: 240 recording ticks, zero settings invalidations/writes, 60 menu-bar updates and correct reset.")
    }
}
