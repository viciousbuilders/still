import SwiftUI

enum StillStyle {
    static func accent(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.43, green: 0.84, blue: 0.74) : Color(red: 0.06, green: 0.38, blue: 0.32)
    }
    static func secondary(_ scheme: ColorScheme) -> Color {
        let value = scheme == .dark ? 0.70 : 0.38
        return Color(red: value, green: value, blue: value)
    }
    static let surface = Color(nsColor: .controlBackgroundColor)
}

struct StillPrimaryButton: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .semibold))
            .frame(maxWidth: .infinity).frame(height: 40)
            .foregroundStyle(enabled ? (scheme == .dark ? Color(nsColor: .windowBackgroundColor) : Color(nsColor: .textBackgroundColor)) : Color.secondary)
            .background(enabled ? StillStyle.accent(scheme) : Color(nsColor: .quaternaryLabelColor), in: RoundedRectangle(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct TreeProgressView: View {
    let progress: Double
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Image(systemName: "tree.fill").resizable().scaledToFit()
            .foregroundStyle(StillStyle.accent(scheme).opacity(0.13))
            .overlay(alignment: .bottom) {
                GeometryReader { geometry in
                    Image(systemName: "tree.fill").resizable().scaledToFit().foregroundStyle(StillStyle.accent(scheme))
                        .mask(alignment: .bottom) { Rectangle().frame(height: geometry.size.height * min(1, max(0.06, progress))) }
                }
            }.accessibilityHidden(true)
    }
}

struct InlineError: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Error: \(message)")
    }
}
