import SwiftUI

enum NoctweaveAppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.stars.fill"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct NoctweaveThemeTokens {
    let colorScheme: ColorScheme

    var isDark: Bool { colorScheme == .dark }

    var canvas: Color {
        isDark
            ? Color(red: 18.0 / 255.0, green: 11.0 / 255.0, blue: 15.0 / 255.0)
            : Color(red: 250.0 / 255.0, green: 246.0 / 255.0, blue: 242.0 / 255.0)
    }

    var canvasRaised: Color {
        isDark
            ? Color.noctweavePlumBlack
            : Color(red: 1.0, green: 253.0 / 255.0, blue: 251.0 / 255.0)
    }

    var surface: Color {
        isDark ? Color.black.opacity(0.24) : Color.white.opacity(0.68)
    }

    var surfaceRaised: Color {
        isDark ? Color.black.opacity(0.34) : Color.white.opacity(0.86)
    }

    var field: Color {
        isDark
            ? Color.black.opacity(0.28)
            : Color(red: 247.0 / 255.0, green: 238.0 / 255.0, blue: 233.0 / 255.0).opacity(0.88)
    }

    var border: Color {
        isDark ? Color.white.opacity(0.14) : Color.noctweaveWine.opacity(0.18)
    }

    var borderStrong: Color {
        isDark ? Color.white.opacity(0.24) : Color.noctweaveWine.opacity(0.30)
    }

    var selectedFill: Color {
        isDark ? Color.noctweaveWine.opacity(0.34) : Color.noctweaveCoral.opacity(0.15)
    }

    var selectedText: Color {
        isDark ? Color.white : Color.noctweavePlumBlack
    }

    var shadow: Color {
        isDark ? Color.black.opacity(0.26) : Color.noctweaveWine.opacity(0.10)
    }
}

extension Color {
    static let noctweaveIvory = Color(red: 250.0 / 255.0, green: 243.0 / 255.0, blue: 234.0 / 255.0)
    static let noctweaveSand = Color(red: 235.0 / 255.0, green: 199.0 / 255.0, blue: 175.0 / 255.0)
    static let noctweaveCoral = Color(red: 201.0 / 255.0, green: 106.0 / 255.0, blue: 97.0 / 255.0)
    static let noctweaveWine = Color(red: 146.0 / 255.0, green: 45.0 / 255.0, blue: 53.0 / 255.0)
    static let noctweavePlumBlack = Color(red: 27.0 / 255.0, green: 18.0 / 255.0, blue: 23.0 / 255.0)
}
