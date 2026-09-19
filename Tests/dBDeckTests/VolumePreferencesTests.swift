import Combine
import Foundation
import Testing
@testable import dBDeck

@Suite("Volume preferences")
struct VolumePreferencesTests {
    @Test func saveAndLoadRoundTrip() throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = VolumePreferences(defaults: defaults)

        preferences.save([
            "com.example.music": AppVolumeSetting(volume: 0.42, isMuted: true)
        ])

        #expect(
            preferences.load()["com.example.music"]
                == AppVolumeSetting(volume: 0.42, isMuted: true)
        )
    }

    @Test func normalizationClampsAndSnapsVolume() {
        #expect(AppVolumeSetting(volume: -1, isMuted: false).volume == 0)
        #expect(AppVolumeSetting(volume: 2, isMuted: false).volume == 2)
        #expect(AppVolumeSetting(volume: 3, isMuted: false).volume == 2)
        #expect(AppVolumeSetting(volume: 1.0000000001, isMuted: false).volume == 1)
    }

    @Test func onlyExactlyUnmuted100PercentUsesPassthrough() {
        #expect(!AppVolumeSetting.passthrough.needsProcessing)
        #expect(AppVolumeSetting(volume: 0.999, isMuted: false).needsProcessing)
        #expect(AppVolumeSetting(volume: 1.01, isMuted: false).needsProcessing)
        #expect(AppVolumeSetting(volume: 1, isMuted: true).needsProcessing)
    }

    @Test @MainActor func perAppControlUpdatesAreIsolated() {
        let control = AppVolumeControl(setting: .passthrough)
        let unrelatedControl = AppVolumeControl(setting: .passthrough)
        var updateCount = 0
        var unrelatedUpdateCount = 0
        let updateObservation = control.objectWillChange.sink { updateCount += 1 }
        let unrelatedObservation = unrelatedControl.objectWillChange.sink {
            unrelatedUpdateCount += 1
        }
        defer {
            updateObservation.cancel()
            unrelatedObservation.cancel()
        }

        let adjusted = AppVolumeSetting(volume: 0.42, isMuted: false)
        control.update(adjusted)

        #expect(control.setting == adjusted)
        #expect(updateCount == 1)
        #expect(unrelatedUpdateCount == 0)
    }

    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let suiteName = "dBDeckVolumeTests.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suiteName)), suiteName)
    }
}
