import Foundation

struct AppVolumeSetting: Codable, Equatable {
    static let maximumVolume: Double = 2
    static let passthrough = AppVolumeSetting(volume: 1, isMuted: false)

    /// Always normalized: clamped to 0...maximumVolume and snapped to exactly
    /// 1 near passthrough, so no un-normalized value of this type can exist.
    private var storedVolume: Double
    var isMuted: Bool

    var volume: Double {
        get { storedVolume }
        set { storedVolume = Self.normalized(newValue) }
    }

    var effectiveGain: Float {
        isMuted ? 0 : Float(storedVolume)
    }

    var needsProcessing: Bool {
        isMuted || storedVolume != Self.passthrough.volume
    }

    init(volume: Double, isMuted: Bool) {
        storedVolume = Self.normalized(volume)
        self.isMuted = isMuted
    }

    private static func normalized(_ volume: Double) -> Double {
        let clampedVolume = min(max(volume, 0), maximumVolume)
        return abs(clampedVolume - 1) < 1e-9 ? 1 : clampedVolume
    }

    private enum CodingKeys: String, CodingKey {
        case volume
        case isMuted
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        storedVolume = Self.normalized(try container.decode(Double.self, forKey: .volume))
        isMuted = try container.decode(Bool.self, forKey: .isMuted)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(storedVolume, forKey: .volume)
        try container.encode(isMuted, forKey: .isMuted)
    }
}
