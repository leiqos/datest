import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var model: UpdaterModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedPanel) {
                Label("Updates", systemImage: "arrow.up.circle")
                    .badge(model.updateCount)
                    .tag(Panel.updates)
                Label("Discover", systemImage: "plus.magnifyingglass")
                    .tag(Panel.discover)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170)
        } detail: {
            switch model.selectedPanel ?? .updates {
            case .updates: UpdatesView()
            case .discover: DiscoverView()
            }
        }
        .frame(minWidth: 720, minHeight: 460)
        .onAppear {
            if model.items.isEmpty { model.refresh() }
        }
        .alert("Homebrew", isPresented: Binding(
            get: { model.brewError != nil },
            set: { if !$0 { model.brewError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.brewError ?? "")
        }
    }
}

struct UpdatesView: View {
    @EnvironmentObject var model: UpdaterModel

    var body: some View {
        List {
            if !model.updatesAvailable.isEmpty {
                Section {
                    ForEach(model.updatesAvailable) { AppRow(item: $0) }
                } header: {
                    sectionHeader("Updates Available", count: model.updatesAvailable.count, tint: .orange)
                }
            }
            if !model.checking.isEmpty {
                Section {
                    ForEach(model.checking) { AppRow(item: $0) }
                } header: {
                    sectionHeader("Checking…", count: model.checking.count, tint: .secondary)
                }
            }
            if !model.upToDate.isEmpty {
                Section {
                    ForEach(model.upToDate) { AppRow(item: $0) }
                } header: {
                    sectionHeader("Up to Date", count: model.upToDate.count, tint: .green)
                }
            }
            if !model.unknown.isEmpty {
                Section {
                    ForEach(model.unknown) { AppRow(item: $0) }
                } header: {
                    sectionHeader("No Update Info", count: model.unknown.count, tint: .secondary)
                }
            }
            if !model.ignoredItems.isEmpty {
                Section {
                    ForEach(model.ignoredItems) { AppRow(item: $0) }
                } header: {
                    sectionHeader("Ignored", count: model.ignoredItems.count, tint: .secondary)
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Filter apps")
        .navigationTitle("Updates")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if !model.brewUpdatableUpdates.isEmpty {
                    Button("Update All (\(model.brewUpdatableUpdates.count))") {
                        model.updateAll()
                    }
                    .disabled(!model.runningOps.isEmpty)
                    .help("Install every update Homebrew can handle, one at a time")
                }
                Menu {
                    Button("Adopt \(model.adoptableItems.count) Apps into Homebrew") {
                        model.adoptAll()
                    }
                    .disabled(model.adoptableItems.isEmpty || !model.runningOps.isEmpty)
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .help("Adopting registers apps you already have with Homebrew, so future updates install from here")
                if model.isChecking || !model.runningOps.isEmpty {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        model.refresh()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .help("Check all apps for updates again")
                }
            }
        }
    }

    private var subtitle: String {
        if model.isChecking {
            return "Checking \(model.items.count) apps…"
        }
        let count = model.updateCount
        if count == 0 { return "All apps are up to date" }
        return "\(count) update\(count == 1 ? "" : "s") available"
    }

    private func sectionHeader(_ title: String, count: Int, tint: Color) -> some View {
        HStack(spacing: 6) {
            Text(title)
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(tint.opacity(0.15), in: Capsule())
                .foregroundStyle(tint)
        }
    }
}

struct AppRow: View {
    @EnvironmentObject var model: UpdaterModel
    let item: AppItem

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.installed.name)
                    .fontWeight(.medium)
                versionLine
            }

            Spacer()

            if item.brewManaged {
                badge("brew", tint: .teal)
                    .help("Managed by Homebrew — updates install automatically on request")
            }
            badge(item.sourceLabel, tint: .secondary)

            trailing
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.installed.path])
            }
            if case .updateAvailable(_, let url) = item.state, let url {
                Button("Open Update Page") { NSWorkspace.shared.open(url) }
            }
            if canAdopt {
                Button("Adopt into Homebrew") { model.brewAdopt(item) }
            }
            if let homepage = item.cask?.pageURL {
                Button("Open Homepage") { NSWorkspace.shared.open(homepage) }
            }
            Divider()
            Button(isIgnored ? "Stop Ignoring" : "Ignore Updates for This App") {
                model.toggleIgnore(item)
            }
        }
    }

    private var isIgnored: Bool {
        model.ignoredIDs.contains(item.id)
    }

    /// Registering with brew only works for identical copies, so offer it for
    /// up-to-date, non-App-Store apps that brew doesn't manage yet.
    private var canAdopt: Bool {
        item.state == .upToDate && !item.brewManaged && item.brewUpdatable
    }

    private func helpForManualUpdate(hasURL: Bool) -> String {
        if item.installed.source == .appStore {
            return "Opens the App Store. If the update isn’t shown yet, "
                + "the store list can lag — press ⌘R on its Updates page."
        }
        return hasURL ? "Open the update page" : "Open the app to update it"
    }

    private var icon: NSImage {
        NSWorkspace.shared.icon(forFile: item.installed.path.path)
    }

    @ViewBuilder
    private var versionLine: some View {
        switch item.state {
        case .updateAvailable(let latest, _):
            HStack(spacing: 4) {
                Text(item.installed.displayVersion)
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(latest)
                    .foregroundStyle(.orange)
                    .fontWeight(.semibold)
            }
            .font(.callout)
        case .unknown(let reason):
            Text("\(item.installed.displayVersion) · \(reason)")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        default:
            Text(item.installed.displayVersion)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
            .foregroundStyle(tint)
    }

    @ViewBuilder
    private var trailing: some View {
        if isIgnored {
            Image(systemName: "bell.slash")
                .foregroundStyle(.tertiary)
                .help("Updates for this app are ignored — right-click to resume")
        } else {
            stateTrailing
        }
    }

    @ViewBuilder
    private var stateTrailing: some View {
        switch item.state {
        case .checking:
            ProgressView().controlSize(.small)
        case .upToDate:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .help("Up to date")
        case .updateAvailable(_, let url):
            if let token = item.cask?.token, model.runningOps[token] != nil {
                ProgressView().controlSize(.small)
            } else if item.brewUpdatable {
                Button("Update") { model.brewUpdate(item) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("Update with Homebrew (checksum-verified download)")
            } else {
                Button("Update") {
                    if let url {
                        NSWorkspace.shared.open(url)
                    } else {
                        NSWorkspace.shared.open(item.installed.path)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help(helpForManualUpdate(hasURL: url != nil))
            }
        case .unknown:
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.tertiary)
                .help("Couldn’t determine the latest version")
        }
    }
}
