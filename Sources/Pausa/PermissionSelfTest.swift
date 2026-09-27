import Foundation
import ScreenCaptureKit

enum PermissionSelfTest {
    /// Use injected authorization results; never change the user's TCC grants.
    @MainActor static func run() async throws {
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw RecorderError(message) }
        }
        var authorized = false
        var requests = 0
        var activations = 0
        let access = ScreenAccess(preflight: { authorized }, request: {
            requests += 1
            return false
        })
        let suite = "local.pausa.permission-test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RecorderModel(defaults: defaults, screenAccess: access)
        model.onScreenAccessRequest = { activations += 1 }
        model.preferences.folder = FileManager.default.temporaryDirectory.path
        // Camera/microphone are deliberately enabled: denied screen access must stop
        // the start operation before requesting either device or creating a session.
        model.preferences.camera = true
        model.preferences.microphone = true
        model.start()
        for _ in 0..<100 where model.state == .starting {
            try await Task.sleep(for: .milliseconds(10))
        }
        try expect(model.state == .idle && model.needsScreenAccess, "Missing access did not return to Ready with guidance.")
        try expect(model.errorMessage == nil && model.temporaryDirectory == nil, "Missing access opened an error or created recording files.")
        try expect(requests == 1 && activations == 1, "The first request should activate settings once, before prompting.")
        for _ in 0..<3 {
            do {
                try await model.refreshWindows()
                throw RecorderError("Window discovery proceeded without screen access.")
            } catch is ScreenAccessRequired {
                // Same path used by the dropdown's onError callback.
                model.presentError(ScreenAccessRequired())
            }
        }
        try expect(requests == 1 && activations == 1 && model.errorMessage == nil,
                   "Repeated attempts prompted again or stole focus through an error alert.")
        authorized = true
        model.recheckScreenAccess()
        try expect(!model.needsScreenAccess && model.state == .idle, "Granting access did not clear guidance, or auto-started recording.")
        try access.require { activations += 1 }
        try expect(requests == 1 && activations == 1, "Already authorized access prompted again.")

        let declined = NSError(domain: SCStreamErrorDomain, code: SCStreamError.userDeclined.rawValue)
        model.presentError(declined)
        try expect(model.needsScreenAccess && model.errorMessage == nil, "ScreenCaptureKit denial opened an error alert.")
        let unavailable = NSError(domain: SCStreamErrorDomain, code: SCStreamError.noDisplayList.rawValue)
        try expect(!ScreenAccess.isPermissionError(unavailable), "A missing display was misclassified as a permission issue.")
        try expect(!ScreenAccess.isPermissionError(NSError(domain: "Other", code: declined.code)), "Error domain was ignored.")
        model.presentError(unavailable)
        try expect(model.errorMessage != nil, "A real capture error was swallowed.")

        var events: [String] = []
        let immediateGrant = ScreenAccess(preflight: { false }, request: { events.append("request"); return true })
        try immediateGrant.require { events.append("activate") }
        try expect(events == ["activate", "request"], "The app activated after the system request.")
        var lateGrant = false
        let delayedGrant = ScreenAccess(preflight: { lateGrant }, request: { lateGrant = true; return false })
        try delayedGrant.require {}
        print("Verified: missing access prevents capture, no denial alert or repeated prompt, grant recheck, no automatic recording, precise error classification, activation before request.")
    }
}
