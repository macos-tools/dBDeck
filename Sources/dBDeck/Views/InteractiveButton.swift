import SwiftUI

struct InteractiveButton<Label: View>: View {
    let helpText: String
    let contentPadding: EdgeInsets
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var isHovering = false

    init(
        helpText: String,
        contentPadding: EdgeInsets = EdgeInsets(
            top: 5,
            leading: 6,
            bottom: 5,
            trailing: 6
        ),
        action: @escaping () -> Void,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.helpText = helpText
        self.contentPadding = contentPadding
        self.action = action
        self.label = label
    }

    var body: some View {
        Button(action: action) {
            label()
                .padding(contentPadding)
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(InteractiveButtonStyle(isHovering: isHovering))
        .onHover { hovering in
            isHovering = hovering
        }
        .help(helpText)
    }
}

private struct InteractiveButtonStyle: ButtonStyle {
    let isHovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.primary.opacity(backgroundOpacity(isPressed: configuration.isPressed)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(
                        .primary.opacity(borderOpacity(isPressed: configuration.isPressed)),
                        lineWidth: 0.75
                    )
            }
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }

    private func backgroundOpacity(isPressed: Bool) -> Double {
        if isPressed { return 0.22 }
        if isHovering { return 0.13 }
        return 0
    }

    private func borderOpacity(isPressed: Bool) -> Double {
        if isPressed { return 0.28 }
        if isHovering { return 0.20 }
        return 0
    }
}
