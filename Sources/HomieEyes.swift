import AppKit
import SwiftUI

/// The notch eyes' color (chosen in onboarding or Customize). Public: the notch draws with it in every build.
enum HomieEyes: String, CaseIterable {
    case classic, starlight, mint, ocean, lilac
    static let key = "pixie.eyes"
    static let changed = Notification.Name("PixieSkinChanged")   // the notch redraws on the same signal as skins
    private static var cached: HomieEyes?
    static var current: HomieEyes {
        get { if let cached { return cached }; let v = HomieEyes(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .classic; cached = v; return v }
        set { cached = newValue; UserDefaults.standard.set(newValue.rawValue, forKey: key); NotificationCenter.default.post(name: changed, object: nil) }
    }
    var title: String { ["classic": "Classic", "starlight": "Starlight", "mint": "Mint", "ocean": "Ocean", "lilac": "Lilac"][rawValue]! }
    var vibe: String { ["classic": "the og. sees everything.", "starlight": "a night owl. glows after dark.", "mint": "fresh. calm. never stressed.", "ocean": "a deep thinker.", "lilac": "a little dreamy."][rawValue]! }
    var rgb: (Double, Double, Double) {
        switch self {
        case .classic: (1, 1, 1)
        case .starlight: (1, 0.84, 0.32)
        case .mint: (0.56, 1, 0.78)
        case .ocean: (0.52, 0.80, 1)
        case .lilac: (0.84, 0.72, 1)
        }
    }
    var color: Color { Color(red: rgb.0, green: rgb.1, blue: rgb.2) }
    var ns: NSColor { NSColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1) }
}
