import SwiftUI

struct ScanSourceButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        let large = controlSize == .large
        let shape = RoundedRectangle(cornerRadius: 7)
        return configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(foreground)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, large ? 12 : 9)
            .frame(height: large ? 34 : 28)
            .fixedSize()
            .background(background(pressed: configuration.isPressed), in: shape)
            .overlay {
                shape.strokeBorder(border, lineWidth: isFocused ? 2 : 1)
                    .allowsHitTesting(false)
            }
            .contentShape(shape)
            .padding(.horizontal, large ? 0 : 3)
    }

    private var foreground: Color {
        guard isEnabled else { return .primary.opacity(0.38) }
        guard prominent else { return .primary }
        return colorScheme == .dark ? Color(red: 0.04, green: 0.16, blue: 0.13) : .white
    }

    private var border: Color {
        if isFocused { return .accentColor }
        if isEnabled && prominent { return .clear }
        return .primary.opacity(isEnabled ? 0.21 : 0.09)
    }

    private func background(pressed: Bool) -> Color {
        guard isEnabled else { return .primary.opacity(0.045) }
        if prominent {
            let accent = colorScheme == .dark ? Color(red: 0.39, green: 0.78, blue: 0.65) : Design.accent
            return accent.opacity(pressed ? 0.8 : 1)
        }
        return .primary.opacity(pressed ? 0.18 : 0.085)
    }
}
