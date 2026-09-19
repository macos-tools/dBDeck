import AppKit
import Combine
import CoreAudio
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
    private var workspaceObservers: [NSObjectProtocol] = []
    private var runningApplicationBundleIDsByPID: [pid_t: String] = [:]
    // Several PIDs can share a bundle ID, so the set needs reference counts to
    // know when the last instance of an app has gone.
    private var runningBundleIDCounts: [String: Int] = [:]
    private var runningBundleIDs: Set<String> = []
    private var playbackAccounting: (observations: [PlaybackObservation], since: Date)?
    private var volumeControls: [String: AppVolumeControl] = [:]
    private var operationErrorMessage: String?
    private var routeErrorsByAppID: [String: String] = [:]
    private var lastProcessSignature: [AudioObjectID]?

    init(
        preferences: VolumePreferences = VolumePreferences(),
        playbackHistory: PlaybackHistoryStore = PlaybackHistoryStore(),
        discovery: (any AudioProcessDiscovering)? = nil,
        engine: any AppAudioRouting = AppAudioEngine(),
        excludedBundleIDs: Set<String> = DBDeckApplicationIdentity.bundleIDs,
        startsEventMonitoring: Bool = true,
        performsInitialRefresh: Bool = true
    ) {
        self.preferences = preferences
        self.playbackHistory = playbackHistory
        self.discovery = discovery ?? AudioProcessDiscovery(excludedBundleIDs: excludedBundleIDs)
        self.engine = engine
        self.excludedBundleIDs = excludedBundleIDs
        // Rows this app wrote about itself, including under bundle IDs earlier
        // versions used. This is a one-time cleanup, not a live filter.
        let ownBundleIDs = excludedBundleIDs.union(DBDeckApplicationIdentity.legacyBundleIDs)
        let savedSettings = preferences.load()
        let retainedSettings = savedSettings.filter {
            !ownBundleIDs.contains($0.key)
        }
        settings = retainedSettings
        if settings.count != savedSettings.count {
            preferences.save(settings)
        }
        playbackHistory.removeRecords(for: ownBundleIDs)
        if startsEventMonitoring {
            observeWorkspaceEvents()
        }
        // Snapshot after registering: an app that launches in between is then
        // reported by the notification rather than missing from both.
        cacheRunningApplications()
        if startsEventMonitoring {
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
        if performsInitialRefresh {
            refresh()
        }
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
        schedulePreferencesSave()
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
        cacheRunningApplications()
        engine.retryFailures()
        ApplicationDisplayNameResolver.clearCache()
        historicalApplications.retryAllUnavailableApplications()
        refresh()
    }

    func refreshVisiblePlaybackState() {
        do {
            // Compared against what discovery last reported, not against the
            // published list: the published list is filtered and identity
            // resolved, so deriving the baseline from it would never match.
            guard try discovery.processSignature() != lastProcessSignature else { return }
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
            let snapshot = try discovery.snapshot()
            refresh(snapshot: snapshot, now: now)
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

    private func refresh(snapshot: DiscoverySnapshot, now: Date) {
        lastProcessSignature = snapshot.signature
        let activeApps = snapshot.apps.filter {
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
        playbackAccounting = observations.isEmpty ? nil : (observations, now)
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
        runningBundleIDCounts = runningApplicationBundleIDsByPID.values.reduce(into: [:]) {
            counts, bundleID in
            counts[bundleID, default: 0] += 1
        }
        runningBundleIDs = Set(runningBundleIDCounts.keys)
    }

    private func retainRunningBundleID(_ bundleID: String) {
        runningBundleIDCounts[bundleID, default: 0] += 1
        runningBundleIDs.insert(bundleID)
    }

    private func releaseRunningBundleID(_ bundleID: String) {
        guard let count = runningBundleIDCounts[bundleID] else { return }
        if count <= 1 {
            runningBundleIDCounts[bundleID] = nil
            runningBundleIDs.remove(bundleID)
        } else {
            runningBundleIDCounts[bundleID] = count - 1
        }
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
        observeWorkspaceApplication(NSWorkspace.didLaunchApplicationNotification) {
            store, application in
            store.applicationDidLaunch(application)
        }
        observeWorkspaceApplication(NSWorkspace.didTerminateApplicationNotification) {
            store, application in
            store.applicationDidTerminate(application)
        }
        observeWorkspace(NSWorkspace.willSleepNotification) { store in
            store.prepareForSleep()
        }
        observeWorkspace(NSWorkspace.didWakeNotification) { store in
            store.cacheRunningApplications()
            store.refresh()
        }
    }

    /// Delivered on `.main`, so the body is already main-actor isolated.
    private func observeWorkspace(
        _ name: NSNotification.Name,
        _ body: @escaping @MainActor (AppAudioStore) -> Void
    ) {
        workspaceObservers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    body(self)
                }
            }
        )
    }

    private func observeWorkspaceApplication(
        _ name: NSNotification.Name,
        _ body: @escaping @MainActor (AppAudioStore, NSRunningApplication) -> Void
    ) {
        workspaceObservers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication
                else {
                    return
                }
                MainActor.assumeIsolated {
                    guard let self else { return }
                    body(self, application)
                }
            }
        )
    }

    private func applicationDidLaunch(_ application: NSRunningApplication) {
        guard let bundleID = trackedBundleID(of: application) else { return }
        runningApplicationBundleIDsByPID[application.processIdentifier] = bundleID
        retainRunningBundleID(bundleID)
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
        releaseRunningBundleID(bundleID)
        guard playbackHistory.containsRecord(for: bundleID) else { return }
        refresh()
    }

    /// A live timer is what "there are unsaved changes" means here.
    private func schedulePreferencesSave() {
        preferencesSaveTimer?.invalidate()
        preferencesSaveTimer = scheduledTimer(after: 0.25, repeats: false) { store in
            store.persistSettings()
        }
    }

    private func persistSettings() {
        guard preferencesSaveTimer != nil else { return }
        preferencesSaveTimer?.invalidate()
        preferencesSaveTimer = nil
        preferences.save(settings)
    }

    private func accountCurrentPlayback(until now: Date) {
        guard let playbackAccounting else { return }
        let elapsed = max(now.timeIntervalSince(playbackAccounting.since), 0)
        guard elapsed > 0 else { return }
        playbackHistory.observe(playbackAccounting.observations, elapsed: elapsed, now: now)
        self.playbackAccounting = (playbackAccounting.observations, now)
    }

    private func updatePlaybackCheckpointTimer() {
        guard playbackAccounting != nil else {
            playbackCheckpointTimer?.invalidate()
            playbackCheckpointTimer = nil
            return
        }
        guard playbackCheckpointTimer == nil else { return }
        playbackCheckpointTimer = scheduledTimer(after: 60, repeats: true) { store in
            store.refresh()
        }
    }

    private func prepareForSleep() {
        accountCurrentPlayback(until: Date())
        playbackAccounting = nil
        updatePlaybackCheckpointTimer()
    }

    private func startFallbackPolling() {
        fallbackTimer = scheduledTimer(after: 10, repeats: true) { store in
            store.refresh()
        }
    }

    /// Timers scheduled here fire on the main run loop, so the body is already
    /// main-actor isolated and needs no hop.
    private func scheduledTimer(
        after interval: TimeInterval,
        repeats: Bool,
        _ body: @escaping @MainActor (AppAudioStore) -> Void
    ) -> Timer {
        Timer.scheduledTimer(withTimeInterval: interval, repeats: repeats) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                body(self)
            }
        }
    }

    private func publishAppsIfChanged(_ refreshedApps: [AudioApp]) {
        guard apps != refreshedApps else { return }
        apps = refreshedApps
        // Nothing renders a row for an app that is not published, so no view can
        // still be observing its control. Without this the map grows for the
        // lifetime of the process.
        let visibleAppIDs = Set(refreshedApps.map(\.id))
        volumeControls = volumeControls.filter { visibleAppIDs.contains($0.key) }
    }

    private func rebuildVisibleApps(activeApps: [AudioApp], now: Date) {
        let activeAppsByBundleID = Dictionary(
            uniqueKeysWithValues: activeApps.map { ($0.bundleID, $0) }
        )
        let activeBundleIDs = Set(activeAppsByBundleID.keys)
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
