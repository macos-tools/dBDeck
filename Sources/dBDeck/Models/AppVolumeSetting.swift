import Foundation

struct AppVolumeSetting: Codable, Equatable {
    var volume: Double
    var isMuted: Bool

    static let passthrough = AppVolumeSetting(volume: 1, isMuted: false)

    var normalized: AppVolumeSetting {
        AppVolumeSetting(volume: min(max(volume, 0), 1), isMuted: isMuted)
    }

    var effectiveGain: Float {
        isMuted ? 0 : Float(normalized.volume)
    }

    var needsProcessing: Bool {
        isMuted || normalized.volume < 1
    }
}
