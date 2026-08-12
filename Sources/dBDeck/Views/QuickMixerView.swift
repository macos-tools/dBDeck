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

            if store.priorityApps.isEmpty {
                ContentUnavailableView(
                    "No Playback History",
                    systemImage: "speaker.wave.2",
                    description: Text("Apps appear here after they produce audio.")
                )
                .frame(height: 180)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(store.priorityApps) { app in
                            AppVolumeRow(app: app, store: store)
                            if app.id != store.priorityApps.last?.id {
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
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("dBDeck")
                    .font(.headline)
                Text("Playing and recent apps")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                store.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh")
        }
        .padding(12)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            Button("Retry") {
                store.retry()
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(.orange.opacity(0.08))
    }

    private var footer: some View {
        HStack {
            Text("Playing · Running · History · Top 5")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Quit") {
                store.quit()
            }
            .buttonStyle(.plain)
        }
        .padding(12)
    }
}
