import Foundation

enum PlaybackHistoryVerificationFailure: Error {
    case failed(String)
}

@main
enum PlaybackHistoryStoreVerifier {
    static func main() throws {
        let suiteName = "dBDeckPlaybackTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw PlaybackHistoryVerificationFailure.failed("Could not create defaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = PlaybackHistoryStore(defaults: defaults)
        let start = Date(timeIntervalSince1970: 1_000)
        let music = PlaybackObservation(
            bundleID: "com.example.music",
            name: "Music",
            bundlePath: "/Applications/Example Music.app"
        )
        let browser = PlaybackObservation(
            bundleID: "com.example.browser",
            name: "Browser",
            bundlePath: "/Applications/Example Browser.app"
        )

        store.observe([music], elapsed: 30, now: start)
        store.observe([music], elapsed: 30, now: start.addingTimeInterval(30))
        store.observe([browser], elapsed: 0, now: start.addingTimeInterval(60))

        guard store.records.count == 2 else {
            throw PlaybackHistoryVerificationFailure.failed("Played apps were not retained")
        }
        guard store.records.first(where: { $0.bundleID == music.bundleID })?.playbackMinutes == 0 else {
            throw PlaybackHistoryVerificationFailure.failed("Elapsed time cap was not applied")
        }
        let subminuteReload = PlaybackHistoryStore(defaults: defaults)
        guard subminuteReload.records.first(where: { $0.bundleID == music.bundleID })?
            .playbackSeconds == 10
        else {
            throw PlaybackHistoryVerificationFailure.failed(
                "Sub-minute playback did not survive reload"
            )
        }

        for offset in 1...12 {
            store.observe(
                [music],
                elapsed: 5,
                now: start.addingTimeInterval(Double(60 + offset * 5))
            )
        }
        guard store.records.first(where: { $0.bundleID == music.bundleID })?.playbackMinutes == 1 else {
            throw PlaybackHistoryVerificationFailure.failed("Playback was not credited by full minutes")
        }

        let reloaded = PlaybackHistoryStore(defaults: defaults)
        guard reloaded.records.first(where: { $0.bundleID == music.bundleID })?.playbackMinutes == 1 else {
            throw PlaybackHistoryVerificationFailure.failed("Playback history did not survive reload")
        }

        let ranked = reloaded.prioritizedRecords(
            playingBundleIDs: [browser.bundleID],
            runningBundleIDs: [music.bundleID]
        )
        guard ranked.map(\.bundleID) == [browser.bundleID, music.bundleID] else {
            throw PlaybackHistoryVerificationFailure.failed("Playing apps were not ranked first")
        }

        let historyOnly = PlaybackObservation(
            bundleID: "com.example.history",
            name: "History",
            bundlePath: "/Applications/Example History.app"
        )
        reloaded.observe([historyOnly], elapsed: 0, now: start.addingTimeInterval(120))
        let tiered = reloaded.prioritizedRecords(
            playingBundleIDs: [browser.bundleID],
            runningBundleIDs: [music.bundleID]
        )
        guard tiered.map(\.bundleID) == [browser.bundleID, music.bundleID, historyOnly.bundleID] else {
            throw PlaybackHistoryVerificationFailure.failed(
                "Playing, running-history, and stopped-history tiers were not preserved"
            )
        }

        let durationRanked = reloaded.prioritizedRecords(
            playingBundleIDs: [],
            runningBundleIDs: []
        )
        guard durationRanked.map(\.bundleID) == [music.bundleID, browser.bundleID, historyOnly.bundleID] else {
            throw PlaybackHistoryVerificationFailure.failed(
                "Playback duration did not outrank recency within the same activity tier"
            )
        }

        try verifyNestedHelperMigration()
        try verifyLegacyMinuteMigration()

        print("PlaybackHistory second persistence, migration, and ranking verification passed")
    }

    private static func verifyNestedHelperMigration() throws {
        let suiteName = "dBDeckHelperMigrationTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw PlaybackHistoryVerificationFailure.failed("Could not create migration defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = PlaybackHistoryStore(defaults: defaults)
        let chromePath = "/Applications/Google Chrome.app"
        store.observe([
            PlaybackObservation(
                bundleID: "com.google.Chrome.helper",
                name: "Google Chrome Helper",
                bundlePath: chromePath + "/Contents/Frameworks/Google Chrome Helper.app"
            )
        ], elapsed: 0)
        store.observe([
            PlaybackObservation(
                bundleID: "com.google.Chrome",
                name: "Google Chrome",
                bundlePath: chromePath
            )
        ], elapsed: 0)

        guard store.records.map(\.bundleID) == ["com.google.Chrome"] else {
            throw PlaybackHistoryVerificationFailure.failed("Nested helper history was not merged")
        }
    }

    private static func verifyLegacyMinuteMigration() throws {
        struct LegacyRecord: Codable {
            let bundleID: String
            let name: String
            let bundlePath: String?
            let playbackMinutes: Int
            let lastPlayedAt: Date
        }

        let suiteName = "dBDeckMinuteMigrationTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw PlaybackHistoryVerificationFailure.failed("Could not create migration suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let legacyRecord = LegacyRecord(
            bundleID: "com.example.legacy",
            name: "Legacy",
            bundlePath: "/Applications/Legacy.app",
            playbackMinutes: 3,
            lastPlayedAt: Date(timeIntervalSince1970: 1_000)
        )
        defaults.set(
            try JSONEncoder().encode([legacyRecord]),
            forKey: "appPlaybackHistory.v1"
        )

        let migrated = PlaybackHistoryStore(defaults: defaults)
        guard migrated.records.first?.playbackSeconds == 180 else {
            throw PlaybackHistoryVerificationFailure.failed(
                "Legacy whole-minute playback was not migrated to seconds"
            )
        }
    }
}
