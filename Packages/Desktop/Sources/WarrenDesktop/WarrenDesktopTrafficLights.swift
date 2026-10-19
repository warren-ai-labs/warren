import AppKit
import SwiftUI

/// Superset's macOS traffic lights are drawn by the system into the sidebar
/// header. Warren runs a borderless window so the top chrome is one seamless
/// surface, which means the lights are rendered here instead.
struct WarrenDesktopTrafficLights: View {
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.colorScheme) private var colorScheme
    @State private var isGroupHovered = false

    private enum Light: CaseIterable {
        case close, minimize, fullScreen
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Light.allCases, id: \.self) { light in
                trafficLight(light)
            }
        }
        .padding(.leading, 16)
        // As AppKit draws them: hovering the group shows every light's glyph
        // at once, not only the one under the pointer.
        .onHover { isGroupHovered = $0 }
        .accessibilityElement(children: .contain)
    }

    /// Clicking a SwiftUI control can temporarily clear `keyWindow` for a
    /// borderless window. Resolve the actual visible Warren window instead of
    /// silently dropping the traffic-light action.
    private var targetWindow: NSWindow? {
        NSApp.keyWindow
            ?? NSApp.mainWindow
            ?? NSApp.windows.first { $0.isVisible && $0.styleMask.contains(.closable) }
    }

    private func perform(_ light: Light) {
        switch light {
        case .close:
            // This is an application close, not a daemon shutdown. The
            // daemon owns sessions and remains alive in the menu bar.
            NSApp.terminate(nil)
        case .minimize:
            targetWindow?.miniaturize(nil)
        case .fullScreen:
            targetWindow?.toggleFullScreen(nil)
        }
    }

    /// The system's own fills. SwiftUI's `.red`, `.yellow` and `.green` are
    /// the semantic colours, a step off from the lights every other window
    /// on the desktop wears.
    private func fill(for light: Light) -> Color {
        // A window in the background wears grey lights, so the key window
        // is the only one that reads as live — unless the pointer is on them.
        guard controlActiveState == .key || isGroupHovered else {
            return colorScheme == .dark
                ? Color(red: 0.235, green: 0.235, blue: 0.235)
                : Color(red: 0.855, green: 0.855, blue: 0.855)
        }
        switch light {
        case .close: return Color(red: 1.0, green: 0.373, blue: 0.341)
        case .minimize: return Color(red: 0.996, green: 0.737, blue: 0.180)
        case .fullScreen: return Color(red: 0.157, green: 0.784, blue: 0.251)
        }
    }

    private func glyph(for light: Light) -> String {
        switch light {
        case .close: "xmark"
        case .minimize: "minus"
        case .fullScreen: "arrow.up.left.and.arrow.down.right"
        }
    }

    private func label(for light: Light) -> String {
        switch light {
        case .close: "Close"
        case .minimize: "Minimize"
        case .fullScreen: "Full Screen"
        }
    }

    private func trafficLight(_ light: Light) -> some View {
        Button { perform(light) } label: {
            Circle()
                .fill(fill(for: light))
                .frame(width: 12, height: 12)
                .overlay {
                    Circle()
                        .strokeBorder(.black.opacity(0.12), lineWidth: 0.5)
                }
                .overlay {
                    Image(systemName: glyph(for: light))
                        .font(.system(size: light == .fullScreen ? 6 : 7, weight: .heavy))
                        .foregroundStyle(.black.opacity(0.55))
                        .opacity(isGroupHovered ? 1 : 0)
                        .accessibilityHidden(true)
                }
                .contentShape(Circle())
        }
        .buttonStyle(WarrenDesktopTrafficLightStyle())
        .accessibilityLabel(label(for: light))
    }
}

/// Darkens a light while it is held, as AppKit does.
private struct WarrenDesktopTrafficLightStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(configuration.isPressed ? -0.12 : 0)
    }
}
