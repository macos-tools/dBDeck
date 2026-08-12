import Foundation

struct AppVolumeSetting: Codable, Equatable {
    var volume: Double
    var isMuted: Bool

    static let maximumVolume: Double = 2
    static let passthrough = AppVolumeSetting(volume: 1, isMuted: false)

    var normalized: AppVolumeSetting {
        let clampedVolume = min(max(volume, 0), Self.maximumVolume)
        let normalizedVolume = abs(clampedVolume - Self.passthrough.volume) < 1e-9
            ? Self.passthrough.volume
            : clampedVolume
        return AppVolumeSetting(
            volume: normalizedVolume,
            isMuted: isMuted
        )
    }

    var effectiveGain: Float {
        isMuted ? 0 : Float(normalized.volume)
    }

    var needsProcessing: Bool {
        isMuted || normalized.volume != Self.passthrough.volume
    }
}
