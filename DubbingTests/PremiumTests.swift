import Foundation
import Testing
@testable import Dubbing

struct PremiumTests {
    @Test func subscriptionAccessExpiresAtThePaidPeriodBoundary() {
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        let premium = PremiumStatus(isPremium: true, expiresAt: expiry.timeIntervalSince1970 * 1000)
        #expect(premium.allowsCoach(at: expiry.addingTimeInterval(-1)))
        #expect(!premium.allowsCoach(at: expiry))
        #expect(!PremiumStatus(isPremium: false, expiresAt: nil).allowsCoach(at: expiry))
    }
}
