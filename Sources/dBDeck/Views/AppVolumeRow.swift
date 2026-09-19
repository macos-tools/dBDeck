import SwiftUI

/// One application's row: icon, name, playback state, and the volume and mute
/// controls.
///
/// The slider runs to 200%, so the readout and the mute state are shown as text
/// as well; a slider position alone does not distinguish quiet from muted.
struct AppVolumeRow: View {
    let app: AudioApp
    @ObservedObject var control: AppVolumeControl
    let onVolumeChange: (Double) -> Void
    let onToggleMute: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: app.icon)
                .resizable()
                .scaledToFit()
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    if app.isPlaying {
                        Circle()
                            .fill(.green)
                            .frame(width: 6, height: 6)
                            .help(String(localized: "Playing now"))
                    }
                    Text(app.name)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let activityLabel {
                        Text(activityLabel)
                            .font(.caption)
                            .foregroundStyle(app.isPlaying ? .green : .secondary)
                    }
                    Text(
                        setting.isMuted
                            ? String(localized: "Muted")
                            : "\(Int(setting.volume * 100))%"
                    )
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    InteractiveButton(
                        helpText: muteHelpText,
                        contentPadding: EdgeInsets(
                            top: 4,
                            leading: 4,
                            bottom: 4,
                            trailing: 4
                        ),
                        action: onToggleMute
                    ) {
                        Image(systemName: setting.isMuted ? "speaker.slash.fill" : "speaker.wave.1.fill")
                            .frame(width: 16)
                    }

                    Slider(
                        value: Binding(
                            get: { control.setting.volume },
                            set: { onVolumeChange(Self.draggedVolume($0)) }
                        ),
                        in: 0...AppVolumeSetting.maximumVolume
                    )
                    .disabled(setting.isMuted)
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// How close to 100% counts as 100%.
    ///
    /// Unmuted 100% is passthrough: no tap, no processing, least energy. On a
    /// continuous 0-200% track that exact point is a single pixel, so the
    /// slider detents onto it rather than leaving it unreachable by hand.
    private static let passthroughSnap = 0.05

    /// Quantizes a slider position to the resolution the row displays, so the
    /// readout does not wander while the value under it does.
    private static func draggedVolume(_ volume: Double) -> Double {
        let passthrough = AppVolumeSetting.passthrough.volume
        guard abs(volume - passthrough) > passthroughSnap else { return passthrough }
        return (volume * 100).rounded() / 100
    }

    private var activityLabel: String? {
        if app.isPlaying { return String(localized: "Playing") }
        if app.isRunning { return String(localized: "Running") }
        return nil
    }

    private var muteHelpText: String {
        let format = setting.isMuted
            ? String(localized: "Unmute %@")
            : String(localized: "Mute %@")
        return String(format: format, locale: .current, app.name)
    }

    private var setting: AppVolumeSetting {
        control.setting
    }
}
