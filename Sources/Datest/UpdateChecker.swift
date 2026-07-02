import Foundation

enum UpdateChecker {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.httpAdditionalHeaders = ["User-Agent": "Datest/1.0 (macOS update checker)"]
        return URLSession(configuration: config)
    }()

    struct Outcome {
        let state: CheckState
        let via: UpdateSource
        /// Matching Homebrew cask, if any — used for brew-based updates/adoption.
        let cask: HomebrewIndex.Cask?
    }

    static func check(_ app: InstalledApp) async -> Outcome {
        let cask = await HomebrewIndex.shared.lookup(appFileName: app.path.lastPathComponent)
        switch app.source {
        case .sparkle:
            return Outcome(state: await checkSparkle(app), via: .sparkle, cask: cask)
        case .appStore:
            return Outcome(state: await checkAppStore(app), via: .appStore, cask: cask)
        case .unknown, .homebrew:
            // Unknown-source apps might still be listed on the App Store;
            // failing that, try the Homebrew cask catalog.
            let masResult = await checkAppStore(app)
            if case .unknown = masResult {
                if let brewResult = checkAgainstCask(app, cask: cask) {
                    return Outcome(state: brewResult, via: .homebrew, cask: cask)
                }
            }
            return Outcome(state: masResult, via: app.source, cask: cask)
        }
    }

    // MARK: - Homebrew cask catalog

    static func checkAgainstCask(_ app: InstalledApp, cask: HomebrewIndex.Cask?) -> CheckState? {
        guard let cask, let installed = app.shortVersion ?? app.buildVersion else { return nil }
        let latest = cask.displayVersion
        if compareVersions(installed, latest) == .orderedAscending {
            return .updateAvailable(latest: latest, releaseURL: cask.pageURL)
        }
        return .upToDate
    }

    // MARK: - App Store (iTunes Lookup API)

    static func checkAppStore(_ app: InstalledApp) async -> CheckState {
        guard let bundleID = app.bundleID else {
            return .unknown(reason: "No bundle identifier")
        }
        let country = Locale.current.region?.identifier ?? "US"
        var comps = URLComponents(string: "https://itunes.apple.com/lookup")!
        comps.queryItems = [
            URLQueryItem(name: "bundleId", value: bundleID),
            URLQueryItem(name: "country", value: country),
            URLQueryItem(name: "entity", value: "macSoftware"),
        ]
        do {
            let (data, _) = try await session.data(from: comps.url!)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]]
            else {
                return .unknown(reason: "Unexpected App Store response")
            }
            // Only trust Mac listings. Lookups by bundle ID often return just the
            // iOS listing ("kind": "software") whose version numbering has nothing
            // to do with the Mac app's — comparing against it fabricates updates.
            let candidates = results.filter { ($0["version"] as? String) != nil }
            let match = candidates.first { ($0["kind"] as? String) == "mac-software" }
            guard let match, let latest = match["version"] as? String else {
                return .unknown(reason: app.source == .appStore
                    ? "Updates through the App Store"
                    : "No update source")
            }
            let pageURL = (match["trackViewUrl"] as? String).flatMap(URL.init(string:))
            if let installed = app.shortVersion,
               compareVersions(installed, latest) == .orderedAscending {
                return .updateAvailable(latest: latest, releaseURL: pageURL)
            }
            return .upToDate
        } catch {
            return .unknown(reason: "Lookup failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Sparkle appcast

    static func checkSparkle(_ app: InstalledApp) async -> CheckState {
        guard let feedURL = app.sparkleFeedURL else {
            return .unknown(reason: "No Sparkle feed")
        }
        do {
            let (data, _) = try await session.data(from: feedURL)
            let allItems = AppcastParser.parse(data: data)
            guard !allItems.isEmpty else {
                return .unknown(reason: "Empty appcast")
            }
            // Only the default channel: items tagged <sparkle:channel> are opt-in
            // beta/nightly builds. Some feeds skip channel tags, so also prefer
            // versions that don't look like prereleases.
            var items = allItems.filter { $0.channel == nil || $0.channel?.isEmpty == true }
            if items.isEmpty { items = allItems }
            let stable = items.filter { !isPrereleaseVersion($0.bestVersion) }
            if !stable.isEmpty { items = stable }
            // Pick the newest item. Prefer short version strings for comparison
            // since that's what we display; fall back to sparkle:version (build).
            let newest = items.max { a, b in
                compareVersions(a.bestVersion, b.bestVersion) == .orderedAscending
            }!
            let installedShort = app.shortVersion
            let installedBuild = app.buildVersion

            let isNewer: Bool
            if let short = newest.shortVersionString, let installed = installedShort {
                isNewer = compareVersions(installed, short) == .orderedAscending
            } else if let build = newest.version, let installed = installedBuild {
                isNewer = compareVersions(installed, build) == .orderedAscending
            } else if let installed = installedShort ?? installedBuild {
                isNewer = compareVersions(installed, newest.bestVersion) == .orderedAscending
            } else {
                return .unknown(reason: "No installed version to compare")
            }

            if isNewer {
                let display = newest.shortVersionString ?? newest.version ?? newest.bestVersion
                return .updateAvailable(latest: display, releaseURL: newest.link ?? newest.enclosureURL)
            }
            return .upToDate
        } catch {
            return .unknown(reason: "Appcast failed: \(error.localizedDescription)")
        }
    }
}

/// "1.2.0-beta.3", "4.3.4b", "2.0a1", "1.0-rc2" etc.
func isPrereleaseVersion(_ version: String) -> Bool {
    let v = version.lowercased()
    if v.contains("beta") || v.contains("alpha") || v.contains("nightly")
        || v.contains("-rc") || v.contains(".rc") {
        return true
    }
    // Trailing letter (optionally followed by digits) after a digit: "4.3.4b", "2.0a1"
    return v.range(of: #"\d[ab]\d*$"#, options: .regularExpression) != nil
}

// MARK: - Appcast XML parsing

struct AppcastItem {
    var version: String?             // sparkle:version (usually CFBundleVersion)
    var shortVersionString: String?  // sparkle:shortVersionString
    var channel: String?             // sparkle:channel ("beta" etc.; nil = default)
    var enclosureURL: URL?
    var link: URL?

    var bestVersion: String { shortVersionString ?? version ?? "0" }
}

enum AppcastParser {
    static func parse(data: Data) -> [AppcastItem] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.items
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var items: [AppcastItem] = []
        private var current: AppcastItem?
        private var text = ""
        private var currentElement = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            currentElement = name
            text = ""
            switch name {
            case "item":
                current = AppcastItem()
            case "enclosure":
                guard current != nil else { break }
                if let url = attributes["url"] { current?.enclosureURL = URL(string: url) }
                if let v = attributes["sparkle:version"] { current?.version = v }
                if let sv = attributes["sparkle:shortVersionString"] { current?.shortVersionString = sv }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                    qualifiedName: String?) {
            guard current != nil else { return }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "item":
                if let item = current { items.append(item) }
                current = nil
            case "sparkle:version":
                if current?.version == nil, !value.isEmpty { current?.version = value }
            case "sparkle:shortVersionString":
                if current?.shortVersionString == nil, !value.isEmpty { current?.shortVersionString = value }
            case "sparkle:channel":
                if !value.isEmpty { current?.channel = value }
            case "link":
                if !value.isEmpty { current?.link = URL(string: value) }
            default:
                break
            }
        }
    }
}
