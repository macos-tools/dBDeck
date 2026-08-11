import SwiftUI

struct AppVolumeRow: View {
    let app: AudioApp
    @ObservedObject var store: AppAudioStore

    private var setting: AppVolumeSetting {
        store.setting(for: app)
    }

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
                    Text(app.name)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(setting.isMuted ? "Muted" : "\(Int(setting.volume * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Button {
                        store.toggleMute(for: app)
                    } label: {
                        Image(systemName: setting.isMuted ? "speaker.slash.fill" : "speaker.wave.1.fill")
                            .frame(width: 16)
                    }
                    .buttonStyle(.plain)
                    .help(setting.isMuted ? "Unmute \(app.name)" : "Mute \(app.name)")

                    Slider(
                        value: Binding(
                            get: { setting.volume },
                            set: { store.setVolume($0, for: app) }
                        ),
                        in: 0...1
                    )
                    .disabled(setting.isMuted)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
