import Foundation

/// Non-persistent `UserProfileStore` for unit tests, SwiftUI previews, and bring-up.
/// Contents are lost with the process.
actor InMemoryUserProfileStore: UserProfileStore {

    private var storage: UserProfile?

    init(_ profile: UserProfile? = nil) {
        self.storage = profile
    }

    func profile() -> UserProfile? { storage }

    func save(_ profile: UserProfile) {
        storage = profile
    }

    func deleteProfile() {
        storage = nil
    }
}
