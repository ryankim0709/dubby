import Foundation

/// A failure the backend can be asked to simulate on `/coach/reply`, for QA runs.
nonisolated enum CoachQAFault: String, Hashable, Sendable {
    case missingKey = "missing_key"
    case providerError = "provider_error"
    case providerTimeout = "provider_timeout"

    static let header = "X-QA-Fault"
}

/// QA switches read from launch arguments. They exist only in DEBUG builds: a release build
/// compiles to "nothing enabled", so it never sends the fault header or shows the QA state carriers.
nonisolated struct CoachQAOptions: Equatable, Sendable {
    /// `-DUBIT_UI_TEST 1`: expose the coach's runtime facts to UI tests.
    let isUITest: Bool
    /// `-DUBIT_QA_COACH_FAULT <missing_key|provider_error|provider_timeout>`.
    let fault: CoachQAFault?

    static let disabled = CoachQAOptions(isUITest: false, fault: nil)

    /// An unknown fault name enables nothing, so a typo can't turn into a different failure.
    static func parse(uiTest: Bool, fault: String?) -> CoachQAOptions {
        CoachQAOptions(isUITest: uiTest, fault: fault.flatMap(CoachQAFault.init(rawValue:)))
    }

    static let current: CoachQAOptions = {
        #if DEBUG
        let defaults = UserDefaults.standard
        return parse(uiTest: defaults.bool(forKey: "DUBIT_UI_TEST"), fault: defaults.string(forKey: "DUBIT_QA_COACH_FAULT"))
        #else
        return .disabled
        #endif
    }()
}
