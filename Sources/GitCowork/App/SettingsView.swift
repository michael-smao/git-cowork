import SwiftUI

struct SettingsView: View {
    @AppStorage(Prefs.Key.appearance) private var appearance = AppAppearance.system
    @State private var language = AppLanguage.saved
    @AppStorage(Prefs.Key.editorApp) private var editorApp = "Visual Studio Code"
    @AppStorage(Prefs.Key.terminalApp) private var terminalApp = "Terminal"
    @AppStorage(Prefs.Key.hostOverrides) private var hostOverrides = ""
    @AppStorage(Prefs.Key.coworkAutoSync) private var coworkAutoSync = true
    @AppStorage(Prefs.Key.autoFetch) private var autoFetch = true
    @AppStorage(Prefs.Key.checkForUpdates) private var checkForUpdates = true

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Language", selection: $language) {
                    ForEach(AppLanguage.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                // Only the built app can reopen itself (and has the translations).
                if language != AppLanguage.atLaunch, Updater.shared.current != nil {
                    HStack {
                        Text("Restart git-cowork to use it. Your open repositories reopen.")
                            .font(Theme.Font.small).foregroundStyle(.secondary)
                        Spacer()
                        Button("Restart Now") { Updater.shared.relaunch() }
                    }
                }
            }
            AccountsSection()
            Section("Apps") {
                TextField("Editor", text: $editorApp, prompt: Text("Visual Studio Code, Cursor, Zed…"))
                TextField("Terminal", text: $terminalApp, prompt: Text("Terminal, iTerm, Ghostty, Warp…"))
                Text("Application names as they appear in /Applications.")
                    .font(Theme.Font.small).foregroundStyle(.secondary)
            }
            Section("Self-hosted servers") {
                TextEditor(text: $hostOverrides)
                    .font(Theme.Font.mono)
                    .frame(height: 80)
                Text("One per line: host = github | gitlab | gitea | forgejo. Used for \"Open on…\" and \"Create Pull/Merge Request\" links. github.com, and hosts with gitlab, gitea or forgejo in their name, are detected automatically.")
                    .font(Theme.Font.small).foregroundStyle(.secondary)
            }
            Section("Cowork") {
                Toggle("Sync tasks automatically", isOn: $coworkAutoSync)
                Text("Tasks, reviews and comments live on the hidden ref refs/cowork/main and are fetched and pushed with plain git, about once a minute while git-cowork is in front. Turn this off to sync only from the status bar or Repository > Sync Tasks Now.")
                    .font(Theme.Font.small).foregroundStyle(.secondary)
                Text("Each repository syncs with the remote in git config cowork.remote, the same one git cowork uses. Without it, git-cowork picks a remote that already has tasks, else origin, and saves the choice there. To change it: git config cowork.remote <name>")
                    .font(Theme.Font.small).foregroundStyle(.secondary)
            }
            Section("Git") {
                Toggle("Fetch automatically", isOn: $autoFetch)
                Text("Runs git fetch --all --prune for each open repository every 5 minutes while git-cowork is in front, so remote branches and ahead/behind stay current. It never asks for a password: if signing in fails, it pauses until you sign in under Accounts or a fetch, pull or push of yours works.")
                    .font(Theme.Font.small).foregroundStyle(.secondary)
                LabeledContent("Executable", value: GitRunner.shared.gitPath)
            }
            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $checkForUpdates)
                Text("Once a day, git-cowork asks GitHub for the newest release. Nothing about you or your repositories is sent. When there's a new version, the status bar offers to install it.")
                    .font(Theme.Font.small).foregroundStyle(.secondary)
                LabeledContent("Version", value: Updater.shared.current?.description ?? "development build")
            }
        }
        .formStyle(.grouped)
        .onChange(of: appearance) { _, new in new.apply() }
        .onChange(of: language) { _, new in new.save() }
        // Fixed width, flexible height: the form scrolls when the window is
        // shorter than it (on smaller screens it is taller than the screen).
        .frame(width: 520)
        .frame(minHeight: 360, idealHeight: 720, maxHeight: .infinity)
    }
}
