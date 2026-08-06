import Foundation

/// Storage for the single `UserProfile`.
///
/// A protocol for the same reason as the other stores: onboarding and anything that later
/// reads the profile depend on this, not on SwiftData, so both stay testable without a
/// container. The durable implementation is injected at the app layer.
///
/// The profile is health-adjacent personal data. An implementation keeps it on device —
/// see `CLAUDE.md`, constraint 2. That is a property of the implementation, not something
/// a caller opts into here.
protocol UserProfileStore: Sendable {

    /// The stored profile, or `nil` before onboarding has written one.
    ///
    /// `nil` is what the app gates the onboarding flow on, so it has to mean "never
    /// filled in" and never "could not be read" — a failure throws instead.
    func profile() async throws -> UserProfile?

    /// Writes the profile, replacing whatever was stored.
    ///
    /// Whole-value replace rather than field-level patching: there is exactly one profile
    /// and exactly one writer, so a merge policy would be an abstraction with no second
    /// case to justify it.
    func save(_ profile: UserProfile) async throws

    /// Removes the profile. Deleting something absent is not an error.
    ///
    /// This is what "erase my data" has to be able to call, so it exists from the start
    /// rather than being retrofitted onto a store that only ever grew.
    func deleteProfile() async throws
}
