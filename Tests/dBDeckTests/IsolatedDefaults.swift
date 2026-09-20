import Foundation
import Testing

/// A `UserDefaults` suite that exists only for the duration of one test.
///
/// `removePersistentDomain(forName:)` empties a suite but does not reliably
/// remove the file behind it: the preferences daemon may already have written
/// one, and it stays in `~/Library/Preferences` afterwards. A suite named for a
/// fresh UUID each run therefore leaves a file per test per run, and they
/// accumulate in the user's own preferences folder indefinitely.
///
/// Holding the suite in a type that flushes the removal *and* unlinks the file
/// when it goes out of scope keeps that from happening, and keeps the cleanup
/// next to the thing that needs cleaning up rather than in every test's `defer`.
struct IsolatedDefaults: ~Copyable {
    let suiteName: String
    let defaults: UserDefaults

    init(_ label: String) throws {
        suiteName = "dBDeck\(label)Tests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
        // The preferences daemon writes lazily, so without forcing the removal
        // out first it flushes its cached copy back over the deleted file.
        defaults.synchronize()
        let file = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(suiteName).plist")
        try? FileManager.default.removeItem(at: file)
    }
}
