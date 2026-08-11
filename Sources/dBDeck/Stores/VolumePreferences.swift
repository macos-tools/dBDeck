import Foundation

final class VolumePreferences {
    private let defaults: UserDefaults
    private let storageKey = "appVolumeSettings.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [String: AppVolumeSetting] {
        guard
            let data = defaults.data(forKey: storageKey),
            let decoded = try? JSONDecoder().decode([String: AppVolumeSetting].self, from: data)
        else {
            return [:]
        }
        return decoded.mapValues(\.normalized)
    }

    func save(_ settings: [String: AppVolumeSetting]) {
        guard let data = try? JSONEncoder().encode(settings.mapValues(\.normalized)) else {
            return
        }
        defaults.set(data, forKey: storageKey)
    }
}
