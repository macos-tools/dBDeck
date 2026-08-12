import AppKit
import Combine
import Foundation

@MainActor
final class AppAudioStore: ObservableObject {
    @Published private(set) var apps: [AudioApp] = []
    @Published private(set) var settings: [String: AppVolumeSetting]
    @Published var errorMessage: String?

    private let discovery = AudioProcessDiscovery()
    private let preferences: VolumePreferences
    private let playbackHistory: PlaybackHistoryStore
    private let engine = AppAudioEngine()
    private var refreshTimer: Timer?
    private var lastRefreshDate: Date?

    init(
        preferences: VolumePreferences = VolumePreferences(),
        playbackHistory: PlaybackHistoryStore = PlaybackHistoryStore()
    ) {
        self.preferences = preferences
        self.playbackHistory = playbackHistory
        settings = preferences.load()
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    deinit {
        refreshTimer?.invalidate()
        engine.stopAll()
    }

    var hasAdjustedApps: Bool {
        apps.contains { setting(for: $0).needsProcessing }
    }

    var priorityApps: [AudioApp] {
        Array(apps.prefix(5))
    }

    func setting(for app: AudioApp) -> AppVolumeSetting {
        settings[app.id] ?? .passthrough
    }

    func setVolume(_ volume: Double, for app: AudioApp) {
        var setting = setting(for: app)
        setting.volume = volume
        update(setting, for: app)
    }

    func toggleMute(for app: AudioApp) {
        var setting = setting(for: app)
        setting.isMuted.toggle()
        update(setting, for: app)
    }

    func playbackMinutes(for app: AudioApp) -> Int {
        playbackHistory.records.first(where: { $0.bundleID == app.bundleID })?
            .playbackMinutes ?? 0
    }

    func retry() {
        errorMessage = nil
        engine.retryFailures()
        refresh()
    }

    func refresh() {
        do {
            let now = Date()
            let elapsed = lastRefreshDate.map { now.timeIntervalSince($0) } ?? 0
            lastRefreshDate = now

            let activeApps = try discovery.activeApps()
            let activeAppsByBundleID = Dictionary(
                uniqueKeysWithValues: activeApps.compactMap { app in
                    app.bundleID.map { ($0, app) }
                }
            )
            let activeBundleIDs = Set(activeAppsByBundleID.keys)
            let runningBundleIDs: Set<String> = Set(
                NSWorkspace.shared.runningApplications.compactMap { application -> String? in
                    guard application.activationPolicy != .prohibited else { return nil }
                    return application.bundleIdentifier
                }
            )
            playbackHistory.observe(
                activeApps.compactMap { app in
                    guard let bundleID = app.bundleID else { return nil }
                    return PlaybackObservation(
                        bundleID: bundleID,
                        name: app.name,
                        bundlePath: app.bundleURL?.path
                    )
                },
                elapsed: elapsed,
                now: now
            )

            apps = playbackHistory
                .prioritizedRecords(
                    playingBundleIDs: activeBundleIDs,
                    runningBundleIDs: runningBundleIDs
                )
                .compactMap { record in
                    if let activeApp = activeAppsByBundleID[record.bundleID] {
                        return activeApp
                    }
                    return historicalAudioApp(
                        from: record,
                        isRunning: runningBundleIDs.contains(record.bundleID)
                    )
                }
            engine.retainOnly(appIDs: Set(activeApps.map(\.id)))

            var firstError: String?
            for app in activeApps {
                if let message = engine.apply(setting(for: app), to: app), firstError == nil {
                    firstError = "\(app.name): \(message)"
                }
            }
            errorMessage = firstError
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func quit() {
        engine.stopAll()
        NSApplication.shared.terminate(nil)
    }

    private func update(_ newSetting: AppVolumeSetting, for app: AudioApp) {
        var updatedSettings = settings
        updatedSettings[app.id] = newSetting.normalized
        settings = updatedSettings
        preferences.save(updatedSettings)
        if app.isPlaying, let message = engine.apply(newSetting, to: app) {
            errorMessage = "\(app.name): \(message)"
        } else {
            errorMessage = nil
        }
    }

    private func historicalAudioApp(
        from record: AppPlaybackRecord,
        isRunning: Bool
    ) -> AudioApp? {
        guard let bundleURL = installedApplicationURL(for: record) else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: bundleURL.path)

        return AudioApp(
            id: record.bundleID,
            bundleID: record.bundleID,
            name: record.name,
            icon: icon,
            bundleURL: bundleURL,
            processIDs: [],
            processIdentifiers: [],
            isPlaying: false,
            isRunning: isRunning
        )
    }

    private func installedApplicationURL(for record: AppPlaybackRecord) -> URL? {
        let currentURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: record.bundleID
        )
        let storedURL = record.bundlePath.map { URL(fileURLWithPath: $0) }

        return [currentURL, storedURL]
            .compactMap { $0 }
            .first { url in
                let path = url.standardizedFileURL.path
                guard !path.contains("/.Trash/"),
                      FileManager.default.fileExists(atPath: path),
                      let bundle = Bundle(url: url)
                else {
                    return false
                }
                return bundle.bundleIdentifier == record.bundleID
            }
    }
}
