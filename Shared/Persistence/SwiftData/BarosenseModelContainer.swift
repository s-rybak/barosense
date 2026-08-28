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
    /// `CheckIn` joined this schema with the check-in flow: a check-in references the tag
    /// vocabulary, so the two belong in one container. `StoredNotification` joined it for the
    /// same reason one step removed — the reminder it logs is planned off the check-in table.
    /// `PressureSample` is durable but deliberately not here: sensor rows live in their own
    /// container (`SwiftDataPressureSampleStore`), the way Health rows do.
    ///
    /// `StoredSubscription` joined it for neither reason — it references nothing here. It is on
    /// this container because a container of its own would be a fourth SQLite file that can
    /// fail to open at launch, and this one failing locks a paying user out of what they
    /// bought. Adding it is a lightweight migration: every field is optional, so an existing
    /// install gains an empty table rather than needing a mapping.
    static let schema = Schema([
        StoredUserProfile.self,
        StoredWellbeingTag.self,
        StoredCheckIn.self,
        StoredNotification.self,
        StoredSubscription.self
    ])

    /// File name of the on-disk store. Part of the storage contract — renaming it orphans
    /// every existing install's history.
    private static let storeFileName = "Barosense.store"

    /// The one on-disk container this process opens, built on first use and kept.
    ///
    /// Exists because the app is no longer the only thing that opens the store: an App
    /// Intent (`Barosense/Intents/`) runs a spoken check-in inside the app's own process,
    /// launching it in the background when it is not already up. Two `ModelContainer`s on
    /// one file is legal — it is SQLite underneath — but it is two write paths that learn
    /// about each other only on the next fetch, which is a class of "my check-in vanished"
    /// bug that is far cheaper to rule out here than to chase later.
    ///
    /// `@MainActor` rather than a lock: both callers are already there or can hop, and it
    /// makes "built once" a property of the isolation rather than of a double-checked read.
    @MainActor private static var openDurable: ModelContainer?

    @MainActor
    static func sharedDurable() throws -> ModelContainer {
        if let openDurable { return openDurable }

        let container = try makeDurable()
        openDurable = container
        return container
    }

    /// The on-disk container backing a running app.
    ///
    /// Prefer `sharedDurable()`. This stays the way the container is actually built, and is
    /// called directly only by tests that want one nobody else is holding.
    static func makeDurable() throws -> ModelContainer {
        do {
            let configuration = ModelConfiguration(
                schema: schema,
                url: try storeURL(fileName: storeFileName),
                cloudKitDatabase: .none
            )
            return try ModelContainer(for: schema, configurations: configuration)
        } catch {
            throw PersistenceError.containerUnavailable(underlying: error)
        }
    }

    /// Where a durable store file lives: the app's own Application Support directory.
    ///
    /// Spelled out rather than left to SwiftData's default. Both targets declare
    /// `com.apple.security.application-groups`, and `ModelConfiguration`'s default
    /// `groupContainer: .automatic` follows that entitlement into a shared-group container
    /// whose `Library/Application Support` directory nothing has created — so the default
    /// silently fails to open on a clean install. Naming the URL also means the file does
    /// not move if the entitlement changes.
    ///
    /// Shared by every durable store rather than reimplemented per store: the sensor logs
    /// hit this exact failure by taking the name-based initialiser, and a workaround that
    /// only one of three stores knows about is a workaround that gets forgotten again.
    ///
    /// The group container is where these belong once something outside the app —
    /// a widget, a complication — has to read the same rows. That is a migration, not a
    /// configuration flip, so it waits until there is such a reader.
    static func storeURL(fileName: String) throws -> URL {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return directory.appending(path: fileName, directoryHint: .notDirectory)
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
