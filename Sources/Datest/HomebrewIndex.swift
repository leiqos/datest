import Foundation

/// Matches installed apps against Homebrew's cask catalog
/// (https://formulae.brew.sh) — a community-maintained database of current
/// versions for thousands of Mac apps — and provides catalog search for the
/// Discover view. Homebrew does not need to be installed to *check* versions;
/// this only reads the public JSON API over HTTPS.
actor HomebrewIndex {
    static let shared = HomebrewIndex()

    struct Cask: Identifiable, Hashable {
        let token: String
        let name: String        // primary display name
        let desc: String?
        let version: String
        let homepage: String?
        let appFileNames: [String]  // "Ghostty.app" etc.

        var id: String { token }

        /// Cask versions append a build/checksum after a comma ("1.2.3,4567").
        var displayVersion: String {
            version.components(separatedBy: ",").first ?? version
        }

        var pageURL: URL? {
            if let homepage, let url = URL(string: homepage),
               url.scheme == "https" || url.scheme == "http" {
                return url
            }
            return URL(string: "https://formulae.brew.sh/cask/\(token)")
        }
    }

    struct RankedCask: Identifiable {
        let rank: Int
        let installs: String  // formatted 30-day install count, e.g. "52,623"
        let cask: Cask
        // Distinct from plain CaskRow ids: the same cask must not share a row
        // identity with another List section, or SwiftUI mixes the rows up.
        var id: String { "top-\(cask.token)" }
    }

    /// Most-installed open-source apps, ranked by Homebrew's public 30-day
    /// install analytics (formulae.brew.sh/analytics).
    func topOpenSource(limit: Int = 15) async -> [RankedCask] {
        await ensureLoaded()
        guard let items = await Self.loadAnalytics() else { return [] }
        var ranked: [RankedCask] = []
        for item in items {
            guard let token = item["cask"] as? String,
                  let count = item["count"] as? String,
                  let cask = byToken[token], cask.isOpenSource
            else { continue }
            ranked.append(RankedCask(rank: ranked.count + 1, installs: count, cask: cask))
            if ranked.count >= limit { break }
        }
        return ranked
    }

    private static let catalogURL = URL(string: "https://formulae.brew.sh/api/cask.json")!
    private static let analyticsURL = URL(string: "https://formulae.brew.sh/api/analytics/cask-install/30d.json")!
    private static let cacheMaxAge: TimeInterval = 24 * 60 * 60

    private var byAppFileName: [String: Cask] = [:]  // key: "google chrome.app" (lowercased)
    private var byToken: [String: Cask] = [:]
    private var allCasks: [Cask] = []
    private var loaded = false
    private var loadFailed = false

    /// Looks up a cask by the app bundle's filename, e.g. "Ghostty.app".
    func lookup(appFileName: String) async -> Cask? {
        await ensureLoaded()
        return byAppFileName[appFileName.lowercased()]
    }

    func cask(token: String) async -> Cask? {
        await ensureLoaded()
        return byToken[token]
    }

    /// Case-insensitive catalog search over name, token, and description.
    func search(_ query: String, limit: Int = 40) async -> [Cask] {
        await ensureLoaded()
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.count >= 2 else { return [] }

        func rank(_ cask: Cask) -> Int? {
            let name = cask.name.lowercased()
            if name.hasPrefix(q) || cask.token.hasPrefix(q) { return 0 }
            if name.contains(q) || cask.token.contains(q) { return 1 }
            if cask.desc?.lowercased().contains(q) == true { return 2 }
            return nil
        }

        return allCasks
            .compactMap { cask in rank(cask).map { (cask, $0) } }
            .sorted { ($0.1, $0.0.name.lowercased()) < ($1.1, $1.0.name.lowercased()) }
            .prefix(limit)
            .map(\.0)
    }

    // MARK: - Loading

    private func ensureLoaded() async {
        guard !loaded && !loadFailed else { return }
        if let casks = await Self.loadCatalog() {
            allCasks = casks
            for cask in casks {
                if byToken[cask.token] == nil { byToken[cask.token] = cask }
                for file in cask.appFileNames {
                    let key = file.lowercased()
                    if byAppFileName[key] == nil { byAppFileName[key] = cask }
                }
            }
            loaded = true
        } else {
            loadFailed = true
        }
    }

    private static var cacheFile: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Datest/cask.json")
    }

    private static var analyticsCacheFile: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Datest/analytics.json")
    }

    private static func loadAnalytics() async -> [[String: Any]]? {
        func parseItems(_ data: Data) -> [[String: Any]]? {
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["items"] as? [[String: Any]], !items.isEmpty
            else { return nil }
            return items
        }
        if let data = cachedData(analyticsCacheFile), let items = parseItems(data) {
            return items
        }
        guard let (data, response) = try? await UpdateChecker.session.data(from: analyticsURL),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let items = parseItems(data)
        else { return nil }
        try? FileManager.default.createDirectory(
            at: analyticsCacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: analyticsCacheFile)
        return items
    }

    private static func loadCatalog() async -> [Cask]? {
        if let data = cachedData(cacheFile), let casks = parse(data) {
            return casks
        }
        guard let (data, response) = try? await UpdateChecker.session.data(from: catalogURL),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let casks = parse(data)
        else { return nil }
        // Best effort — an unwritable cache just means re-downloading next launch.
        try? FileManager.default.createDirectory(
            at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheFile)
        return casks
    }

    private static func cachedData(_ file: URL) -> Data? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              let modified = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) < cacheMaxAge
        else { return nil }
        return try? Data(contentsOf: file)
    }

    private static func parse(_ data: Data) -> [Cask]? {
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        var casks: [Cask] = []
        for entry in entries {
            guard let token = entry["token"] as? String,
                  let version = entry["version"] as? String,
                  version.lowercased() != "latest",  // unversioned cask; nothing to compare
                  entry["deprecated"] as? Bool != true,
                  entry["disabled"] as? Bool != true,
                  let artifacts = entry["artifacts"] as? [Any]
            else { continue }

            var appFileNames: [String] = []
            for artifact in artifacts {
                guard let dict = artifact as? [String: Any],
                      let apps = dict["app"] as? [Any] else { continue }
                for app in apps {
                    // Entries are either "Name.app" or {"target": "Name.app"}.
                    let name = (app as? String)
                        ?? (app as? [String: Any])?["target"] as? String
                    if let name, name.hasSuffix(".app") {
                        appFileNames.append((name as NSString).lastPathComponent)
                    }
                }
            }
            guard !appFileNames.isEmpty else { continue }  // pkg-only casks etc.

            let names = entry["name"] as? [String]
            casks.append(Cask(
                token: token,
                name: names?.first ?? token,
                desc: entry["desc"] as? String,
                version: version,
                homepage: entry["homepage"] as? String,
                appFileNames: appFileNames
            ))
        }
        return casks.isEmpty ? nil : casks
    }
}

extension HomebrewIndex.Cask {
    /// Well-known open-source casks whose homepage isn't a code forge.
    private static let knownOpenSourceTokens: Set<String> = [
        "ghostty", "signal", "lulu", "iina", "keka", "maccy", "obs",
        "localsend", "firefox", "brave-browser", "libreoffice", "utm",
        "rectangle", "itsycal", "monitorcontrol", "handbrake-app", "audacity",
        "gimp", "inkscape", "bitwarden", "keepingyouawake", "thunderbird",
        "vlc", "veracrypt", "syncthing-app", "nextcloud", "element", "iterm2",
        "blender", "godot", "kicad", "zed", "chromium",
    ]

    var isOpenSource: Bool {
        if Self.knownOpenSourceTokens.contains(token) { return true }
        guard let homepage = homepage?.lowercased() else { return false }
        return homepage.contains("github.com") || homepage.contains("gitlab.com")
            || homepage.contains("codeberg.org") || homepage.contains("sourceforge.net")
    }
}
