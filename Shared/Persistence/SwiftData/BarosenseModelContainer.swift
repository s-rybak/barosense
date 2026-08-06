import Foundation
import SwiftData

/// Errors from opening the durable store.
enum PersistenceError: Error {
    /// The on-disk store could not be opened — a corrupt file, or a migration the app
    /// cannot perform. Surfaced rather than swallowed: silently falling back to an
    /// in-memory container would look like the user's history had vanished.
    case containerUnavailable(underlying: Error)
}

/// The app's SwiftData stack.
///
/// One schema, one container, built once at launch and handed to the stores. Everything
/// that touches `ModelContext` sits behind a `@ModelActor` store, so no `ModelContext`
/// and no `@Model` instance ever crosses an isolation boundary — the stores hand out the
/// plain value types in `Shared/Models/` instead.
///
/// **CloudKit is off, deliberately.** `cloudKitDatabase: .none` is not a default being
/// restated: it is `CLAUDE.md` constraint 2 expressed in code. Check-ins, the tag
/// vocabulary and the profile are health or health-adjacent data, and syncing any of it
/// requires separate explicit consent plus the ADR the compliance checklist asks for.
/// Turning this on is a gated decision, not a configuration tweak.
enum BarosenseModelContainer {

    /// Every durable type. Adding a `@Model` that is not listed here compiles and then
    /// fails at runtime on first use, so the list is the registry.
    ///
    /// `CheckIn` and `PressureSample` are **not** here yet — they still have in-memory
    /// stores only. Their durable rows land with the check-in flow.
    static let schema = Schema([
        StoredUserProfile.self,
        StoredWellbeingTag.self
    ])

    /// File name of the on-disk store. Part of the storage contract — renaming it orphans
    /// every existing install's history.
    private static let storeFileName = "Barosense.store"

    /// The on-disk container backing a running app.
    static func makeDurable() throws -> ModelContainer {
        do {
            let configuration = ModelConfiguration(
                schema: schema,
                url: try storeURL(),
                cloudKitDatabase: .none
            )
            return try ModelContainer(for: schema, configurations: configuration)
        } catch {
            throw PersistenceError.containerUnavailable(underlying: error)
        }
    }

    /// Where the store file lives: the app's own Application Support directory.
    ///
    /// Spelled out rather than left to SwiftData's default. Both targets declare
    /// `com.apple.security.application-groups`, and the default location follows that
    /// entitlement into a shared-group container whose `Library/Application Support`
    /// directory nothing has created — so the default silently fails to open on a clean
    /// install. Naming the URL also means the file does not move if the entitlement
    /// changes.
    ///
    /// The group container is where this belongs once something outside the app —
    /// a widget, a complication — has to read the same rows. That is a migration, not a
    /// configuration flip, so it waits until there is such a reader.
    private static func storeURL() throws -> URL {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return directory.appending(path: storeFileName, directoryHint: .notDirectory)
    }

    /// A container that never touches disk, for tests and previews. Same schema, so a
    /// test exercises the real mapping rather than a parallel one.
    static func makeInMemory() throws -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )

        do {
            return try ModelContainer(for: schema, configurations: configuration)
        } catch {
            throw PersistenceError.containerUnavailable(underlying: error)
        }
    }
}
