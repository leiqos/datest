import Foundation

enum UpdateSource: String {
    case appStore = "App Store"
    case sparkle = "Sparkle"
    case homebrew = "Homebrew"
    case unknown = "Unknown"
}

struct InstalledApp: Identifiable, Hashable {
    let path: URL
    let name: String
    let bundleID: String?
    let shortVersion: String?
    let buildVersion: String?
    let source: UpdateSource
    let sparkleFeedURL: URL?
    /// False for root-owned bundles (e.g. Parallels) that Homebrew, running as
    /// the user, cannot replace — those must update through their own installer.
    let isUserWritable: Bool

    var id: String { path.path }

    /// Best human-readable installed version.
    var displayVersion: String {
        shortVersion ?? buildVersion ?? "—"
    }
}

enum CheckState: Equatable {
    case checking
    case upToDate
    case updateAvailable(latest: String, releaseURL: URL?)
    case unknown(reason: String)
}

struct AppItem: Identifiable {
    let installed: InstalledApp
    var state: CheckState = .checking
    /// The source that actually answered (e.g. Homebrew for an app with no feed).
    var via: UpdateSource?
    /// Matching Homebrew cask, if the catalog has one for this app.
    var cask: HomebrewIndex.Cask?
    /// True when Homebrew already manages this app (present in the Caskroom).
    var brewManaged = false

    var id: String { installed.id }

    var sourceLabel: String { (via ?? installed.source).rawValue }

    /// Brew can update this app: it has a cask, isn't an App Store install
    /// (those should keep updating through the App Store), and either brew
    /// already manages it or the bundle is replaceable by the current user.
    var brewUpdatable: Bool {
        cask != nil && installed.source != .appStore && BrewService.available
            && (brewManaged || installed.isUserWritable)
    }
}

/// Compares two version strings component-wise, numerically where possible.
/// "1.10" > "1.9", "2.0.1" > "2.0", "1.0b2" handled via string fallback per component.
func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
    // Strip a leading "v" and anything after whitespace ("2.1 (Build 7)" -> "2.1").
    func clean(_ s: String) -> [String] {
        var s = s.trimmingCharacters(in: .whitespaces)
        if s.lowercased().hasPrefix("v") { s = String(s.dropFirst()) }
        if let space = s.firstIndex(where: { $0 == " " || $0 == "(" }) {
            s = String(s[..<space])
        }
        return s.split(separator: ".").map(String.init)
    }
    let ca = clean(a), cb = clean(b)
    for i in 0..<max(ca.count, cb.count) {
        let pa = i < ca.count ? ca[i] : "0"
        let pb = i < cb.count ? cb[i] : "0"
        if let na = Int(pa), let nb = Int(pb) {
            if na != nb { return na < nb ? .orderedAscending : .orderedDescending }
        } else if pa != pb {
            // Numeric part beats non-numeric of same position when prefixes match
            // (e.g. "1" vs "1b2"); otherwise plain string comparison.
            let result = pa.compare(pb, options: .numeric)
            if result != .orderedSame { return result }
        }
    }
    return .orderedSame
}
