import SwiftUI

enum MetzStyle {
    static let background = Color(red: 12/255, green: 17/255, blue: 24/255)
    static let sidebar = Color(red: 16/255, green: 23/255, blue: 32/255)
    static let panel = Color(red: 23/255, green: 33/255, blue: 45/255)
    static let hover = Color(red: 31/255, green: 43/255, blue: 57/255)
    static let accent = Color(red: 110/255, green: 168/255, blue: 1)
    static let line = Color(red: 38/255, green: 49/255, blue: 62/255)
    static let secondary = Color(red: 185/255, green: 196/255, blue: 208/255)
    static let success = Color(red: 78/255, green: 217/255, blue: 160/255)
    static let pagePadding: CGFloat = 24
}

struct MetzButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 12).frame(minHeight: 34)
            .foregroundStyle(primary ? MetzStyle.background : Color.primary)
            .background(primary ? MetzStyle.accent : (configuration.isPressed ? MetzStyle.hover : MetzStyle.panel), in: RoundedRectangle(cornerRadius: 7))
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
    }
}

struct MetzPageTitle: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 24, weight: .semibold))
            if let subtitle { Text(subtitle).font(.callout).foregroundStyle(MetzStyle.secondary) }
        }
    }
}
