import SwiftUI

/// Shared launcher palette. Source-specific views should reference these names rather than
/// borrowing colors from another source's indicator type.
enum HelmColors {
    static let emerald = Color(red: 0.204, green: 0.827, blue: 0.600)
    static let amber   = Color(red: 0.984, green: 0.749, blue: 0.141)
    static let violet  = Color(red: 0.655, green: 0.545, blue: 0.980)
    static let rose    = Color(red: 0.961, green: 0.451, blue: 0.522)
    static let red     = Color(red: 0.937, green: 0.357, blue: 0.357)
    static let slate   = Color(red: 0.553, green: 0.624, blue: 0.722)
    static let gray    = Color.white.opacity(0.28)
}
