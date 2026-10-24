import SwiftUI
import UIKit
import MisescaKit

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }

    static func dynamic(light: UInt32, dark: UInt32) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) }
    }
}

/// The Misesca palette: linen, ink, brass, sage, terracotta, slate.
/// Dark values are the same hues lifted for dim ballrooms.
enum Palette {
    static let uiBackground = UIColor.dynamic(light: 0xFAF8F4, dark: 0x17191C)
    static let uiSurface = UIColor.dynamic(light: 0xF1ECE3, dark: 0x22252A)
    static let uiInk = UIColor.dynamic(light: 0x1F2328, dark: 0xF1EEE8)
    static let uiSecondary = UIColor.dynamic(light: 0x5B6168, dark: 0xAAB0B7)
    static let uiRule = UIColor.dynamic(light: 0xDDD6CA, dark: 0x33373D)
    static let uiBrass = UIColor.dynamic(light: 0xA8793A, dark: 0xC99B5C)
    static let uiSage = UIColor.dynamic(light: 0x4F7D5C, dark: 0x76A684)
    static let uiTerracotta = UIColor.dynamic(light: 0xC2553D, dark: 0xDD7760)
    static let uiSlate = UIColor.dynamic(light: 0x6B7A8F, dark: 0x8F9DB1)
    static let uiOnAccent = UIColor.dynamic(light: 0xFFFFFF, dark: 0x17191C)

    static let background = Color(uiBackground)
    static let surface = Color(uiSurface)
    static let ink = Color(uiInk)
    static let secondary = Color(uiSecondary)
    static let rule = Color(uiRule)
    static let brass = Color(uiBrass)
    static let sage = Color(uiSage)
    static let terracotta = Color(uiTerracotta)
    static let slate = Color(uiSlate)
    static let onAccent = Color(uiOnAccent)

    /// Fixed, non-adaptive values for AR materials and PDF output.
    enum Fixed {
        static let linen = UIColor(hex: 0xFAF8F4)
        static let ink = UIColor(hex: 0x1F2328)
        static let secondary = UIColor(hex: 0x5B6168)
        static let rule = UIColor(hex: 0xDDD6CA)
        static let brass = UIColor(hex: 0xA8793A)
        static let sage = UIColor(hex: 0x4F7D5C)
        static let terracotta = UIColor(hex: 0xC2553D)
        static let slate = UIColor(hex: 0x6B7A8F)
    }
}

extension EventStatus {
    var color: Color {
        switch self {
        case .notStarted: return Palette.secondary
        case .setting: return Palette.brass
        case .enPlace: return Palette.sage
        case .needsAttention: return Palette.terracotta
        }
    }
}

extension Font {
    /// New York, for names of things: events, screens, section heads.
    static func heading(_ style: Font.TextStyle = .title2) -> Font {
        .system(style, design: .serif).weight(.semibold)
    }
}

extension UIFont {
    static func serif(_ style: UIFont.TextStyle, weight: UIFont.Weight = .semibold) -> UIFont {
        let base = UIFont.preferredFont(forTextStyle: style)
        let weighted = base.fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]])
        let descriptor = weighted.withDesign(.serif) ?? weighted
        return UIFont(descriptor: descriptor, size: base.pointSize)
    }

    static func serif(size: CGFloat, weight: UIFont.Weight = .semibold) -> UIFont {
        let d = UIFont.systemFont(ofSize: size, weight: weight).fontDescriptor
        return UIFont(descriptor: d.withDesign(.serif) ?? d, size: size)
    }
}

enum Appearance {
    /// Serif titles in the navigation bar. Only fonts and colors are set so the system bar keeps its own layout.
    static func apply() {
        let bar = UINavigationBar.appearance()
        bar.titleTextAttributes = [.font: UIFont.serif(.headline), .foregroundColor: Palette.uiInk]
        bar.largeTitleTextAttributes = [.font: UIFont.serif(.largeTitle, weight: .bold), .foregroundColor: Palette.uiInk]
    }
}

enum Format {
    static let eventDate: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE MMM d h:mm a")
        return f
    }()

    static let checkTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static func inches(_ v: Double) -> String { "\(Int(v.rounded())) in" }
}
