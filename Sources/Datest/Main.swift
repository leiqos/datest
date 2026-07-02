import SwiftUI

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--check") {
            runCLICheck()
        } else if let idx = args.firstIndex(of: "--search"), idx + 1 < args.count {
            runCLISearch(query: args[idx + 1])
        } else {
            DatestApp.main()
        }
    }
}

struct DatestApp: App {
    @StateObject private var model = UpdaterModel()

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(model)
        }
        .windowToolbarStyle(.unified)

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(model)
        } label: {
            Image(systemName: model.updateCount > 0
                ? "arrow.up.circle.fill" : "arrow.up.circle")
            if model.updateCount > 0 {
                Text("\(model.updateCount)")
            }
        }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var model: UpdaterModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let updates = model.allUpdates
        if updates.isEmpty {
            Text(model.isChecking ? "Checking for updates…" : "All apps are up to date")
        } else {
            Text("\(updates.count) update\(updates.count == 1 ? "" : "s") available")
            ForEach(updates) { item in
                if case .updateAvailable(let latest, let url) = item.state {
                    Button("\(item.installed.name)  \(item.installed.displayVersion) → \(latest)") {
                        if item.brewUpdatable {
                            model.brewUpdate(item)
                        } else if let url {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        }
        Divider()
        Button(model.isChecking ? "Checking…" : "Check Now") { model.refresh() }
            .disabled(model.isChecking)
        Button("Open Datest") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("Quit Datest") { NSApp.terminate(nil) }
    }
}

// MARK: - Headless mode: `Latest --check` prints results to stdout.

private func runCLICheck() {
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        let apps = AppScanner.scan()
        print("Scanning \(apps.count) apps…\n")

        var results: [(InstalledApp, CheckState, UpdateSource)] = []
        await withTaskGroup(of: (InstalledApp, CheckState, UpdateSource).self) { group in
            var iterator = apps.makeIterator()
            var active = 0
            func addNext(_ group: inout TaskGroup<(InstalledApp, CheckState, UpdateSource)>) {
                if let app = iterator.next() {
                    active += 1
                    group.addTask {
                        let outcome = await UpdateChecker.check(app)
                        return (app, outcome.state, outcome.via)
                    }
                }
            }
            for _ in 0..<6 { addNext(&group) }
            while active > 0 {
                guard let result = await group.next() else { break }
                active -= 1
                results.append(result)
                addNext(&group)
            }
        }

        results.sort { $0.0.name.localizedCaseInsensitiveCompare($1.0.name) == .orderedAscending }

        var updates = 0
        for (app, state, via) in results {
            let name = app.name.padding(toLength: 32, withPad: " ", startingAt: 0)
            let version = app.displayVersion.padding(toLength: 14, withPad: " ", startingAt: 0)
            let source = via.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)
            switch state {
            case .updateAvailable(let latest, _):
                updates += 1
                print("↑ \(name) \(version) \(source) → \(latest)")
            case .upToDate:
                print("✓ \(name) \(version) \(source) up to date")
            case .unknown(let reason):
                print("? \(name) \(version) \(source) \(reason)")
            case .checking:
                break
            }
        }
        print("\n\(updates) update\(updates == 1 ? "" : "s") available out of \(results.count) apps.")
        semaphore.signal()
    }
    semaphore.wait()
}

// MARK: - Headless mode: `Latest --search <query>` searches the Homebrew catalog.

private func runCLISearch(query: String) {
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        let results = await HomebrewIndex.shared.search(query)
        if results.isEmpty {
            print("No casks matching \"\(query)\".")
        }
        for cask in results {
            let token = cask.token.padding(toLength: 24, withPad: " ", startingAt: 0)
            let name = cask.name.padding(toLength: 28, withPad: " ", startingAt: 0)
            let version = cask.displayVersion.padding(toLength: 16, withPad: " ", startingAt: 0)
            print("\(token) \(name) \(version) \(cask.desc ?? "")")
        }
        semaphore.signal()
    }
    semaphore.wait()
}
