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
    /// Spelled out rather than left to SwiftData's default, which resolves
    /// `groupContainer: .automatic` against whatever app-group entitlement the target
    /// carries. Both targets used to declare `com.apple.security.application-groups`, and
    /// the default then followed it into a shared-group container whose
    /// `Library/Application Support` directory nothing had created — so it silently failed
    /// to open on a clean install. The entitlement is gone now (nothing read the shared
    /// container), and naming the URL is what makes that removal a no-op for existing
    /// installs instead of a store that moves out from under them.
    ///
    /// Shared by every durable store rather than reimplemented per store: the sensor logs
    /// hit this exact failure by taking the name-based initialiser, and a workaround that
    /// only one of three stores knows about is a workaround that gets forgotten again.
    ///
    /// A group container is where these belong once something outside the app — a widget,
    /// a complication — has to read the same rows. That is a migration plus the entitlement
    /// back, not a configuration flip, so it waits until there is such a reader.
    static func storeURL(fileName: String) throws -> URL {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        excludeFromBackup(directory)
        return directory.appending(path: fileName, directoryHint: .notDirectory)
    }

    /// Marks the directory holding every durable store as excluded from iCloud and iTunes
    /// backups.
    ///
    /// `CLAUDE.md` constraint 2 says health data does not leave the device. A backup is an
    /// egress path, and the default for anything under Application Support is *included*:
    /// without this line the check-in history, the notes attached to it, the tag vocabulary
    /// and every sensor row are copied into the user's iCloud account by the OS, with no
    /// prompt, no consent step, and nothing in this codebase saying so. That is the same
    /// data `cloudKitDatabase: .none` exists to keep out of iCloud, arriving by a different
    /// door.
    ///
    /// **The cost is real and is the point of the trade:** a user restoring onto a new
    /// iPhone starts with an empty history. Migration has to be an explicit, consented
    /// export rather than something the OS does silently — and until that export exists,
    /// this is the choice that matches what the app's own README promises. Reversing it is
    /// one line, and needs an ADR, not a preference.
    ///
    /// The whole directory rather than each store file, so it also covers the SQLite
    /// sidecars: `-wal` holds the most recent writes and `-shm` its index, and excluding
    /// only `Barosense.store` would back up the very rows the user last entered.
    ///
    /// Applied on every open rather than once. The flag is a file attribute, so a directory
    /// recreated after a failed migration, or restored from a backup taken before this
    /// shipped, arrives without it.
    ///
    /// **Does not throw, deliberately.** This is the one call in `storeURL` whose failure
    /// must not stop the store from opening. `setResourceValues` fails for reasons that have
    /// nothing to do with the data — an odd sandbox state, a directory mid-restore — and
    /// letting that propagate would fail every durable store at once, which `BarosenseApp`
    /// answers by falling back to memory: the barometer history then goes unwritten for the
    /// whole session, and its own comment there calls that the costliest failure it has.
    /// Against it, one launch whose files stay eligible for backup is the smaller loss, and
    /// the next launch re-applies the flag. Logged rather than swallowed, because a store
    /// that opens normally is exactly the case where nothing else would ever show this.
    private static func excludeFromBackup(_ directory: URL) {
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true

        do {
            try url.setResourceValues(values)
        } catch {
            BarosenseLog.persistence.error(
                "backup exclusion failed, store opened anyway: \(String(describing: error), privacy: .public)"
            )
        }
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
