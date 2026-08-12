import Combine

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
