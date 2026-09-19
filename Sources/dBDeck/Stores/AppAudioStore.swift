import AppKit
import Combine
import Foundation
import OSLog

@MainActor
final class AppAudioStore: ObservableObject {
    @Published private(set) var apps: [AudioApp] = []
    @Published private(set) var errorMessage: String?

    private(set) var settings: [String: AppVolumeSetting]

    private let discovery: any AudioProcessDiscovering
    private let preferences: VolumePreferences
    private let playbackHistory: PlaybackHistoryStore
    private let historicalApplications = HistoricalApplicationResolver()
    private let engine: any AppAudioRouting
    private let excludedBundleIDs: Set<String>
    private let logger = Logger(subsystem: "com.dbdeck.mac", category: "Energy")
    private var audioMonitor: AudioActivityMonitor?
    private var fallbackTimer: Timer?
    private var playbackCheckpointTimer: Timer?
    private var preferencesSaveTimer: Timer?
    private var settingsNeedSave = false
    private var workspaceObservers: [NSObjectProtocol] = []
    private var runningApplicationBundleIDsByPID: [pid_t: String] = [:]
    private var currentPlaybackObservations: [PlaybackObservation] = []
    private var lastPlaybackAccountingDate: Date?
    private var volumeControls: [String: AppVolumeControl] = [:]
    private var operationErrorMessage: String?
    private var routeErrorsByAppID: [String: String] = [:]

    init(
        preferences: VolumePreferences = VolumePreferences(),
        playbackHistory: PlaybackHistoryStore = PlaybackHistoryStore(),
        discovery: any AudioProcessDiscovering = AudioProcessDiscovery(),
        engine: any AppAudioRouting = AppAudioEngine(),
        excludedBundleIDs: Set<String> = DBDeckApplicationIdentity.bundleIDs,
        startsEventMonitoring: Bool = true
    ) {
        self.preferences = preferences
        self.playbackHistory = playbackHistory
        self.discovery = discovery
        self.engine = engine
        self.excludedBundleIDs = excludedBundleIDs
        let savedSettings = preferences.load()
        let retainedSettings = savedSettings.filter {
            !excludedBundleIDs.contains($0.key)
        }
        settings = retainedSettings
        if settings.count != savedSettings.count {
            preferences.save(settings)
        }
        playbackHistory.removeRecords(for: excludedBundleIDs)
        cacheRunningApplications()
        if startsEventMonitoring {
            observeWorkspaceEvents()
            do {
                audioMonitor = try AudioActivityMonitor { [weak self] change in
                    Task { @MainActor in
                        guard let self else { return }
                        if change.contains(.defaultOutputDevice) {
                            // A new output device is a fresh chance to route, so
                            // do not make the user wait out a backoff earned
                            // against the device they just switched away from.
                            self.engine.retryFailures()
                        }
                        self.refresh()
                    }
                }
                logger.info("Core Audio event monitoring started; idle polling is disabled")
            } catch {
                startFallbackPolling()
                logger.error("Core Audio event monitoring failed; using 10-second fallback: \(error.localizedDescription, privacy: .public)")
            }
        }
        refresh()
    }

    deinit {
        fallbackTimer?.invalidate()
        playbackCheckpointTimer?.invalidate()
        preferencesSaveTimer?.invalidate()
        let notificationCenter = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            notificationCenter.removeObserver(observer)
        }
        engine.stopAll()
    }

    func setting(for app: AudioApp) -> AppVolumeSetting {
        settings[app.id] ?? .passthrough
    }

    func volumeControl(for app: AudioApp) -> AppVolumeControl {
        if let control = volumeControls[app.id] {
            return control
        }
        let control = AppVolumeControl(setting: setting(for: app))
        volumeControls[app.id] = control
        return control
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

    func resetAllVolumes() {
        settings.removeAll()
        for control in volumeControls.values {
            control.update(.passthrough)
        }
        settingsNeedSave = true
        persistSettings()

        engine.stopAll()
        routeErrorsByAppID.removeAll()
        publishErrorMessage()
    }

    func retry() {
        operationErrorMessage = nil
        routeErrorsByAppID.removeAll()
        engine.retryFailures()
        historicalApplications.retryAllUnavailableApplications()
        refresh()
    }

    func manualRefresh() {
        engine.retryFailures()
        historicalApplications.retryAllUnavailableApplications()
        refresh()
    }

    func refreshVisiblePlaybackState() {
        do {
            let discoveredProcesses = try discovery.activeProcessObjectIDs()
            let publishedProcesses = apps
                .filter(\.isPlaying)
                .flatMap(\.processIDs)
                .sorted()
            guard discoveredProcesses != publishedProcesses else { return }
        } catch {
            operationErrorMessage = error.localizedDescription
            publishErrorMessage()
            return
        }
        refresh()
    }

    func refresh() {
        do {
            let now = Date()
            let activeApps = try discovery.activeApps()
            refresh(activeApps: activeApps, now: now)
        } catch {
            operationErrorMessage = error.localizedDescription
            publishErrorMessage()
        }
    }

    func quit() {
        flushPendingState()
        engine.stopAll()
        NSApplication.shared.terminate(nil)
    }

    func flushPendingState() {
        accountCurrentPlayback(until: Date())
        persistSettings()
    }

    private func update(_ newSetting: AppVolumeSetting, for app: AudioApp) {
        guard settings[app.id] != newSetting else { return }
        settings[app.id] = newSetting
        volumeControls[app.id]?.update(newSetting)
        settingsNeedSave = true
        schedulePreferencesSave()
        if app.isPlaying {
            engine.retryFailure(for: app.id)
            applyRoute(newSetting, to: app)
        }
        publishErrorMessage()
    }

    private func applyRoute(_ setting: AppVolumeSetting, to app: AudioApp) {
        routeErrorsByAppID[app.id] = engine.apply(setting, to: app).map {
            "\(app.name): \($0)"
        }
    }

    private func refresh(activeApps: [AudioApp], now: Date) {
        let activeApps = activeApps.filter {
            !excludedBundleIDs.contains($0.bundleID)
        }
        accountCurrentPlayback(until: now)

        let observations = activeApps.map { app in
            PlaybackObservation(
                bundleID: app.bundleID,
                name: app.name,
                bundlePath: app.bundleURL?.path
            )
        }
        playbackHistory.observe(observations, elapsed: 0, now: now)
        currentPlaybackObservations = observations
        lastPlaybackAccountingDate = observations.isEmpty ? nil : now
        updatePlaybackCheckpointTimer()
        rebuildVisibleApps(activeApps: activeApps, now: now)

        let activeAppIDs = Set(activeApps.map(\.id))
        engine.retainOnly(appIDs: activeAppIDs)
        routeErrorsByAppID = routeErrorsByAppID.filter { activeAppIDs.contains($0.key) }
        engine.withOutputDeviceCached {
            for app in activeApps {
                applyRoute(setting(for: app), to: app)
            }
        }
        operationErrorMessage = nil
        publishErrorMessage()
    }

    private func cacheRunningApplications() {
        runningApplicationBundleIDsByPID = Dictionary(
            NSWorkspace.shared.runningApplications.compactMap {
                application -> (pid_t, String)? in
                guard let bundleID = trackedBundleID(of: application) else { return nil }
                return (application.processIdentifier, bundleID)
            },
            uniquingKeysWith: { _, latest in latest }
        )
    }

    /// `nil` for apps this mixer never tracks. Note that `processIdentifier` is
    /// `-1` for apps without a pid, so callers must tolerate duplicate keys.
    private func trackedBundleID(of application: NSRunningApplication) -> String? {
        guard application.activationPolicy != .prohibited,
              let bundleID = application.bundleIdentifier,
              !excludedBundleIDs.contains(bundleID)
        else {
            return nil
        }
        return bundleID
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
        guard let bundleID = trackedBundleID(of: application) else { return }
        runningApplicationBundleIDsByPID[application.processIdentifier] = bundleID
        historicalApplications.retryUnavailableApplication(bundleID: bundleID)
        guard playbackHistory.containsRecord(for: bundleID) else { return }
        refresh()
    }

    private func applicationDidTerminate(_ application: NSRunningApplication) {
        guard let bundleID = runningApplicationBundleIDsByPID.removeValue(
            forKey: application.processIdentifier
        ) else {
            return
        }
        guard playbackHistory.containsRecord(for: bundleID) else { return }
        refresh()
    }

    private func schedulePreferencesSave() {
        preferencesSaveTimer?.invalidate()
        preferencesSaveTimer = Timer.scheduledTimer(
            withTimeInterval: 0.25,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                self?.persistSettings()
            }
        }
    }

    private func persistSettings() {
        preferencesSaveTimer?.invalidate()
        preferencesSaveTimer = nil
        guard settingsNeedSave else { return }
        settingsNeedSave = false
        preferences.save(settings)
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
                self?.refresh()
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
        guard apps != refreshedApps else { return }
        apps = refreshedApps
    }

    private func rebuildVisibleApps(activeApps: [AudioApp], now: Date) {
        let activeAppsByBundleID = Dictionary(
            uniqueKeysWithValues: activeApps.map { ($0.bundleID, $0) }
        )
        let activeBundleIDs = Set(activeAppsByBundleID.keys)
        let runningBundleIDs = Set(runningApplicationBundleIDsByPID.values)
        let installedRecordsAndApps = playbackHistory
            .prioritizedRecords(
                playingBundleIDs: activeBundleIDs,
                runningBundleIDs: runningBundleIDs
            )
            .compactMap { record -> (AppPlaybackRecord, AudioApp)? in
                if let activeApp = activeAppsByBundleID[record.bundleID] {
                    return (record, activeApp)
                }
                guard let app = historicalApplications.audioApp(
                    from: record,
                    isRunning: runningBundleIDs.contains(record.bundleID)
                ) else {
                    return nil
                }
                return (record, app)
            }
        playbackHistory.updateHiddenRecordsIfNeeded(
            installedRecords: installedRecordsAndApps.map(\.0),
            playingBundleIDs: activeBundleIDs,
            runningBundleIDs: runningBundleIDs,
            now: now
        )
        let refreshedApps = installedRecordsAndApps.compactMap { record, app in
            playbackHistory.isHiddenFromList(
                bundleID: record.bundleID,
                playingBundleIDs: activeBundleIDs,
                runningBundleIDs: runningBundleIDs
            ) ? nil : app
        }
        publishAppsIfChanged(refreshedApps)
    }

    private func setErrorMessage(_ message: String?) {
        guard errorMessage != message else { return }
        errorMessage = message
    }

    private func publishErrorMessage() {
        if let operationErrorMessage {
            setErrorMessage(operationErrorMessage)
            return
        }
        let orderedRouteError = apps.lazy.compactMap { self.routeErrorsByAppID[$0.id] }.first
            ?? routeErrorsByAppID.sorted(by: { $0.key < $1.key }).first?.value
        setErrorMessage(orderedRouteError)
    }

}
