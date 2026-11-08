import GitCoworkCore
import SwiftUI

/// The Clone sheet's list of the signed-in accounts' repos. Picking one fills
/// in its HTTPS URL; double-clicking clones it.
struct CloneRepoList: View {
    let accounts: [HostAccount]
    @Binding var url: String
    /// The account whose repo is picked; nil when the URL was typed.
    @Binding var listAccount: HostAccount?
    let onOpen: (String) -> Void

    @State private var accountID: String
    @State private var loaded: [String: [HostRepo]] = [:]
    @State private var errors: [String: String] = [:]
    @State private var filter = ""
    @State private var selection: HostRepo.ID?
    @FocusState private var filterFocused: Bool

    init(accounts: [HostAccount], url: Binding<String>, listAccount: Binding<HostAccount?>, onOpen: @escaping (String) -> Void) {
        self.accounts = accounts
        _url = url
        _listAccount = listAccount
        self.onOpen = onOpen
        _accountID = State(initialValue: accounts.first?.id ?? "")
    }

    private var account: HostAccount? { accounts.first { $0.id == accountID } ?? accounts.first }
    private var all: [HostRepo]? { account.flatMap { loaded[$0.id] } }
    private var shown: [HostRepo] { (all ?? []).filter { $0.matches(filter) } }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                Text("Your Repositories").font(Theme.Font.caption).foregroundStyle(.secondary)
                Spacer()
                if accounts.count > 1 {
                    Picker("Account", selection: $accountID) {
                        ForEach(accounts) { Text(label($0)).tag($0.id) }
                    }
                    .labelsHidden()
                    .fixedSize()
                } else if let account {
                    Text(label(account)).foregroundStyle(.secondary)
                }
            }
            .font(Theme.Font.small)
            SearchField("Filter repositories", text: $filter, focus: $filterFocused, clearHelp: "Clear filter")
            List(shown, selection: $selection) { repo in
                CloneRepoRow(repo: repo).listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, Theme.Metrics.rowHeight)
            .contextMenu(forSelectionType: HostRepo.ID.self, menu: { _ in }) { ids in
                if let id = ids.first, let repo = all?.first(where: { $0.id == id }) {
                    listAccount = account
                    onOpen(repo.cloneURL)
                }
            }
            .overlay { status }
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.cardBorder))
        }
        .task(id: accountID) { await load() }
        .onChange(of: accountID) { selection = nil }
        .onChange(of: selection) {
            if let selection, let repo = all?.first(where: { $0.id == selection }) {
                listAccount = account
                url = repo.cloneURL
            } else {
                listAccount = nil
            }
        }
        .onChange(of: url) {
            // Typing a different URL drops the highlighted repo.
            if let selection, all?.first(where: { $0.id == selection })?.cloneURL != url { self.selection = nil }
        }
    }

    /// Plain text for loading, errors and empty results, as in the other sheets.
    @ViewBuilder private var status: some View {
        if let account {
            if let error = errors[account.id] {
                VStack(spacing: Theme.Space.m) {
                    ErrorText(error).multilineTextAlignment(.center)
                    Button("Try Again") {
                        errors[account.id] = nil
                        Task { await load() }
                    }
                    .controlSize(.small)
                }
                .padding(Theme.Space.l)
            } else if all == nil {
                Text("Loading repositories…").font(Theme.Font.small).foregroundStyle(.secondary)
            } else if all?.isEmpty == true {
                Text("No repositories on \(account.host)").font(Theme.Font.small).foregroundStyle(.secondary)
            } else if shown.isEmpty {
                Text("No matches").font(Theme.Font.small).foregroundStyle(.secondary)
            }
        }
    }

    private func label(_ account: HostAccount) -> String { String(localized: "\(account.username) on \(account.host)") }

    private func load() async {
        guard let account, loaded[account.id] == nil, errors[account.id] == nil else { return }
        do {
            loaded[account.id] = try await RepoList.fetch(for: account)
        } catch is CancellationError {
            // The sheet closed or the account changed; the next .task loads again.
        } catch {
            errors[account.id] = error.localizedDescription
        }
    }
}

private struct CloneRepoRow: View {
    let repo: HostRepo

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: repo.isPrivate ? "lock" : "book.closed")
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .help(repo.isPrivate ? "Private" : "Public")
            Text(repo.fullPath).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: Theme.Space.m)
            if let date = repo.updatedAt {
                Text(Formatters.relative(date))
                    .font(Theme.Font.small)
                    .foregroundStyle(.secondary)
                    .help(Formatters.full(date))
            }
        }
        .font(Theme.Font.body)
        .help(repo.cloneURL)
    }
}
