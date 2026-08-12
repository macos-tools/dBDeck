import SwiftUI

struct AppVolumeRow: View {
    let app: AudioApp
    @ObservedObject var control: AppVolumeControl
    let onVolumeChange: (Double) -> Void
    let onToggleMute: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "app.dashed")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    if app.isPlaying {
                        Circle()
                            .fill(.green)
                            .frame(width: 6, height: 6)
                            .help("Playing now")
                    }
                    Text(app.name)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let activityLabel {
                        Text(activityLabel)
                            .font(.caption)
                            .foregroundStyle(app.isPlaying ? .green : .secondary)
                    }
                    Text(setting.isMuted ? "Muted" : "\(Int(setting.volume * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Button {
                        onToggleMute()
                    } label: {
                        Image(systemName: setting.isMuted ? "speaker.slash.fill" : "speaker.wave.1.fill")
                            .frame(width: 16)
                    }
                    .buttonStyle(.plain)
                    .help(setting.isMuted ? "Unmute \(app.name)" : "Mute \(app.name)")

                    Slider(
                        value: Binding(
                            get: { control.setting.volume },
                            set: { onVolumeChange($0) }
                        ),
                        in: 0...AppVolumeSetting.maximumVolume,
                        step: 0.01
                    )
                    .disabled(setting.isMuted)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var activityLabel: String? {
        if app.isPlaying { return "Playing" }
        if app.isRunning { return "Running" }
        return nil
    }

    private var setting: AppVolumeSetting {
        control.setting
    }
}
