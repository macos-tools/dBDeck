import Foundation
import Testing
@testable import dBDeck

@Suite("Playback history")
struct PlaybackHistoryStoreTests {
    @Test func playbackSecondsPersistAndRankWithinActivityTiers() throws {
        let suite = try IsolatedDefaults("Playback")
        let defaults = suite.defaults
        let store = PlaybackHistoryStore(defaults: defaults)
        let start = Date(timeIntervalSince1970: 1_000)
        let music = observation("music", name: "Music")
        let browser = observation("browser", name: "Browser")
        let history = observation("history", name: "History")

        store.observe([music], elapsed: 30, now: start)
        store.observe([browser], elapsed: 0, now: start.addingTimeInterval(60))

        #expect(store.records.count == 2)
        #expect(store.containsRecord(for: music.bundleID))
        #expect(!store.containsRecord(for: "com.example.missing"))
        #expect(record(music.bundleID, in: store)?.playbackMinutes == 0)
        #expect(
            record(music.bundleID, in: PlaybackHistoryStore(defaults: defaults))?
                .playbackSeconds == 30
        )

        store.observe([music], elapsed: 30, now: start.addingTimeInterval(30))
        let reloaded = PlaybackHistoryStore(defaults: defaults)
        #expect(record(music.bundleID, in: reloaded)?.playbackMinutes == 1)
        #expect(
            reloaded.prioritizedRecords(
                playingBundleIDs: [browser.bundleID],
                runningBundleIDs: [music.bundleID]
            ).map(\.bundleID) == [browser.bundleID, music.bundleID]
        )

        reloaded.observe([history], elapsed: 0, now: start.addingTimeInterval(120))
        #expect(
            reloaded.prioritizedRecords(
                playingBundleIDs: [browser.bundleID],
                runningBundleIDs: [music.bundleID]
            ).map(\.bundleID) == [browser.bundleID, music.bundleID, history.bundleID]
        )
        #expect(
            reloaded.prioritizedRecords(
                playingBundleIDs: [],
                runningBundleIDs: []
            ).map(\.bundleID) == [music.bundleID, browser.bundleID, history.bundleID]
        )
    }

    @Test func nestedHelperMigrationPreservesPlaybackSeconds() throws {
        let suite = try IsolatedDefaults("HelperMigration")
        let defaults = suite.defaults
        let store = PlaybackHistoryStore(defaults: defaults)
        let chromePath = "/Applications/Google Chrome.app"

        store.observe([
            PlaybackObservation(
                bundleID: "com.google.Chrome.helper",
                name: "Google Chrome Helper",
                bundlePath: chromePath + "/Contents/Frameworks/Google Chrome Helper.app"
            )
        ], elapsed: 90)
        store.observe([
            PlaybackObservation(
                bundleID: "com.google.Chrome",
                name: "Google Chrome",
                bundlePath: chromePath
            )
        ], elapsed: 0)

        #expect(store.records.map(\.bundleID) == ["com.google.Chrome"])
        #expect(store.records.first?.playbackSeconds == 90)
    }

    @Test func legacyWholeMinutesMigrateToSeconds() throws {
        struct LegacyRecord: Codable {
            let bundleID: String
            let name: String
            let bundlePath: String?
            let playbackMinutes: Int
            let lastPlayedAt: Date
        }

        let suite = try IsolatedDefaults("MinuteMigration")
        let defaults = suite.defaults
        defaults.set(
            try JSONEncoder().encode([
                LegacyRecord(
                    bundleID: "com.example.legacy",
                    name: "Legacy",
                    bundlePath: "/Applications/Legacy.app",
                    playbackMinutes: 3,
                    lastPlayedAt: Date(timeIntervalSince1970: 1_000)
                )
            ]),
            forKey: "appPlaybackHistory.v1"
        )

        #expect(PlaybackHistoryStore(defaults: defaults).records.first?.playbackSeconds == 180)
    }

    @Test func removesExcludedRecordsAndTheirVisibilityState() throws {
        let suite = try IsolatedDefaults("RecordRemoval")
        let defaults = suite.defaults
        let store = PlaybackHistoryStore(defaults: defaults)
        let ownApp = observation("self", name: "dBDeck")
        store.observe([ownApp], elapsed: 10)

        store.removeRecords(for: [ownApp.bundleID])

        #expect(!store.containsRecord(for: ownApp.bundleID))
        #expect(PlaybackHistoryStore(defaults: defaults).records.isEmpty)
    }

    @Test func visibilityMaintenanceRunsAtMostDailyAndPersists() throws {
        let suite = try IsolatedDefaults("Visibility")
        let defaults = suite.defaults
        let store = PlaybackHistoryStore(defaults: defaults)
        let now = Date(timeIntervalSince1970: 2_000_000)
        let stale = playbackRecord(
            "stale",
            lastPlayedAt: now.addingTimeInterval(-PlaybackHistoryStore.dormantHistoryInterval - 1)
        )
        let boundary = playbackRecord(
            "boundary",
            lastPlayedAt: now.addingTimeInterval(-PlaybackHistoryStore.dormantHistoryInterval)
        )
        let recentRecords = (0..<9).map {
            playbackRecord("recent.\($0)", lastPlayedAt: now)
        }
        let installedRecords = [stale, boundary] + recentRecords

        updateVisibility(store, records: installedRecords, now: now)
        #expect(isHidden(stale.bundleID, in: store))
        #expect(!isHidden(boundary.bundleID, in: store))

        updateVisibility(
            store,
            records: installedRecords,
            now: now.addingTimeInterval(12 * 60 * 60)
        )
        #expect(!isHidden(boundary.bundleID, in: store))

        let nextDay = now.addingTimeInterval(PlaybackHistoryStore.visibilityMaintenanceInterval)
        updateVisibility(store, records: installedRecords, now: nextDay)
        #expect(isHidden(boundary.bundleID, in: store))

        store.updateHiddenRecordsIfNeeded(
            installedRecords: installedRecords,
            playingBundleIDs: [],
            runningBundleIDs: [stale.bundleID],
            now: nextDay.addingTimeInterval(1)
        )
        #expect(!isHidden(stale.bundleID, in: store))

        let reloaded = PlaybackHistoryStore(defaults: defaults)
        updateVisibility(
            reloaded,
            records: installedRecords,
            now: nextDay.addingTimeInterval(2)
        )
        #expect(!isHidden(stale.bundleID, in: reloaded))

        updateVisibility(
            reloaded,
            records: Array(installedRecords.prefix(10)),
            now: nextDay.addingTimeInterval(
                PlaybackHistoryStore.visibilityMaintenanceInterval
            )
        )
        #expect(!isHidden(boundary.bundleID, in: reloaded))
    }


    private func observation(_ suffix: String, name: String) -> PlaybackObservation {
        PlaybackObservation(
            bundleID: "com.example.\(suffix)",
            name: name,
            bundlePath: "/Applications/\(name).app"
        )
    }

    private func playbackRecord(_ suffix: String, lastPlayedAt: Date) -> AppPlaybackRecord {
        AppPlaybackRecord(
            bundleID: "com.example.\(suffix)",
            name: suffix,
            bundlePath: nil,
            playbackSeconds: 60,
            lastPlayedAt: lastPlayedAt
        )
    }

    private func record(
        _ bundleID: String,
        in store: PlaybackHistoryStore
    ) -> AppPlaybackRecord? {
        store.records.first { $0.bundleID == bundleID }
    }

    private func updateVisibility(
        _ store: PlaybackHistoryStore,
        records: [AppPlaybackRecord],
        now: Date
    ) {
        store.updateHiddenRecordsIfNeeded(
            installedRecords: records,
            playingBundleIDs: [],
            runningBundleIDs: [],
            now: now
        )
    }

    private func isHidden(_ bundleID: String, in store: PlaybackHistoryStore) -> Bool {
        store.isHiddenFromList(
            bundleID: bundleID,
            playingBundleIDs: [],
            runningBundleIDs: []
        )
    }
}
