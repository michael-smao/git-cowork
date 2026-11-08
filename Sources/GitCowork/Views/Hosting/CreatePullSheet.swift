import GitCoworkCore
import SwiftUI

/// Opens a pull/merge request from a branch on the signed-in host, pushing
/// the branch first if it needs it.
struct CreatePullSheet: View {
    let model: RepoModel
    let branch: String

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var details = ""
    @State private var base: String
    @State private var draft = false
    @State private var working = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    init(model: RepoModel, branch: String) {
        self.model = model
        self.branch = branch
        let defaultBase = model.baseBranchName
        _base = State(initialValue: defaultBase == branch ? "" : defaultBase)
        let tip = model.branch(named: branch)?.target
        _title = State(initialValue: tip.flatMap { model.commit($0)?.subject } ?? branch)
    }

    private var term: String { model.hostStatus?.links.pullRequestTerm ?? "Pull Request" }
    private var pushProblem: String? { model.pushProblem(for: branch) }
    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        SheetScaffold(title: String(localized: "Create \(term)"),
                      confirmTitle: pushProblem == nil ? L("Create") : L("Push and Create"),
                      confirmDisabled: working || trimmedTitle.isEmpty || base.isEmpty || model.busy != nil,
                      error: error, busy: working ? "Creating…" : nil, dismissOnConfirm: false, width: 520,
                      onCancel: { task?.cancel() }) {
            create()
        } content: {
            Text(verbatim: "\(branch) → \(base)")
                .font(Theme.Font.mono)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            TextField("Title", text: $title).textFieldStyle(.roundedBorder)
            PlaceholderEditor(text: $details, placeholder: "Description (optional)", minHeight: 96)
            Picker("Base", selection: $base) {
                ForEach(model.baseOptions(for: branch, keeping: base), id: \.self) { Text($0).tag($0) }
            }
            Toggle("Draft", isOn: $draft).toggleStyle(.checkbox)
            if let pushProblem {
                SheetNotice(symbol: "exclamationmark.triangle.fill", color: .orange, text: pushProblem) { EmptyView() }
            }
        }
        .onDisappear { task?.cancel() }
    }

    private func create() {
        guard let status = model.hostStatus else { return }
        let (title, details, branch, base, draft) = (trimmedTitle, details, branch, base, draft)
        let needsPush = pushProblem != nil
        error = nil
        working = true
        task = Task {
            defer { working = false }
            do {
                if needsPush, await !model.push(branch: branch) {
                    error = String(localized: "Couldn't push \(branch).")
                    return
                }
                let pull = try await status.createPull(title: title, description: details, branch: branch, base: base, draft: draft)
                dismiss()
                model.centerMode = .history
                if model.commitIndex[pull.headSHA] != nil { model.reveal(pull.headSHA) }
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
