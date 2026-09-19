import Foundation

/// One application's volume, from silent through unity to `maximumVolume`
/// (+6 dB).
///
/// Unmuted unity is the passthrough case: the application is left untouched,
/// with no tap and no processing, which is both the cheapest state and the one
/// with no effect on audio quality.
struct AppVolumeSetting: Codable, Equatable {
    static let maximumVolume: Double = 2
    static let passthrough = AppVolumeSetting(volume: 1, isMuted: false)

    /// The volume, held normalized so no un-normalized value of this type can
    /// exist: clamped to `0...maximumVolume`, and snapped to exactly 1 when
    /// close enough that the difference is inaudible.
    ///
    /// The snap matters because exactly 1 unmuted is what `needsProcessing`
    /// tests to decide that an application can be left alone entirely.
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
