import SwiftUI

/// Shared launcher design tokens. Source-specific views should reference these names rather
/// than borrowing colors from another source's indicator type.
///
/// The system is deliberately desaturated: neutral surfaces and a three-tier text ramp carry
/// the layout; the accents are dimmed to ~60–70% saturation so they sit *in* the surface
/// instead of vibrating off it, and they only ever appear on a state glyph or a selection
/// rail — never on whole words.
enum HelmColors {
    // MARK: Surfaces
    static let surface      = Color(red: 0.067, green: 0.067, blue: 0.075)  // #111113
    static let surfaceHover = Color(red: 0.102, green: 0.102, blue: 0.118)  // #1A1A1E
    static let hairline     = Color.white.opacity(0.08)

    // MARK: Text tiers
    static let textPrimary   = Color(red: 0.910, green: 0.910, blue: 0.918) // #E8E8EA — titles
    static let textSecondary = Color(red: 0.604, green: 0.604, blue: 0.627) // #9A9AA0 — context
    static let textTertiary  = Color(red: 0.369, green: 0.369, blue: 0.400) // #5E5E66 — time/hints

    // MARK: Accents — state only, never on whole words
    static let amber   = Color(red: 0.851, green: 0.643, blue: 0.255)  // #D9A441
    static let emerald = Color(red: 0.420, green: 0.639, blue: 0.408)  // #6BA368
    static let red     = Color(red: 0.851, green: 0.412, blue: 0.353)  // #D9695A
    static let violet  = Color(red: 0.565, green: 0.502, blue: 0.722)
    static let rose    = Color(red: 0.780, green: 0.471, blue: 0.522)
    static let slate   = Color(red: 0.486, green: 0.510, blue: 0.557)
    static let gray    = textTertiary
}
