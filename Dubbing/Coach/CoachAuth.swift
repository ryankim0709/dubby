import Foundation

/// Supplies the Convex auth token that the tutoring routes need as a Bearer header. The sign-in
/// feature implements this; the coach only asks for the current token and never stores one.
nonisolated protocol CoachAuthTokenProvider: Sendable {
    /// The current Convex auth token, or nil when nobody is signed in.
    func convexAuthToken() async throws -> String?
}

/// The provider for builds where sign-in isn't connected yet: nobody is signed in, so every
/// tutoring route reports that sign-in is required instead of sending an unauthenticated request.
nonisolated struct SignedOutCoachTokens: CoachAuthTokenProvider {
    func convexAuthToken() async throws -> String? { nil }
}
