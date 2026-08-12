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

        let ranked = reloaded.prioritizedRecords(activeBundleIDs: [browser.bundleID])
        guard ranked.map(\.bundleID) == [browser.bundleID, music.bundleID] else {
            throw PlaybackHistoryVerificationFailure.failed("Active apps were not ranked first")
        }

        try verifyNestedHelperMigration()

        print("PlaybackHistory minute persistence and ranking verification passed")
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
}
