import SwiftUI

// Avoid SDK 27 macro overloads when building with the Command Line Tools.
// The public property-wrapper implementation remains supported on macOS 14+.
typealias ViewState<Value> = SwiftUI.State<Value>

enum IslandStyle {
    static let primary = Color.white
    static let body = Color(hex: 0xdcdcdc)
    static let secondary = Color(hex: 0x979797)
    static let green = Color(hex: 0x31cf76)
    static let cyan = Color(hex: 0x8bdee8)
    static let blue = Color(hex: 0x91c8ff)
    static let orange = Color(hex: 0xff9412)
    static let red = Color(hex: 0xff6069)
    static let settingsGreen = Color(hex: 0x4b6f5a)
    static let settingsText = Color(hex: 0x141414)
    static let settingsMuted = Color(hex: 0x838280)
    static let settingsBorder = Color(hex: 0xe6e6e6)
    static let bodyFont = Font.system(size: 12)
    static let openAnimation = Animation.interpolatingSpring(mass: 1, stiffness: 320, damping: 32)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 255) / 255,
                  green: Double((hex >> 8) & 255) / 255,
                  blue: Double(hex & 255) / 255, opacity: 1)
    }
}

struct IslandActionStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(primary ? Color(hex: 0x141414) : IslandStyle.secondary)
            .padding(.horizontal, 12).frame(minHeight: 28)
            .background(primary ? Color(hex: 0xf2f2f2) : Color.clear, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .opacity(enabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// These controls keep the reference colours when the workbench is not key.
struct SettingsSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Capsule()
                .fill(configuration.isOn ? IslandStyle.settingsGreen : IslandStyle.settingsBorder)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle().fill(.white).frame(width: 16, height: 16).padding(2)
                        .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                }
                .frame(width: 32, height: 20)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.45)
        .animation(.easeInOut(duration: 0.16), value: configuration.isOn)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.switch)
        }
    }
}

struct SettingsSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let label: String
    var step: Double = 5
    @Environment(\.isEnabled) private var enabled
    @FocusState private var focused: Bool

    private let thumbSize: CGFloat = 18
    private var progress: Double {
        guard range.upperBound > range.lowerBound else { return 0 }
        return min(1, max(0, (value - range.lowerBound) / (range.upperBound - range.lowerBound)))
    }

    var body: some View {
        GeometryReader { geometry in
            let travel = max(0, geometry.size.width - thumbSize)
            let center = thumbSize / 2 + travel * progress
            ZStack(alignment: .leading) {
                Capsule().fill(Color(hex: 0xededed)).frame(height: 8)
                Capsule().fill(IslandStyle.settingsGreen).frame(width: center, height: 8)
                Circle().fill(.white)
                    .overlay(Circle().stroke(IslandStyle.settingsGreen, lineWidth: 2))
                    .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                    .frame(width: thumbSize, height: thumbSize)
                    .offset(x: center - thumbSize / 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                guard enabled else { return }
                focused = true
                let fraction = travel > 0 ? (event.location.x - thumbSize / 2) / travel : 0
                setValue(range.lowerBound + Double(fraction) * (range.upperBound - range.lowerBound))
            })
        }
        .frame(height: 22)
        .opacity(enabled ? 1 : 0.45)
        .focusable(enabled)
        .focused($focused)
        .focusEffectDisabled()
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(IslandStyle.settingsGreen.opacity(focused ? 0.45 : 0), lineWidth: 2).padding(-3))
        .onMoveCommand { direction in
            guard enabled else { return }
            switch direction {
            case .left, .down: setValue(value - step)
            case .right, .up: setValue(value + step)
            default: break
            }
        }
        .accessibilityRepresentation {
            Slider(value: $value, in: range, step: step) { Text(label) }
                .accessibilityValue("\(Int(value))%")
        }
    }

    private func setValue(_ proposed: Double) {
        let snapped = range.lowerBound + ((proposed - range.lowerBound) / step).rounded() * step
        value = min(range.upperBound, max(range.lowerBound, snapped))
    }
}

struct IslandShell: Shape {
    var notch: Bool
    var expansion: CGFloat

    init(notch: Bool, expanded: Bool) { self.notch = notch; self.expansion = expanded ? 1 : 0 }
    init(notch: Bool, expansion: CGFloat) { self.notch = notch; self.expansion = expansion }
    var animatableData: CGFloat {
        get { expansion }
        set { expansion = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let progress = min(1, max(0, expansion))
        guard notch else { return Path(roundedRect: rect, cornerRadius: 16 + 8 * progress) }
        let shoulder = min(6 + 13 * progress, rect.width / 4)
        let radius = min(14 + 10 * progress, max(0, rect.height - shoulder), max(0, (rect.width - 2 * shoulder) / 2))
        let left = shoulder, right = rect.width - shoulder
        var p = Path()
        p.move(to: .zero)
        p.addLine(to: CGPoint(x: rect.width, y: 0))
        p.addCurve(to: CGPoint(x: right, y: shoulder), control1: CGPoint(x: right, y: 0), control2: CGPoint(x: right, y: 0))
        p.addLine(to: CGPoint(x: right, y: rect.height - radius))
        p.addQuadCurve(to: CGPoint(x: right - radius, y: rect.height), control: CGPoint(x: right, y: rect.height))
        p.addLine(to: CGPoint(x: left + radius, y: rect.height))
        p.addQuadCurve(to: CGPoint(x: left, y: rect.height - radius), control: CGPoint(x: left, y: rect.height))
        p.addLine(to: CGPoint(x: left, y: shoulder))
        p.addCurve(to: .zero, control1: CGPoint(x: left, y: 0), control2: CGPoint(x: left, y: 0))
        p.closeSubpath()
        return p
    }
}

