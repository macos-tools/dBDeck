import Combine
import Foundation

enum VerificationFailure: Error {
    case failed(String)
}

@main
enum VolumePreferencesVerifier {
    static func main() throws {
        try verifySaveAndLoad()
        try verifyNormalization()
        try verifyPassthroughBoundary()
        try verifyPerAppControlUpdates()
        print("VolumePreferences verification passed")
    }

    private static func verifySaveAndLoad() throws {
        let suiteName = "dBDeckTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw VerificationFailure.failed("Could not create isolated UserDefaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = VolumePreferences(defaults: defaults)

        preferences.save([
            "com.example.music": AppVolumeSetting(volume: 0.42, isMuted: true)
        ])

        let expected = AppVolumeSetting(volume: 0.42, isMuted: true)
        guard preferences.load()["com.example.music"] == expected else {
            throw VerificationFailure.failed("Saved bundle setting did not round-trip")
        }
    }

    private static func verifyNormalization() throws {
        guard AppVolumeSetting(volume: -1, isMuted: false).normalized.volume == 0 else {
            throw VerificationFailure.failed("Lower volume bound was not clamped")
        }
        guard AppVolumeSetting(volume: 2, isMuted: false).normalized.volume == 2 else {
            throw VerificationFailure.failed("Maximum boost was not retained")
        }
        guard AppVolumeSetting(volume: 3, isMuted: false).normalized.volume == 2 else {
            throw VerificationFailure.failed("Upper volume bound was not clamped")
        }
        guard AppVolumeSetting(volume: 1.0000000001, isMuted: false)
            .normalized.volume == 1
        else {
            throw VerificationFailure.failed("100% slider rounding did not snap to passthrough")
        }
    }

    private static func verifyPassthroughBoundary() throws {
        guard !AppVolumeSetting.passthrough.needsProcessing else {
            throw VerificationFailure.failed("100% unmuted audio did not use passthrough")
        }
        guard AppVolumeSetting(volume: 0.999, isMuted: false).needsProcessing else {
            throw VerificationFailure.failed("Sub-100% volume incorrectly used passthrough")
        }
        guard AppVolumeSetting(volume: 1.01, isMuted: false).needsProcessing else {
            throw VerificationFailure.failed("Boosted volume incorrectly used passthrough")
        }
        guard AppVolumeSetting(volume: 1, isMuted: true).needsProcessing else {
            throw VerificationFailure.failed("Muted audio incorrectly used passthrough")
        }
    }

    @MainActor
    private static func verifyPerAppControlUpdates() throws {
        let control = AppVolumeControl(setting: .passthrough)
        let unrelatedControl = AppVolumeControl(setting: .passthrough)
        var updateCount = 0
        var unrelatedUpdateCount = 0
        let updateObservation = control.objectWillChange.sink {
            updateCount += 1
        }
        let unrelatedObservation = unrelatedControl.objectWillChange.sink {
            unrelatedUpdateCount += 1
        }
        defer {
            updateObservation.cancel()
            unrelatedObservation.cancel()
        }

        let adjusted = AppVolumeSetting(volume: 0.42, isMuted: false)
        control.update(adjusted)
        guard control.setting == adjusted,
              updateCount == 1,
              unrelatedUpdateCount == 0
        else {
            throw VerificationFailure.failed("Per-app control updates were not isolated")
        }
    }
}
