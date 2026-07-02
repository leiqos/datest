import SwiftUI
import AppKit

struct DiscoverView: View {
    @EnvironmentObject var model: UpdaterModel

    var body: some View {
        List {
            if !BrewService.available {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Homebrew is not installed")
                                .fontWeight(.medium)
                            Text("Installing and updating apps from here requires Homebrew.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Open brew.sh") {
                            NSWorkspace.shared.open(URL(string: "https://brew.sh")!)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            if model.discoverQuery.trimmingCharacters(in: .whitespaces).count >= 2 {
                Section("Search Results") {
                    if model.discoverResults.isEmpty {
                        Text("No matching apps in the Homebrew catalog")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.discoverResults) { CaskRow(cask: $0) }
                    }
                }
            } else {
                if !model.topOpenSource.isEmpty {
                    Section {
                        ForEach(model.topOpenSource) { ranked in
                            CaskRow(cask: ranked.cask, rank: ranked.rank, installs: ranked.installs)
                        }
                    } header: {
                        Text("Top Open Source Apps")
                    } footer: {
                        Text("Ranked by Homebrew installs over the last 30 days.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    ForEach(model.discoverRecommended) { CaskRow(cask: $0) }
                } header: {
                    Text("Recommended")
                } footer: {
                    Text("Curated free apps, plus open-source apps already on your Mac (adopt them for one-click updates). Installs run through Homebrew, which verifies every download against its SHA-256 checksum.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .searchable(text: $model.discoverQuery, placement: .toolbar,
                    prompt: "Search the Homebrew catalog")
        .onChange(of: model.discoverQuery) { _ in model.searchCatalog() }
        .navigationTitle("Discover")
        .onAppear {
            model.loadRecommended()
            model.loadTopOpenSource()
        }
    }
}

struct CaskRow: View {
    @EnvironmentObject var model: UpdaterModel
    let cask: HomebrewIndex.Cask
    var rank: Int?
    var installs: String?

    var body: some View {
        HStack(spacing: 10) {
            if let rank {
                Text("\(rank)")
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .frame(width: 22, alignment: .trailing)
            }
            avatar

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(cask.name)
                        .fontWeight(.medium)
                    homepageLink
                }
                if let desc = cask.desc {
                    Text(desc)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 1) {
                Text(cask.displayVersion)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                if let installs {
                    Text("\(installs) installs")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            trailing
        }
        .padding(.vertical, 3)
        .contextMenu {
            if let url = cask.pageURL {
                Button("Open Homepage") { NSWorkspace.shared.open(url) }
            }
            Button("View on formulae.brew.sh") {
                NSWorkspace.shared.open(URL(string: "https://formulae.brew.sh/cask/\(cask.token)")!)
            }
        }
    }

    private var avatar: some View {
        Group {
            if let image = model.caskIcons[cask.token] {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            } else {
                RoundedRectangle(cornerRadius: 7)
                    .fill(.quaternary)
                    .overlay {
                        Text(String(cask.name.prefix(1)).uppercased())
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: 34, height: 34)
        .onAppear { model.loadIcon(for: cask) }
    }

    @ViewBuilder
    private var homepageLink: some View {
        if let url = cask.pageURL {
            let isGitHub = (cask.homepage ?? "").lowercased().contains("github.com")
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                HStack(spacing: 2) {
                    if isGitHub {
                        Text("GitHub").font(.caption)
                    }
                    Image(systemName: "arrow.up.right.square").font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(cask.homepage ?? "Project page")
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if let op = model.runningOps[cask.token] {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(op.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if model.managedTokens.contains(cask.token) {
            Label("Installed", systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
        } else if let item = model.installedItem(token: cask.token) {
            if !item.brewUpdatable {
                // App Store installs stay on the App Store channel; root-owned
                // apps (e.g. Parallels) can't be taken over by brew.
                Text(item.installed.source == .appStore ? "Installed (App Store)" : "Installed")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    Text("Installed")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Adopt") { model.brewAdopt(token: cask.token) }
                        .controlSize(.small)
                        .disabled(!BrewService.available)
                        .help("Let Homebrew manage the copy you already have — future updates install from here")
                }
            }
        } else {
            Button("Install") { model.brewInstall(token: cask.token) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!BrewService.available)
                .help("Install with Homebrew (checksum-verified download)")
        }
    }
}
