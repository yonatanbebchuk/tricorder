import SwiftUI

/// The house palette (terracotta accent, serif display type) inside an otherwise native look.
enum Theme {
    static let accent = Color(red: 217 / 255, green: 119 / 255, blue: 87 / 255)
    static let ok = Color(red: 79 / 255, green: 127 / 255, blue: 90 / 255)
    static let bad = Color(red: 185 / 255, green: 69 / 255, blue: 44 / 255)
    static let warn = Color.orange

    static func display(_ size: CGFloat = 30) -> Font { .system(size: size, weight: .medium, design: .serif) }
    static let mono = Font.system(.caption, design: .monospaced)
    static let cardRadius: CGFloat = 14
}

extension Status {
    var color: Color {
        switch self {
        case .done: Theme.ok
        case .running: Theme.accent
        case .failed: Theme.bad
        case .interrupted: Theme.warn
        case .cancelled, .skipped: .secondary
        default: Color.secondary.opacity(0.55)
        }
    }
}
