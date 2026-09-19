import Foundation

/// Persists each application's volume and mute state, keyed by bundle
/// identifier so settings survive the application restarting.
final class VolumePreferences {
    private let defaults: UserDefaults
    private let storageKey = "appVolumeSettings.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [String: AppVolumeSetting] {
        defaults.codable([String: AppVolumeSetting].self, forKey: storageKey) ?? [:]
    }

    func save(_ settings: [String: AppVolumeSetting]) {
        defaults.setCodable(settings, forKey: storageKey)
    }
}
