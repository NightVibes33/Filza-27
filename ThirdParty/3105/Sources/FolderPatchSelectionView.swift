import SwiftUI

struct FolderPatchSelectionView: View {
    @Environment(\.appLanguage) private var language
    @Environment(\.dismiss) private var dismiss
    let containerRoot: URL
    let folder: URL
    let onCreate: ([PatchDraftCandidate]) -> Void

    @State private var candidates: [PatchDraftCandidate] = []
    @State private var selectedIDs = Set<String>()
    @State private var isLoading = true
    @State private var validationMessageKey: String?

    private var selectedCandidates: [PatchDraftCandidate] {
        candidates.filter { selectedIDs.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView(language.text("patch.folder_scanning"))
                } else if candidates.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "folder")
                            .font(.system(size: 36, weight: .light))
                            .foregroundStyle(.secondary)
                        Text(language.text("patch.folder_empty"))
                            .font(.headline)
                        Text(language.text("patch.folder_empty_message"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                } else {
                    fileList
                }
            }
            .navigationTitle(language.text("patch.select_files"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(language.text("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(language.text("patch.add_selected")) {
                        let selection = selectedCandidates
                        dismiss()
                        onCreate(selection)
                    }
                    .disabled(selectedIDs.isEmpty)
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button(selectionActionTitle, action: toggleAll)
                }
            }
            .task { loadCandidates() }
        }
    }

    private var fileList: some View {
        List {
            if let validationMessageKey {
                Section {
                    Label(
                        language.text(validationMessageKey),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.red)
                }
            }

            Section {
                ForEach(candidates) { candidate in
                    Button {
                        toggle(candidate)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "doc.fill")
                                .foregroundStyle(AppTheme.accent)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(candidate.url.lastPathComponent)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(candidate.relativePath)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 8)
                            VStack(alignment: .trailing, spacing: 5) {
                                Image(systemName: selectedIDs.contains(candidate.id)
                                      ? "checkmark.circle.fill"
                                      : "circle")
                                    .foregroundStyle(selectedIDs.contains(candidate.id)
                                                     ? AppTheme.accent
                                                     : Color.secondary)
                                Text(ByteCountFormatter.string(
                                    fromByteCount: candidate.byteCount,
                                    countStyle: .file
                                ))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text(language.text("patch.selected_count", Int64(selectedIDs.count)))
                    .textCase(nil)
            } footer: {
                Text(language.text(
                    "patch.folder_selection_footer",
                    Int64(PatchPackageLimits.maximumRuleCount)
                ))
            }
        }
        .listStyle(.plain)
    }

    private var selectionActionTitle: String {
        selectedIDs.count == candidates.count
            ? language.text("patch.deselect_all")
            : language.text("patch.select_all")
    }

    private func loadCandidates() {
        guard isLoading else { return }
        let root = containerRoot
        let selectedFolder = folder
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try PatchDraftService.candidates(
                    in: selectedFolder,
                    containerRoot: root
                )
            }
            DispatchQueue.main.async {
                isLoading = false
                switch result {
                case .success(let loaded):
                    candidates = loaded
                    if loaded.count <= PatchPackageLimits.maximumRuleCount {
                        selectedIDs = Set(loaded.map(\.id))
                    }
                case .failure(let error as PatchPackageError):
                    validationMessageKey = error.localizationKey
                case .failure:
                    validationMessageKey = "patch.error.invalid_project"
                }
            }
        }
    }

    private func toggle(_ candidate: PatchDraftCandidate) {
        validationMessageKey = nil
        if selectedIDs.remove(candidate.id) != nil { return }
        guard selectedIDs.count < PatchPackageLimits.maximumRuleCount else {
            validationMessageKey = "patch.error.size_limit"
            return
        }
        selectedIDs.insert(candidate.id)
    }

    private func toggleAll() {
        validationMessageKey = nil
        if selectedIDs.count == candidates.count {
            selectedIDs.removeAll()
            return
        }
        guard candidates.count <= PatchPackageLimits.maximumRuleCount else {
            validationMessageKey = "patch.error.size_limit"
            return
        }
        selectedIDs = Set(candidates.map(\.id))
    }
}
