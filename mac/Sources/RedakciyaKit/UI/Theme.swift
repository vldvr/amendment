import AppKit
import SwiftUI

/// Tokens from design/direction.md. The marker is the only accent.
enum Theme {
    static func dynamic(_ light: UInt32, _ dark: UInt32, alpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return rgb(isDark ? dark : light, alpha: alpha)
        })
    }

    static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    static let ink = dynamic(0x16181B, 0xE8E7E2)
    static let paper = dynamic(0xEDECE7, 0x1B1D20)
    static let sheet = dynamic(0xF8F8F6, 0x232528)
    static let graphite = dynamic(0x55585D, 0xA4A6AA)
    static let rule = dynamic(0xCFCDC6, 0x3A3C40)
    static let markerEdge = dynamic(0xC98A00, 0xFFC21A)
    static let markerFill = Color(nsColor: NSColor(name: nil) { a in
        rgb(0xFFC21A, alpha: a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 0.30 : 0.42)
    })
    static let primary = dynamic(0x16181B, 0xE8E7E2)
    static let onPrimary = dynamic(0xF8F8F6, 0x16181B)
    static let secondaryFill = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? rgb(0xE8E7E2, alpha: 0.09) : rgb(0x16181B, alpha: 0.07)
    })
}

/// Buttons as in the mockups: radius 7, primary is ink, secondary a light wash.
struct CardButtonStyle: ButtonStyle {
    var primary = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 12)
            .frame(height: 28)
            .foregroundStyle(primary ? Theme.onPrimary : Theme.ink)
            .background(RoundedRectangle(cornerRadius: 7).fill(primary ? Theme.primary : Theme.secondaryFill))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Rectangle())
    }
}
