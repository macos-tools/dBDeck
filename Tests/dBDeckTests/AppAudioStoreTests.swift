import AppKit
import CoreAudio
import Foundation
import Testing
@testable import dBDeck

/// Covers what the store publishes and when it goes back to discovery, using
/// stub discovery and routing so no audio hardware is involved.
@Suite("App audio store")
@MainActor
struct AppAudioStoreTests {
    @Test func updatingOneAppDoesNotClearAnotherAppsRouteError() throws {
        let suite = try IsolatedDefaults("StoreErrors")
        let defaults = suite.defaults
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
        let suite = try IsolatedDefaults("StoreVisibleRefresh")
        let defaults = suite.defaults
        let original = audioApp("player", name: "Player", processID: 21)
        // 99 is a process that discovery reports but never publishes, as an
        // excluded or unresolvable one would be. The check has to compare
        // against what discovery last reported: comparing against the published
        // list would treat that process as a difference every time.
        let discovery = StubAudioDiscovery(apps: [original], extraSignatureIDs: [99])
        let store = AppAudioStore(
            preferences: VolumePreferences(defaults: defaults),
            playbackHistory: PlaybackHistoryStore(defaults: defaults),
            discovery: discovery,
            engine: StubAudioEngine(),
            startsEventMonitoring: false
        )

        #expect(discovery.snapshotCallCount == 1)
        store.refreshVisiblePlaybackState()
        #expect(discovery.snapshotCallCount == 1)

        let replacement = audioApp("player", name: "Player", processID: 22)
        discovery.apps = [replacement]
        discovery.signature = [22, 99]
        store.refreshVisiblePlaybackState()

        #expect(discovery.snapshotCallCount == 2)
        #expect(store.apps.first?.processIDs == [22])
    }

    @Test func excludesTheHostApplicationFromHistoryAndVisibleApps() throws {
        let suite = try IsolatedDefaults("StoreSelfExclusion")
        let defaults = suite.defaults
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
    var signature: [AudioObjectID]
    private(set) var snapshotCallCount = 0

    init(apps: [AudioApp], extraSignatureIDs: [AudioObjectID] = []) {
        self.apps = apps
        signature = (apps.flatMap(\.processIDs) + extraSignatureIDs).sorted()
    }

    func snapshot() throws -> DiscoverySnapshot {
        snapshotCallCount += 1
        return DiscoverySnapshot(signature: signature, apps: apps)
    }

    func processSignature() throws -> [AudioObjectID] {
        signature
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

    func withOutputDeviceCached(_ body: () -> Void) {
        body()
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
