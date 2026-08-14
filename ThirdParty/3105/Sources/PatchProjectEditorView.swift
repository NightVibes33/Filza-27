import SwiftUI

struct PatchProjectEditorView: View {
    @Environment(\.appLanguage) private var language
    @Environment(\.dismiss) private var dismiss
    let existingProject: PatchProject?
    let passwordIsProtected: Bool
    let onSave: (PatchProject, String?) -> Void

    @State private var name: String
    @State private var rules: [PatchRule]
    @State private var password = ""
    @State private var ruleEditor: PatchRuleEditorContext?
    @State private var validationMessageKey: String?

    init(
        existingProject: PatchProject?,
        passwordIsProtected: Bool,
        initialDraft: PatchProjectDraft? = nil,
        onSave: @escaping (PatchProject, String?) -> Void
    ) {
        self.existingProject = existingProject
        self.passwordIsProtected = passwordIsProtected
        self.onSave = onSave
        _name = State(initialValue: existingProject?.name ?? initialDraft?.name ?? "")
        _rules = State(initialValue: existingProject?.rules ?? initialDraft?.rules ?? [])
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(language.text("patch.project")) {
                    TextField(language.text("patch.project_name"), text: $name)
                        .textInputAutocapitalization(.words)
                }

                Section {
                    ForEach(rules) { rule in
                        Button {
                            ruleEditor = PatchRuleEditorContext(rule: rule)
                        } label: {
                            HStack(spacing: 10) {
                                ruleRow(rule)
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(language.text("patch.edit_rule_hint"))
                    }
                    .onDelete { rules.remove(atOffsets: $0) }

                    Button {
                        ruleEditor = PatchRuleEditorContext(rule: nil)
                    } label: {
                        Label(language.text("patch.add_rule"), systemImage: "plus.circle.fill")
                    }
                } header: {
                    Text(language.text("patch.rules"))
                } footer: {
                    Text(language.text("patch.bundle_path_footer"))
                }

                Section {
                    if existingProject == nil {
                        SecureField(language.text("patch.password_optional"), text: $password)
                            .textContentType(.newPassword)
                    } else {
                        Label(
                            language.text(passwordIsProtected ? "patch.password_locked" : "patch.no_password"),
                            systemImage: passwordIsProtected ? "lock.fill" : "lock.open"
                        )
                    }
                } header: {
                    Text(language.text("patch.password"))
                } footer: {
                    Text(language.text(existingProject == nil
                        ? "patch.password_immutable_footer"
                        : "patch.password_existing_footer"))
                }

                if let validationMessageKey {
                    Section {
                        Label(language.text(validationMessageKey), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(language.text(existingProject == nil ? "patch.new" : "patch.edit"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(language.text("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(language.text("common.done"), action: save)
                }
            }
            .sheet(item: $ruleEditor) { context in
                PatchRuleEditorView(rule: context.rule) { savedRule in
                    if let index = rules.firstIndex(where: { $0.id == savedRule.id }) {
                        rules[index] = savedRule
                    } else {
                        rules.append(savedRule)
                    }
                }
            }
        }
    }

    private func ruleRow(_ rule: PatchRule) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(rule.bundleID)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Text(rule.relativePath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if rule.hasReplacement {
                Text(rule.replacementFilename)
                    .font(.caption)
                    .foregroundStyle(AppTheme.accent)
            } else {
                Label(language.text("patch.replacement_required"), systemImage: "exclamationmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 3)
    }

    private func save() {
        let projectName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !projectName.isEmpty, projectName.utf8.count <= 120, !rules.isEmpty else {
            validationMessageKey = "patch.error.invalid_project"
            return
        }
        guard let incompleteRule = rules.first(where: { !$0.hasReplacement }) else {
            saveCompleteProject(named: projectName)
            return
        }
        validationMessageKey = "patch.error.replacement_required"
        ruleEditor = PatchRuleEditorContext(rule: incompleteRule)
    }

    private func saveCompleteProject(named projectName: String) {
        let project = PatchProject(
            id: existingProject?.id ?? UUID(),
            name: projectName,
            createdAt: existingProject?.createdAt ?? Date(),
            updatedAt: Date(),
            rules: rules
        )
        do {
            try PatchPackageCodec.validate(project)
            onSave(project, existingProject == nil && !password.isEmpty ? password : nil)
            dismiss()
        } catch let error as PatchPackageError {
            validationMessageKey = error.localizationKey
        } catch {
            validationMessageKey = "patch.error.invalid_project"
        }
    }
}

private struct PatchRuleEditorContext: Identifiable {
    let id = UUID()
    let rule: PatchRule?
}

struct PatchRuleEditorView: View {
    @Environment(\.appLanguage) private var language
    @Environment(\.dismiss) private var dismiss
    let originalRule: PatchRule?
    let onSave: (PatchRule) -> Void

    @State private var bundleID: String
    @State private var relativePath: String
    @State private var replacementFilename: String
    @State private var replacementData: Data
    @State private var showFileImporter = false
    @State private var isImporting = false
    @State private var validationMessageKey: String?

    init(rule: PatchRule?, onSave: @escaping (PatchRule) -> Void) {
        originalRule = rule
        self.onSave = onSave
        _bundleID = State(initialValue: rule?.bundleID ?? "")
        _relativePath = State(initialValue: rule?.relativePath ?? "")
        _replacementFilename = State(initialValue: rule?.replacementFilename ?? "")
        _replacementData = State(initialValue: rule?.replacementData ?? Data())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("com.example.app", text: $bundleID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                    TextField("Library/path/file", text: $relativePath)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                } header: {
                    Text(language.text("patch.destination"))
                } footer: {
                    Text(language.text("patch.bundle_not_uuid_footer"))
                }

                Section(language.text("patch.replacement_file")) {
                    Button {
                        showFileImporter = true
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: replacementFilename.isEmpty ? "doc.badge.plus" : "doc.fill")
                                .foregroundStyle(AppTheme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(replacementFilename.isEmpty
                                     ? language.text("patch.choose_file")
                                     : replacementFilename)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(language.text(replacementFilename.isEmpty
                                     ? "patch.replacement_required"
                                     : "patch.change_replacement"))
                                    .font(.caption)
                                    .foregroundStyle(replacementFilename.isEmpty ? Color.orange : Color.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .disabled(isImporting)
                    if isImporting {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(language.text("patch.importing_replacement"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !replacementFilename.isEmpty {
                        LabeledContent(
                            language.text("patch.file_size"),
                            value: ByteCountFormatter.string(
                                fromByteCount: Int64(replacementData.count),
                                countStyle: .file
                            )
                        )
                    }
                }

                if let validationMessageKey {
                    Section {
                        Label(language.text(validationMessageKey), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(language.text(originalRule == nil ? "patch.add_rule" : "patch.edit_rule"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(language.text("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(language.text("common.done"), action: save)
                        .disabled(isImporting)
                }
            }
            .sheet(isPresented: $showFileImporter) {
                FileDocumentPicker(
                    allowsMultipleSelection: false,
                    onSelection: { result in
                        showFileImporter = false
                        importFile(result)
                    },
                    onCancel: {
                        showFileImporter = false
                    }
                )
                .ignoresSafeArea()
            }
        }
    }

    private func importFile(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        isImporting = true
        validationMessageKey = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                let values = try url.resourceValues(
                    forKeys: [.fileSizeKey, .isDirectoryKey, .isSymbolicLinkKey]
                )
                guard values.isDirectory != true,
                      values.isSymbolicLink != true,
                      let size = values.fileSize,
                      size <= PatchPackageLimits.maximumReplacementBytes else {
                    throw PatchPackageError.sizeLimitExceeded
                }
                let importedData = try Data(contentsOf: url, options: .mappedIfSafe)
                guard importedData.count <= PatchPackageLimits.maximumReplacementBytes else {
                    throw PatchPackageError.sizeLimitExceeded
                }
                DispatchQueue.main.async {
                    replacementData = importedData
                    replacementFilename = url.lastPathComponent
                    isImporting = false
                }
            } catch let error as PatchPackageError {
                DispatchQueue.main.async {
                    validationMessageKey = error.localizationKey
                    isImporting = false
                }
            } catch {
                DispatchQueue.main.async {
                    validationMessageKey = "patch.error.invalid_project"
                    isImporting = false
                }
            }
        }
    }

    private func save() {
        do {
            let canonicalBundle = try PatchPathValidator.canonicalBundleIdentifier(bundleID)
            let canonicalPath = try PatchPathValidator.canonicalRelativePath(relativePath)
            guard !replacementFilename.isEmpty else { throw PatchPackageError.invalidProject }
            onSave(PatchRule(
                id: originalRule?.id ?? UUID(),
                bundleID: canonicalBundle,
                relativePath: canonicalPath,
                replacementFilename: replacementFilename,
                replacementData: replacementData
            ))
            dismiss()
        } catch let error as PatchPackageError {
            validationMessageKey = error.localizationKey
        } catch {
            validationMessageKey = "patch.error.invalid_project"
        }
    }
}
