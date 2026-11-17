import GitCoworkCore
import SwiftUI

/// Creates a release on the signed-in host for a tag, or for a new tag at a
/// commit. The tag is pushed first (nothing happens if it's there already);
/// then the release's page opens in the browser.
struct CreateReleaseSheet: View {
    let model: RepoModel
    /// An existing tag, or nil to make one at `sha`.
    let existingTag: String?
    let sha: String

    @Environment(\.dismiss) private var dismiss
    @State private var tag: String
    @State private var title: String
    @State private var notes = ""
    @State private var notesEdited = false
    @State private var draft = false
    @State private var prerelease = false
    @State private var working = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    init(model: RepoModel, tag: String?, sha: String) {
        self.model = model
        existingTag = tag
        self.sha = sha
        let name = tag ?? ReleaseDraft.nextTag(after: model.tags.map(\.name)) ?? ""
        _tag = State(initialValue: name)
        _title = State(initialValue: name)
    }

    private var host: String { model.hostStatus?.links.host ?? "" }
    private var trimmedTag: String { tag.trimmingCharacters(in: .whitespaces) }
    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespaces) }
    private var tagTaken: Bool { existingTag == nil && model.tags.contains { $0.name == trimmedTag } }
    private var hasDraftOptions: Bool { model.hostStatus?.accountKind.map(HostAPI.releaseHasDraftAndPrerelease) ?? true }
    private var remote: String { model.defaultRemote ?? "origin" }
    private var short: String { String(sha.prefix(7)) }

    var body: some View {
        SheetScaffold(title: String(localized: "Create Release on \(host)"),
                      confirmTitle: existingTag == nil ? L("Create Tag and Release") : L("Create Release"),
                      confirmDisabled: working || !RefName.isValid(trimmedTag) || tagTaken || trimmedTitle.isEmpty || model.busy != nil,
                      error: error, busy: working ? "Creating…" : nil, dismissOnConfirm: false, width: 520,
                      onCancel: { task?.cancel() }) {
            create()
        } content: {
            Grid(alignment: .leading, horizontalSpacing: Theme.Space.m, verticalSpacing: Theme.Space.m) {
                GridRow {
                    Text("Tag").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    if let existingTag {
                        Text(verbatim: "\(existingTag) · \(short)").font(Theme.Font.mono)
                    } else {
                        TextField("Tag name, e.g. v1.2.0", text: $tag).textFieldStyle(.roundedBorder)
                    }
                }
                if tagTaken {
                    GridRow {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        NameTaken(text: String(localized: "A tag named \(trimmedTag) already exists."))
                    }
                }
                GridRow {
                    Text("Title").foregroundStyle(.secondary)
                    TextField("Title", text: $title).textFieldStyle(.roundedBorder)
                }
            }
            PlaceholderEditor(text: Binding(get: { notes }, set: { notes = $0; notesEdited = true }),
                              placeholder: "Release notes (optional)", minHeight: 140, maxHeight: 280)
            if hasDraftOptions {
                HStack(spacing: Theme.Space.l) {
                    Toggle("Draft", isOn: $draft).toggleStyle(.checkbox)
                    Toggle("Pre-release", isOn: $prerelease).toggleStyle(.checkbox)
                }
            }
            Text(existingTag == nil
                 ? String(localized: "Creates the tag \(trimmedTag) at \(short) and pushes it to \(remote) first.")
                 : String(localized: "Pushes \(trimmedTag) to \(remote) first, if it isn't there yet."))
                .font(Theme.Font.small)
                .foregroundStyle(.secondary)
        }
        .task {
            // The commits since the last tag; kept if the user typed already.
            let draftNotes = await model.releaseNotes(upTo: existingTag.map { "refs/tags/\($0)" } ?? sha)
            if !notesEdited { notes = draftNotes }
        }
        .onChange(of: tag) { old, new in
            // The title follows the tag until it's changed by hand.
            if title == old { title = new }
        }
        .onDisappear { task?.cancel() }
    }

    private func create() {
        let (tag, title, notes, draft, prerelease) = (trimmedTag, trimmedTitle, notes, hasDraftOptions && draft, hasDraftOptions && prerelease)
        error = nil
        working = true
        task = Task {
            defer { working = false }
            do {
                let page = try await model.createRelease(tag: tag, at: sha, title: title, notes: notes, draft: draft, prerelease: prerelease)
                dismiss()
                External.browse(page)
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
