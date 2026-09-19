import Combine

/// The observable handle a single mixer row binds to.
///
/// One per application, so moving one slider redraws that row rather than the
/// whole list.
@MainActor
final class AppVolumeControl: ObservableObject {
    @Published private(set) var setting: AppVolumeSetting

    init(setting: AppVolumeSetting) {
        self.setting = setting
    }

    func update(_ setting: AppVolumeSetting) {
        guard self.setting != setting else { return }
        self.setting = setting
    }
}
