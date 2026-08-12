import SwiftUI

struct QuickMixerView: View {
    @ObservedObject var store: AppAudioStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let errorMessage = store.errorMessage {
                errorBanner(errorMessage)
                Divider()
            }

            if store.apps.isEmpty {
                ContentUnavailableView(
                    "No Playback History",
                    systemImage: "speaker.wave.2",
                    description: Text("Apps appear here after they produce audio.")
                )
                .frame(height: 180)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(store.apps) { app in
                            AppVolumeRow(
                                app: app,
                                control: store.volumeControl(for: app),
                                onVolumeChange: { store.setVolume($0, for: app) },
                                onToggleMute: { store.toggleMute(for: app) }
                            )
                            if app.id != store.apps.last?.id {
                                Divider().padding(.leading, 38)
                            }
                        }
                    }
                    .padding(12)
                }
                .frame(maxHeight: 400)
            }

            Divider()
            footer
        }
        .frame(width: 380, height: 430)
        .task {
            store.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                store.refreshVisiblePlaybackState()
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("dBDeck")
                    .font(.headline)
                Text("Playing, running, and playback history")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 12) {
                InteractiveButton(
                    helpText: "Rescan audio apps and playback state.",
                    action: store.manualRefresh
                ) {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 14, height: 14)
                }
                .accessibilityLabel("Refresh audio apps")

                InteractiveButton(
                    helpText: "Reset all volumes to 100%.\n100% uses the least energy.",
                    action: store.resetAllVolumes
                ) {
                    Image(systemName: "arrow.uturn.backward")
                        .frame(width: 14, height: 14)
                }
                .accessibilityLabel("Reset all apps to 100%")
            }
        }
        .padding(.leading, 12)
        .padding(.vertical, 9)
        .padding(.trailing, 16)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            InteractiveButton(
                helpText: "Retry audio setup.",
                contentPadding: EdgeInsets(top: 3, leading: 6, bottom: 3, trailing: 6),
                action: store.retry
            ) {
                Text("Retry")
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(.orange.opacity(0.08))
    }

    private var footer: some View {
        HStack {
            Text("Only apps with playback history are shown")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            InteractiveButton(
                helpText: "Quit dBDeck.",
                contentPadding: EdgeInsets(top: 4, leading: 7, bottom: 4, trailing: 7),
                action: store.quit
            ) {
                Text("Quit")
            }
        }
        .padding(12)
    }
}
