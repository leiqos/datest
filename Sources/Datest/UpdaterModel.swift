import Foundation
import SwiftUI
import AppKit

enum Panel: Hashable {
    case updates, discover
}

@MainActor
final class UpdaterModel: ObservableObject {
    @Published var selectedPanel: Panel? = .updates
    @Published var items: [AppItem] = []
    @Published var isChecking = false
    @Published var searchText = ""
    @Published var lastChecked: Date?

    // Homebrew operations (install/upgrade/adopt), keyed by cask token.
    // Ops run one at a time — brew refuses to run concurrently with itself.
    @Published var runningOps: [String: BrewService.Operation] = [:]
    @Published var brewError: String?
    @Published var managedTokens: Set<String> = []
    private var opQueue: [(BrewService.Operation, String)] = []
    private var isProcessingQueue = false
    private var batchErrors: [String] = []

    // Discover view.
    @Published var discoverQuery = ""
    @Published var discoverResults: [HomebrewIndex.Cask] = []
    @Published var recommended: [HomebrewIndex.Cask] = []
    @Published var caskIcons: [String: NSImage] = [:]
    @Published var topOpenSource: [HomebrewIndex.RankedCask] = []
    private var iconAttempts: Set<String> = []

    /// Apps whose updates the user chose to ignore (e.g. paid major upgrades).
    @Published var ignoredIDs: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "ignoredAppIDs") ?? []) {
        didSet {
            UserDefaults.standard.set(Array(ignoredIDs).sorted(), forKey: "ignoredAppIDs")
        }
    }

    func toggleIgnore(_ item: AppItem) {
        if ignoredIDs.contains(item.id) {
            ignoredIDs.remove(item.id)
        } else {
            ignoredIDs.insert(item.id)
        }
    }

    private var refreshTask: Task<Void, Never>?

    var filtered: [AppItem] {
        guard !searchText.isEmpty else { return items }
        return items.filter { $0.installed.name.localizedCaseInsensitiveContains(searchText) }
    }

    /// Filtered items minus the ones whose updates the user ignores.
    private var visible: [AppItem] {
        filtered.filter { !ignoredIDs.contains($0.id) }
    }

    var updatesAvailable: [AppItem] {
        visible.filter { if case .updateAvailable = $0.state { return true } else { return false } }
    }
    var upToDate: [AppItem] {
        visible.filter { $0.state == .upToDate }
    }
    var checking: [AppItem] {
        visible.filter { $0.state == .checking }
    }
    var unknown: [AppItem] {
        visible.filter { if case .unknown = $0.state { return true } else { return false } }
    }
    var ignoredItems: [AppItem] {
        filtered.filter { ignoredIDs.contains($0.id) }
    }

    /// All non-ignored updates regardless of the search filter — for the menu bar.
    var allUpdates: [AppItem] {
        items.filter { item in
            guard !ignoredIDs.contains(item.id) else { return false }
            if case .updateAvailable = item.state { return true } else { return false }
        }
    }

    var updateCount: Int { allUpdates.count }

    /// Tokens installed on this Mac (brew-managed or matched to an app).
    var installedTokens: Set<String> {
        managedTokens.union(items.compactMap { $0.cask?.token })
    }

    func installedItem(token: String) -> AppItem? {
        items.first { $0.cask?.token == token }
    }

    /// Updates that Homebrew can install directly.
    var brewUpdatableUpdates: [AppItem] {
        allUpdates.filter(\.brewUpdatable)
    }

    /// Up-to-date apps brew could adopt (non-App-Store, cask exists, unmanaged).
    var adoptableItems: [AppItem] {
        items.filter { $0.state == .upToDate && !$0.brewManaged && $0.brewUpdatable }
    }

    // MARK: - Refresh

    func refresh() {
        refreshTask?.cancel()
        isChecking = true
        managedTokens = BrewService.managedTokens()
        let installed = AppScanner.scan()
        let managed = managedTokens
        items = installed.map { AppItem(installed: $0, state: .checking) }

        refreshTask = Task { [weak self] in
            // Limit concurrency so we don't hammer the iTunes API.
            await withTaskGroup(of: (String, UpdateChecker.Outcome).self) { group in
                var iterator = installed.makeIterator()
                var active = 0
                let maxConcurrent = 6

                func addNext(_ group: inout TaskGroup<(String, UpdateChecker.Outcome)>) {
                    if let app = iterator.next() {
                        active += 1
                        group.addTask {
                            (app.id, await UpdateChecker.check(app))
                        }
                    }
                }

                for _ in 0..<maxConcurrent { addNext(&group) }
                while active > 0 {
                    guard let (id, outcome) = await group.next() else { break }
                    active -= 1
                    if Task.isCancelled { break }
                    await MainActor.run {
                        if let idx = self?.items.firstIndex(where: { $0.id == id }) {
                            self?.items[idx].state = outcome.state
                            self?.items[idx].via = outcome.via
                            self?.items[idx].cask = outcome.cask
                            if let token = outcome.cask?.token {
                                self?.items[idx].brewManaged = managed.contains(token)
                            }
                        }
                    }
                    addNext(&group)
                }
            }
            await MainActor.run {
                self?.isChecking = false
                self?.lastChecked = Date()
            }
        }
    }

    // MARK: - Homebrew operations

    /// Update an app through Homebrew: `upgrade` when brew already manages it,
    /// otherwise a forced install that replaces the existing copy with brew's
    /// checksum-verified download and manages it from then on.
    func brewUpdate(_ item: AppItem) {
        guard let token = item.cask?.token else { return }
        runOperation(item.brewManaged ? .upgrade : .takeOver, token: token)
    }

    /// Register an existing, identical copy with Homebrew (no reinstall).
    func brewAdopt(_ item: AppItem) {
        guard let token = item.cask?.token else { return }
        brewAdopt(token: token)
    }

    func brewAdopt(token: String) {
        runOperation(.adopt, token: token)
    }

    func brewInstall(token: String) {
        runOperation(.install, token: token)
    }

    func updateAll() {
        for item in brewUpdatableUpdates { brewUpdate(item) }
    }

    func adoptAll() {
        for item in adoptableItems { brewAdopt(item) }
    }

    private func runOperation(_ op: BrewService.Operation, token: String) {
        guard runningOps[token] == nil else { return }
        runningOps[token] = op
        opQueue.append((op, token))
        processQueue()
    }

    private func processQueue() {
        guard !isProcessingQueue, !opQueue.isEmpty else { return }
        isProcessingQueue = true
        let (op, token) = opQueue.removeFirst()
        Task {
            do {
                try await BrewService.run(op, token: token)
            } catch {
                batchErrors.append("\(op.label) \(token) failed:\n\(error.localizedDescription)")
            }
            runningOps[token] = nil
            isProcessingQueue = false
            if opQueue.isEmpty {
                if !batchErrors.isEmpty {
                    brewError = batchErrors.joined(separator: "\n\n")
                    batchErrors = []
                }
                refresh()
            } else {
                processQueue()
            }
        }
    }

    // MARK: - Discover

    /// Curated, well-known free apps — resolved against the live catalog so
    /// names, descriptions, and versions stay current.
    static let recommendedTokens: [String] = [
        "rectangle",       // window manager
        "alt-tab",         // windows-style window switcher
        "maccy",           // clipboard history
        "keka",            // archiver
        "appcleaner",      // thorough uninstalls
        "pearcleaner",     // open-source app cleaner
        "iina",            // video player
        "monitorcontrol",  // external display brightness/volume
        "betterdisplay",   // display management
        "shottr",          // screenshots & annotations
        "itsycal",         // menu bar calendar
        "hiddenbar",       // tidy the menu bar
        "obsidian",        // notes
        "zotero",          // reference manager
        "bitwarden",       // password manager
        "handbrake-app",   // video converter
        "transmission",    // torrent client
        "utm",             // virtual machines
        "localsend",       // airdrop for everyone
        "keepingyouawake", // prevent sleep
        "linearmouse",     // mouse customization
        "stats",           // menu bar system monitor
    ]

    func loadRecommended() {
        guard recommended.isEmpty else { return }
        Task {
            var casks: [HomebrewIndex.Cask] = []
            for token in Self.recommendedTokens {
                if let cask = await HomebrewIndex.shared.cask(token: token) {
                    casks.append(cask)
                }
            }
            await MainActor.run { self.recommended = casks }
        }
    }

    /// The Recommended section: curated picks plus open-source apps already on
    /// this Mac, minus anything the Top Open Source ranking already shows —
    /// every app appears in exactly one Discover section.
    var discoverRecommended: [HomebrewIndex.Cask] {
        let topTokens = Set(topOpenSource.map { $0.cask.token })
        var seen = Set<String>()
        return (recommended + installedOpenSource)
            .filter { !topTokens.contains($0.token) && seen.insert($0.token).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func searchCatalog() {
        let query = discoverQuery
        Task {
            let results = query.count >= 2 ? await HomebrewIndex.shared.search(query) : []
            await MainActor.run {
                // Ignore stale results from a superseded query.
                if self.discoverQuery == query { self.discoverResults = results }
            }
        }
    }

    // MARK: - Icons for Discover rows

    /// Installed apps use their real icon; otherwise try the vendor's own site
    /// (apple-touch-icon, then favicon) — no third-party icon service involved.
    func loadIcon(for cask: HomebrewIndex.Cask) {
        let token = cask.token
        guard !iconAttempts.contains(token) else { return }
        iconAttempts.insert(token)

        if let item = installedItem(token: token) {
            caskIcons[token] = NSWorkspace.shared.icon(forFile: item.installed.path.path)
            return
        }
        guard let homepage = cask.homepage,
              let homepageURL = URL(string: homepage),
              let host = homepageURL.host else { return }

        // GitHub-hosted projects: the site favicon is just the octocat — use
        // the project's own avatar instead.
        var candidates: [String]
        if host == "github.com" || host == "www.github.com" {
            let parts = homepageURL.pathComponents.filter { $0 != "/" }
            guard let owner = parts.first else { return }
            candidates = ["https://github.com/\(owner).png?size=128"]
        } else {
            candidates = ["https://\(host)/apple-touch-icon.png",
                          "https://\(host)/favicon.ico"]
        }
        Task { [weak self] in
            for candidate in candidates {
                guard let url = URL(string: candidate),
                      let (data, response) = try? await UpdateChecker.session.data(from: url),
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      let image = NSImage(data: data), image.isValid
                else { continue }
                await MainActor.run { self?.caskIcons[token] = image }
                return
            }
        }
    }

    // MARK: - Open source apps

    /// Open-source apps already installed on this Mac (matched to casks).
    var installedOpenSource: [HomebrewIndex.Cask] {
        var seen = Set<String>()
        return items
            .compactMap(\.cask)
            .filter { $0.isOpenSource && seen.insert($0.token).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func loadTopOpenSource() {
        guard topOpenSource.isEmpty else { return }
        Task {
            let ranked = await HomebrewIndex.shared.topOpenSource(limit: 15)
            await MainActor.run { self.topOpenSource = ranked }
        }
    }
}
