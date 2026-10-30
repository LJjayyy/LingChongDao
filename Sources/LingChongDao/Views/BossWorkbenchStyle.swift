import SwiftUI

/// The workbench's paper-and-copper palette. Island surfaces and status tokens
/// stay independent so source pets and task urgency retain their meaning.
enum BossWorkbenchStyle {
    static let canvas = Color(hex: 0xFAF8F4)
    static let sidebar = Color(hex: 0xF1ECE5)
    static let text = Color(hex: 0x302B27)
    static let muted = Color(hex: 0x786E65)
    static let copper = Color(hex: 0xA76C43)
    static let copperText = Color(hex: 0x895634)
    static let selected = Color(hex: 0xEFE2D1)
    static let border = Color(hex: 0xE6DED4)
    static let paper = Color.white
}

struct BossCardSurface: ViewModifier {
    var radius: CGFloat = 14
    func body(content: Content) -> some View {
        content
            .background(BossWorkbenchStyle.paper, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(BossWorkbenchStyle.border, lineWidth: 1))
    }
}

extension View {
    func bossCard(radius: CGFloat = 14) -> some View { modifier(BossCardSurface(radius: radius)) }
}

struct BossButtonStyle: ButtonStyle {
    enum Kind: Equatable { case primary, secondary, quiet }
    var kind: Kind = .secondary
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: kind == .primary ? .semibold : .medium))
            .foregroundStyle(kind == .primary ? Color.white : (kind == .quiet ? BossWorkbenchStyle.copperText : BossWorkbenchStyle.text))
            .padding(.horizontal, kind == .quiet ? 5 : 12)
            .frame(minHeight: 30)
            .background(background(pressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(kind == .secondary ? BossWorkbenchStyle.border : .clear, lineWidth: 1))
            .opacity(enabled ? 1 : 0.45)
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private func background(pressed: Bool) -> Color {
        switch kind {
        case .primary: return pressed ? BossWorkbenchStyle.copperText.opacity(0.9) : BossWorkbenchStyle.copperText
        case .secondary: return pressed ? BossWorkbenchStyle.selected : BossWorkbenchStyle.paper
        case .quiet: return pressed ? BossWorkbenchStyle.selected.opacity(0.7) : .clear
        }
    }
}

/// Used where the view already draws its own surface, such as navigation and
/// the mascot button. Feedback never changes the hit region or nearby layout.
struct BossPressStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(enabled ? 1 : 0.45)
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
