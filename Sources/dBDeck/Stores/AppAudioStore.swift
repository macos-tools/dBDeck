import AppKit
import Combine
import Foundation
import OSLog

@MainActor
final class AppAudioStore: ObservableObject {
    @Published private(set) var apps: [AudioApp] = []
    @Published private(set) var settings: [String: AppVolumeSetting]
    @Published var errorMessage: String?

    private let discovery = AudioProcessDiscovery()
    private let preferences: VolumePreferences
    private let playbackHistory: PlaybackHistoryStore
    private let engine = AppAudioEngine()
    private let logger = Logger(subsystem: "com.dbdeck.mac", category: "Energy")
    private var audioMonitor: AudioActivityMonitor?
    private var fallbackTimer: Timer?
    private var playbackCheckpointTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var runningApplicationBundleIDsByPID: [pid_t: String] = [:]
    private var currentPlaybackObservations: [PlaybackObservation] = []
    private var lastPlaybackAccountingDate: Date?

    init(
        preferences: VolumePreferences = VolumePreferences(),
        playbackHistory: PlaybackHistoryStore = PlaybackHistoryStore()
    ) {
        self.preferences = preferences
        self.playbackHistory = playbackHistory
        settings = preferences.load()
        cacheRunningApplications()
        observeWorkspaceEvents()

        do {
            audioMonitor = try AudioActivityMonitor { [weak self] in
                Task { @MainActor in
                    self?.refresh()
                }
            }
            logger.info("Core Audio event monitoring started; idle polling is disabled")
        } catch {
            errorMessage = error.localizedDescription
            startFallbackPolling()
            logger.error("Core Audio event monitoring failed; using 10-second fallback: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
    }

    deinit {
        fallbackTimer?.invalidate()
        playbackCheckpointTimer?.invalidate()
        let notificationCenter = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            notificationCenter.removeObserver(observer)
        }
        engine.stopAll()
    }

    var hasAdjustedApps: Bool {
        apps.contains { setting(for: $0).needsProcessing }
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
            let activeApps = try discovery.activeApps()
            accountCurrentPlayback(until: now)

            let activeAppsByBundleID = Dictionary(
                uniqueKeysWithValues: activeApps.compactMap { app in
                    app.bundleID.map { ($0, app) }
                }
            )
            let activeBundleIDs = Set(activeAppsByBundleID.keys)
            let runningBundleIDs = Set(runningApplicationBundleIDsByPID.values)
            let observations = activeApps.compactMap { app -> PlaybackObservation? in
                guard let bundleID = app.bundleID else { return nil }
                return PlaybackObservation(
                    bundleID: bundleID,
                    name: app.name,
                    bundlePath: app.bundleURL?.path
                )
            }
            playbackHistory.observe(
                observations,
                elapsed: 0,
                now: now
            )
            currentPlaybackObservations = observations
            lastPlaybackAccountingDate = observations.isEmpty ? nil : now
            updatePlaybackCheckpointTimer()

            let refreshedApps = playbackHistory
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
            publishAppsIfChanged(refreshedApps)
            engine.retainOnly(appIDs: Set(activeApps.map(\.id)))

            var firstError: String?
            for app in activeApps {
                if let message = engine.apply(setting(for: app), to: app), firstError == nil {
                    firstError = "\(app.name): \(message)"
                }
            }
            setErrorMessage(firstError)
        } catch {
            setErrorMessage(error.localizedDescription)
        }
    }

    func quit() {
        flushPlaybackHistory()
        engine.stopAll()
        NSApplication.shared.terminate(nil)
    }

    func flushPlaybackHistory() {
        accountCurrentPlayback(until: Date())
    }

    private func update(_ newSetting: AppVolumeSetting, for app: AudioApp) {
        var updatedSettings = settings
        updatedSettings[app.id] = newSetting.normalized
        settings = updatedSettings
        preferences.save(updatedSettings)
        if app.isPlaying, let message = engine.apply(newSetting, to: app) {
            setErrorMessage("\(app.name): \(message)")
        } else {
            setErrorMessage(nil)
        }
    }

    private func cacheRunningApplications() {
        runningApplicationBundleIDsByPID = Dictionary(
            uniqueKeysWithValues: NSWorkspace.shared.runningApplications.compactMap {
                application -> (pid_t, String)? in
                guard application.activationPolicy != .prohibited,
                      let bundleID = application.bundleIdentifier
                else {
                    return nil
                }
                return (application.processIdentifier, bundleID)
            }
        )
    }

    private func observeWorkspaceEvents() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            else {
                return
            }
            Task { @MainActor in
                self?.applicationDidLaunch(application)
            }
        })
        workspaceObservers.append(notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            else {
                return
            }
            Task { @MainActor in
                self?.applicationDidTerminate(application)
            }
        })
        workspaceObservers.append(notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.prepareForSleep()
            }
        })
        workspaceObservers.append(notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        })
    }

    private func applicationDidLaunch(_ application: NSRunningApplication) {
        guard application.activationPolicy != .prohibited,
              let bundleID = application.bundleIdentifier
        else {
            return
        }
        runningApplicationBundleIDsByPID[application.processIdentifier] = bundleID
        refresh()
    }

    private func applicationDidTerminate(_ application: NSRunningApplication) {
        guard runningApplicationBundleIDsByPID.removeValue(
            forKey: application.processIdentifier
        ) != nil else {
            return
        }
        refresh()
    }

    private func accountCurrentPlayback(until now: Date) {
        guard !currentPlaybackObservations.isEmpty,
              let lastPlaybackAccountingDate
        else {
            return
        }
        let elapsed = max(now.timeIntervalSince(lastPlaybackAccountingDate), 0)
        guard elapsed > 0 else { return }
        playbackHistory.observe(currentPlaybackObservations, elapsed: elapsed, now: now)
        self.lastPlaybackAccountingDate = now
    }

    private func updatePlaybackCheckpointTimer() {
        if currentPlaybackObservations.isEmpty {
            playbackCheckpointTimer?.invalidate()
            playbackCheckpointTimer = nil
            return
        }
        guard playbackCheckpointTimer == nil else { return }
        playbackCheckpointTimer = Timer.scheduledTimer(
            withTimeInterval: 60,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.accountCurrentPlayback(until: Date())
            }
        }
    }

    private func prepareForSleep() {
        accountCurrentPlayback(until: Date())
        currentPlaybackObservations = []
        lastPlaybackAccountingDate = nil
        updatePlaybackCheckpointTimer()
    }

    private func startFallbackPolling() {
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) {
            [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    private func publishAppsIfChanged(_ refreshedApps: [AudioApp]) {
        guard !Self.sameVisibleState(apps, refreshedApps) else { return }
        apps = refreshedApps
    }

    private static func sameVisibleState(_ lhs: [AudioApp], _ rhs: [AudioApp]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { left, right in
            left.id == right.id
                && left.bundleID == right.bundleID
                && left.name == right.name
                && left.bundleURL == right.bundleURL
                && left.processIDs == right.processIDs
                && left.processIdentifiers == right.processIdentifiers
                && left.isPlaying == right.isPlaying
                && left.isRunning == right.isRunning
        }
    }

    private func setErrorMessage(_ message: String?) {
        guard errorMessage != message else { return }
        errorMessage = message
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
            name: ApplicationDisplayNameResolver.name(for: bundleURL),
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
