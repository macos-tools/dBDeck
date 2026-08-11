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
    private let engine = AppAudioEngine()
    private var refreshTimer: Timer?

    init(preferences: VolumePreferences = VolumePreferences()) {
        self.preferences = preferences
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

    func retry() {
        errorMessage = nil
        engine.retryFailures()
        refresh()
    }

    func refresh() {
        do {
            let discoveredApps = try discovery.activeApps()
            apps = discoveredApps
            engine.retainOnly(appIDs: Set(discoveredApps.map(\.id)))

            var firstError: String?
            for app in discoveredApps {
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
        if let message = engine.apply(newSetting, to: app) {
            errorMessage = "\(app.name): \(message)"
        } else {
            errorMessage = nil
        }
    }
}
