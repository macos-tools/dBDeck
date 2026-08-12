import AppIntents
import SwiftUI
import WidgetKit

@main
struct dBDeckControlsBundle: WidgetBundle {
    var body: some Widget {
        dBDeckMixerControl()
    }
}

struct dBDeckMixerControl: ControlWidget {
    private static let mixerURL = URL(string: "dbdeck://mixer")!

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.dbdeck.app.control.mixer") {
            ControlWidgetButton(action: OpenURLIntent(Self.mixerURL)) {
                Label("App Volume", systemImage: "speaker.wave.2.fill")
            }
        }
        .displayName("dBDeck")
        .description("Open your five highest-priority app volume controls.")
    }
}
