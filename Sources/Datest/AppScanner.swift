import Foundation

enum AppScanner {
    /// Directories scanned for .app bundles (top level only).
    static var searchDirectories: [URL] {
        var dirs = [URL(fileURLWithPath: "/Applications")]
        let home = FileManager.default.homeDirectoryForCurrentUser
        dirs.append(home.appendingPathComponent("Applications"))
        return dirs
    }

    static func scan() -> [InstalledApp] {
        let fm = FileManager.default
        var apps: [InstalledApp] = []
        for dir in searchDirectories {
            guard let contents = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in contents where url.pathExtension == "app" {
                if let app = readApp(at: url) {
                    apps.append(app)
                }
            }
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func readApp(at url: URL) -> InstalledApp? {
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }

        let name = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent

        let bundleID = info["CFBundleIdentifier"] as? String
        let shortVersion = info["CFBundleShortVersionString"] as? String
        let buildVersion = info["CFBundleVersion"] as? String

        var feedURL: URL?
        if let feed = info["SUFeedURL"] as? String {
            feedURL = URL(string: feed.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let hasMASReceipt = FileManager.default.fileExists(
            atPath: url.appendingPathComponent("Contents/_MASReceipt/receipt").path
        )

        let source: UpdateSource
        if hasMASReceipt {
            source = .appStore
        } else if feedURL != nil {
            source = .sparkle
        } else {
            source = .unknown
        }

        return InstalledApp(
            path: url,
            name: name,
            bundleID: bundleID,
            shortVersion: shortVersion,
            buildVersion: buildVersion,
            source: source,
            sparkleFeedURL: feedURL,
            isUserWritable: FileManager.default.isWritableFile(atPath: url.path)
        )
    }
}
