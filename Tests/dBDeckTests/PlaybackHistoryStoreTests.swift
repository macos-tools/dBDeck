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
        store.observe([browser], elapsed: 0, now: start.addingTimeInterval(60))

        guard store.records.count == 2 else {
            throw PlaybackHistoryVerificationFailure.failed("Played apps were not retained")
        }
        guard store.containsRecord(for: music.bundleID),
              !store.containsRecord(for: "com.example.missing")
        else {
            throw PlaybackHistoryVerificationFailure.failed("History lookup was incorrect")
        }
        guard store.records.first(where: { $0.bundleID == music.bundleID })?.playbackMinutes == 0 else {
            throw PlaybackHistoryVerificationFailure.failed("Sub-minute playback was rounded too early")
        }
        let subminuteReload = PlaybackHistoryStore(defaults: defaults)
        guard subminuteReload.records.first(where: { $0.bundleID == music.bundleID })?
            .playbackSeconds == 30
        else {
            throw PlaybackHistoryVerificationFailure.failed(
                "Event-driven playback interval did not survive reload"
            )
        }

        store.observe([music], elapsed: 30, now: start.addingTimeInterval(30))
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
        try verifyDormantHistoryVisibility()

        print("PlaybackHistory second persistence, migration, and ranking verification passed")
    }

    private static func verifyDormantHistoryVisibility() throws {
        let suiteName = "dBDeckDormantVisibilityTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw PlaybackHistoryVerificationFailure.failed("Could not create visibility suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = PlaybackHistoryStore(defaults: defaults)
        let now = Date(timeIntervalSince1970: 2_000_000)
        let stale = AppPlaybackRecord(
            bundleID: "com.example.stale",
            name: "Stale",
            bundlePath: nil,
            playbackSeconds: 60,
            lastPlayedAt: now.addingTimeInterval(
                -PlaybackHistoryStore.dormantHistoryInterval - 1
            )
        )
        let boundary = AppPlaybackRecord(
            bundleID: "com.example.boundary",
            name: "Boundary",
            bundlePath: nil,
            playbackSeconds: 60,
            lastPlayedAt: now.addingTimeInterval(
                -PlaybackHistoryStore.dormantHistoryInterval
            )
        )
        let recentRecords = (0..<9).map { index in
            AppPlaybackRecord(
                bundleID: "com.example.recent.\(index)",
                name: "Recent \(index)",
                bundlePath: nil,
                playbackSeconds: 60,
                lastPlayedAt: now
            )
        }
        let installedRecords = [stale, boundary] + recentRecords

        store.updateHiddenRecordsIfNeeded(
            installedRecords: installedRecords,
            playingBundleIDs: [],
            runningBundleIDs: [],
            now: now
        )
        guard store.isHiddenFromList(
            bundleID: stale.bundleID,
            playingBundleIDs: [],
            runningBundleIDs: []
        ) else {
            throw PlaybackHistoryVerificationFailure.failed(
                "Dormant history was not hidden above the list limit"
            )
        }
        guard !store.isHiddenFromList(
            bundleID: boundary.bundleID,
            playingBundleIDs: [],
            runningBundleIDs: []
        ) else {
            throw PlaybackHistoryVerificationFailure.failed(
                "Exactly seven-day-old history was hidden too early"
            )
        }

        let twelveHoursLater = now.addingTimeInterval(12 * 60 * 60)
        store.updateHiddenRecordsIfNeeded(
            installedRecords: installedRecords,
            playingBundleIDs: [],
            runningBundleIDs: [],
            now: twelveHoursLater
        )
        guard !store.isHiddenFromList(
            bundleID: boundary.bundleID,
            playingBundleIDs: [],
            runningBundleIDs: []
        ) else {
            throw PlaybackHistoryVerificationFailure.failed(
                "Visibility maintenance ran more than once per day"
            )
        }

        let oneDayLater = now.addingTimeInterval(PlaybackHistoryStore.visibilityMaintenanceInterval)
        store.updateHiddenRecordsIfNeeded(
            installedRecords: installedRecords,
            playingBundleIDs: [],
            runningBundleIDs: [],
            now: oneDayLater
        )
        guard store.isHiddenFromList(
            bundleID: boundary.bundleID,
            playingBundleIDs: [],
            runningBundleIDs: []
        ) else {
            throw PlaybackHistoryVerificationFailure.failed(
                "Daily visibility maintenance did not run"
            )
        }

        store.updateHiddenRecordsIfNeeded(
            installedRecords: installedRecords,
            playingBundleIDs: [stale.bundleID],
            runningBundleIDs: [],
            now: oneDayLater.addingTimeInterval(1)
        )
        guard !store.isHiddenFromList(
            bundleID: stale.bundleID,
            playingBundleIDs: [],
            runningBundleIDs: []
        ) else {
            throw PlaybackHistoryVerificationFailure.failed(
                "An active app did not leave the hidden list immediately"
            )
        }

        let reloaded = PlaybackHistoryStore(defaults: defaults)
        reloaded.updateHiddenRecordsIfNeeded(
            installedRecords: installedRecords,
            playingBundleIDs: [],
            runningBundleIDs: [],
            now: oneDayLater.addingTimeInterval(2)
        )
        guard !reloaded.isHiddenFromList(
            bundleID: stale.bundleID,
            playingBundleIDs: [],
            runningBundleIDs: []
        ) else {
            throw PlaybackHistoryVerificationFailure.failed(
                "Daily visibility state did not survive reload"
            )
        }

        reloaded.updateHiddenRecordsIfNeeded(
            installedRecords: Array(installedRecords.prefix(10)),
            playingBundleIDs: [],
            runningBundleIDs: [],
            now: oneDayLater.addingTimeInterval(
                PlaybackHistoryStore.visibilityMaintenanceInterval
            )
        )
        guard !reloaded.isHiddenFromList(
            bundleID: boundary.bundleID,
            playingBundleIDs: [],
            runningBundleIDs: []
        ) else {
            throw PlaybackHistoryVerificationFailure.failed(
                "A list of 10 apps retained a stale hidden state"
            )
        }
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
