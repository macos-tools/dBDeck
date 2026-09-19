import AppKit
import CoreAudio
import Foundation
import Testing
@testable import dBDeck

@Suite("App audio store")
@MainActor
struct AppAudioStoreTests {
    @Test func updatingOneAppDoesNotClearAnotherAppsRouteError() throws {
        let (defaults, suiteName) = try isolatedDefaults("Errors")
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = audioApp("one", name: "One", processID: 11)
        let second = audioApp("two", name: "Two", processID: 12)
        let discovery = StubAudioDiscovery(apps: [first, second])
        let engine = StubAudioEngine(failures: [first.id: "route failed"])
        let store = AppAudioStore(
            preferences: VolumePreferences(defaults: defaults),
            playbackHistory: PlaybackHistoryStore(defaults: defaults),
            discovery: discovery,
            engine: engine,
            startsEventMonitoring: false
        )

        #expect(store.errorMessage == "One: route failed")
        store.setVolume(0.5, for: second)
        #expect(store.errorMessage == "One: route failed")
        store.flushPendingState()
    }

    @Test func visibleRefreshUsesLightweightSignatureUntilProcessesChange() throws {
        let (defaults, suiteName) = try isolatedDefaults("VisibleRefresh")
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let original = audioApp("player", name: "Player", processID: 21)
        let discovery = StubAudioDiscovery(apps: [original])
        let store = AppAudioStore(
            preferences: VolumePreferences(defaults: defaults),
            playbackHistory: PlaybackHistoryStore(defaults: defaults),
            discovery: discovery,
            engine: StubAudioEngine(),
            startsEventMonitoring: false
        )

        #expect(discovery.activeAppsCallCount == 1)
        store.refreshVisiblePlaybackState()
        #expect(discovery.activeAppsCallCount == 1)

        let replacement = audioApp("player", name: "Player", processID: 22)
        discovery.apps = [replacement]
        discovery.activeObjectIDs = replacement.processIDs
        store.refreshVisiblePlaybackState()

        #expect(discovery.activeAppsCallCount == 2)
        #expect(store.apps.first?.processIDs == [22])
    }

    @Test func excludesTheHostApplicationFromHistoryAndVisibleApps() throws {
        let (defaults, suiteName) = try isolatedDefaults("SelfExclusion")
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let ownBundleID = "com.example.self"
        let ownApp = audioApp("self", name: "dBDeck", processID: 31)
        let history = PlaybackHistoryStore(defaults: defaults)
        history.observe([
            PlaybackObservation(
                bundleID: ownBundleID,
                name: "dBDeck",
                bundlePath: "/Applications/dBDeck.app"
            )
        ], elapsed: 10)
        VolumePreferences(defaults: defaults).save([
            ownBundleID: AppVolumeSetting(volume: 0.5, isMuted: false)
        ])

        let store = AppAudioStore(
            preferences: VolumePreferences(defaults: defaults),
            playbackHistory: history,
            discovery: StubAudioDiscovery(apps: [ownApp]),
            engine: StubAudioEngine(),
            excludedBundleIDs: [ownBundleID],
            startsEventMonitoring: false
        )

        #expect(store.apps.isEmpty)
        #expect(store.settings[ownBundleID] == nil)
        #expect(!history.containsRecord(for: ownBundleID))
    }

    private func isolatedDefaults(_ label: String) throws -> (UserDefaults, String) {
        let suiteName = "dBDeckStore\(label)Tests.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suiteName)), suiteName)
    }

    private func audioApp(
        _ suffix: String,
        name: String,
        processID: AudioObjectID
    ) -> AudioApp {
        AudioApp(
            bundleID: "com.example.\(suffix)",
            name: name,
            icon: NSImage(size: NSSize(width: 16, height: 16)),
            bundleURL: nil,
            processIDs: [processID],
            isPlaying: true,
            isRunning: true
        )
    }
}

private final class StubAudioDiscovery: AudioProcessDiscovering {
    var apps: [AudioApp]
    var activeObjectIDs: [AudioObjectID]
    private(set) var activeAppsCallCount = 0

    init(apps: [AudioApp]) {
        self.apps = apps
        activeObjectIDs = apps.flatMap(\.processIDs).sorted()
    }

    func activeApps() throws -> [AudioApp] {
        activeAppsCallCount += 1
        return apps
    }

    func activeProcessObjectIDs() throws -> [AudioObjectID] {
        activeObjectIDs
    }
}

private final class StubAudioEngine: AppAudioRouting {
    var failures: [String: String]

    init(failures: [String: String] = [:]) {
        self.failures = failures
    }

    func apply(_ setting: AppVolumeSetting, to app: AudioApp) -> String? {
        failures[app.id]
    }

    func retainOnly(appIDs: Set<String>) {
        failures = failures.filter { appIDs.contains($0.key) }
    }

    func retryFailure(for appID: String) {
        failures[appID] = nil
    }

    func retryFailures() {
        failures.removeAll()
    }

    func stopAll() {}
}
