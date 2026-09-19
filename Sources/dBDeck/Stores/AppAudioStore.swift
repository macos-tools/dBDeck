import AppKit
import Combine
import CoreAudio
import Foundation
import OSLog

/// The state behind the mixer: which applications to show, what volume each is
/// set to, and whether anything is wrong.
///
/// Everything here is reconciled rather than incrementally patched. A refresh
/// takes one discovery snapshot and, from it, credits playback time, rebuilds
/// the visible list, and brings the live audio routes into line with the stored
/// settings. Anything that could have changed the world therefore only has to
/// trigger a refresh, not describe what it changed.
///
/// Those triggers are: Core Audio property changes via `AudioActivityMonitor`,
/// application launch and termination and sleep and wake via `NSWorkspace`, a
/// once-a-second check while the panel is open, a ten-second fallback poll used
/// only if Core Audio monitoring could not be started, and the user asking
/// directly.
///
/// The visible list is not the same as the playing list. Applications stay
/// listed after they stop playing, ordered playing first, then running, then by
/// accumulated playback time, so the control you want is where you left it.
/// `PlaybackHistoryStore` owns that history and `HistoricalApplicationResolver`
/// turns its rows back into displayable applications.
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
    // Which applications are running, tracked from launch and terminate
    // notifications. One application can hold several PIDs, so membership is
    // reference counted: the bundle ID leaves the set when its last one does.
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
        // The mixer never lists itself, so any stored row about itself is
        // stale data to discard at startup rather than something to filter on
        // every read.
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
        // Registration precedes the snapshot so the two overlap. An
        // application appearing between them is reported by the notification;
        // the reverse order would let it fall between the two and be treated as
        // not running for the rest of the session.
        cacheRunningApplications()
        if startsEventMonitoring {
            do {
                audioMonitor = try AudioActivityMonitor { [weak self] change in
                    Task { @MainActor in
                        guard let self else { return }
                        if change.contains(.defaultOutputDevice) {
                            // Routes are built against a specific device, so a
                            // new one is a fresh attempt rather than a repeat of
                            // whatever failed on the last.
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
            // The baseline is what discovery last reported, not the published
            // list. The published list has been filtered and identity resolved,
            // so a process that is discovered but never shown would register as
            // a difference on every single check.
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

    /// The bundle ID to track this application under, or `nil` if the mixer
    /// ignores it — background-only processes, anything without a bundle
    /// identifier, and the mixer itself.
    ///
    /// Callers keying by PID must tolerate duplicates: applications without a
    /// pid all report `-1`.
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

    /// Observes a workspace notification for as long as this store exists.
    ///
    /// Delivery is requested on the main queue, which is what lets the body run
    /// as main-actor isolated without hopping.
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

    /// Coalesces rapid setting changes into one write.
    ///
    /// Dragging a slider produces a change per frame, and each would otherwise
    /// re-encode and store every setting. A pending timer is also the record
    /// that unsaved changes exist, so `persistSettings` has nothing else to
    /// consult.
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
        // Playback time is credited from the interval between reconciliations,
        // so a long uninterrupted stretch of playing needs a periodic mark to
        // stay accounted for. Only the clock advances here; noticing change is
        // the activity monitor's job.
        playbackCheckpointTimer = scheduledTimer(after: 60, repeats: true) { store in
            store.accountCurrentPlayback(until: Date())
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

    /// Schedules a timer whose body runs as main-actor isolated.
    ///
    /// `Timer.scheduledTimer` installs on the current run loop, which here is
    /// always the main one, so the body is already on the main actor.
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
        // Controls are created on demand per row and observed by that row, so
        // the published list bounds which ones can still have an observer.
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
