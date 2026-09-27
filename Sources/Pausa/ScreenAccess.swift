import CoreGraphics
import ScreenCaptureKit

struct ScreenAccessRequired: Error {}

/// A false authorization check is not evidence that the user clicked Deny.
/// Keep the system prompt separate from source discovery and from error alerts.
@MainActor
final class ScreenAccess {
    private let preflight: () -> Bool
    private let request: () -> Bool
    private var requested = false

    init(preflight: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
         request: @escaping () -> Bool = { CGRequestScreenCaptureAccess() }) {
        self.preflight = preflight
        self.request = request
    }

    var isAuthorized: Bool { preflight() }

    func require(beforeRequest: () -> Void) throws {
        if isAuthorized { return }
        if !requested {
            requested = true
            // Any app activation must happen BEFORE macOS presents its prompt.
            beforeRequest()
            if request() { return }
        }
        if isAuthorized { return }
        throw ScreenAccessRequired()
    }

    static func isPermissionError(_ error: Error) -> Bool {
        if error is ScreenAccessRequired { return true }
        let error = error as NSError
        return error.domain == SCStreamErrorDomain && error.code == SCStreamError.userDeclined.rawValue
    }
}
