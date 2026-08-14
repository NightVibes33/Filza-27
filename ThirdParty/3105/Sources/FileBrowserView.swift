import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct FileBrowserView: View {
    @Environment(\.appLanguage) private var language
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var patchDraftCoordinator: PatchDraftCoordinator
    let containerPath: String
    let title: String
    let bundleID: String?
    let isRoot: Bool
    @State private var currentPath: String
    @State private var entries: [FileEntry] = []
    @State private var fileSearchText = ""
    @State private var isLoadingEntries = true
    @State private var hasGranted = false
    @State private var pendingReplacementRequest: FileReplacementRequest?
    @State private var replacementRequest: FileReplacementRequest?
    @State private var activityText: String?
    @State private var replacementNotice: FileReplacementNotice?
    @State private var operationNotice: FileReplacementNotice?
    @State private var namePrompt: FileNamePrompt?
    @State private var nameInput = ""
    @State private var deleteTarget: FileEntry?
    @State private var pendingImportPickerID: UUID?
    @State private var isShowingImportPicker = false
    @State private var importSession: FileImportSession?
    @State private var importConflict: FileImportConflict?
    @State private var folderPatchEntry: FileEntry?

    private var filteredEntries: [FileEntry] {
        let query = fileSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return entries }
        return entries.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var overlayState: FileBrowserOverlayState {
        if isLoadingEntries { return .loading }
        if entries.isEmpty { return .empty }
        if filteredEntries.isEmpty { return .noResults }
        return .none
    }

    private var interfaceAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.20)
    }

    init(containerPath: String, title: String, bundleID: String? = nil) {
        self.containerPath = containerPath
        self.title = title
        self.bundleID = bundleID
        self.isRoot = true
        _currentPath = State(initialValue: containerPath)
    }

    var body: some View {
        List {
            Section {
                ForEach(filteredEntries) { entry in
                    fileRow(entry)
                }
            } header: {
                Text(language.text("browser.items_count", Int64(filteredEntries.count)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(nil)
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 44)
        .scrollDismissesKeyboard(.interactively)
        .overlay {
            Group {
                switch overlayState {
                case .loading:
                    ProgressView(language.text("browser.loading"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .empty:
                    fileEmptyView
                case .noResults:
                    searchEmptyView
                case .none:
                    EmptyView()
                }
            }
            .transition(.opacity)
            .animation(interfaceAnimation, value: overlayState)
        }
        .navigationTitle(currentPath == containerPath ? title : (currentPath as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $fileSearchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: language.text("browser.search_files")
        )
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        requestImportPicker()
                    } label: {
                        Label(
                            language.text("browser.import_files"),
                            systemImage: "square.and.arrow.down"
                        )
                    }
                    Divider()
                    Button {
                        presentNamePrompt(.createFile)
                    } label: {
                        Label(language.text("browser.new_file"), systemImage: "doc.badge.plus")
                    }
                    Button {
                        presentNamePrompt(.createFolder)
                    } label: {
                        Label(language.text("browser.new_folder"), systemImage: "folder.badge.plus")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(activityText != nil || importSession != nil)
                .accessibilityLabel(language.text("browser.add"))
            }
        }
        .onAppear { load() }
        .sheet(item: $replacementRequest) { request in
            FileDocumentPicker(
                allowsMultipleSelection: false,
                onSelection: { result in
                    log("filebrowser: replacement picker returned")
                    handleReplacementImport(result, request: request)
                    replacementRequest = nil
                },
                onCancel: {
                    log("filebrowser: replacement picker cancelled")
                    replacementRequest = nil
                }
            )
            .ignoresSafeArea()
        }
        .sheet(isPresented: $isShowingImportPicker) {
            FileDocumentPicker(
                allowsMultipleSelection: true,
                onSelection: { result in
                    log("filebrowser: import picker returned")
                    isShowingImportPicker = false
                    handleImportPickerResult(result)
                },
                onCancel: {
                    log("filebrowser: import picker cancelled")
                    isShowingImportPicker = false
                }
            )
            .ignoresSafeArea()
        }
        .sheet(item: $folderPatchEntry) { entry in
            FolderPatchSelectionView(
                containerRoot: URL(fileURLWithPath: containerPath, isDirectory: true),
                folder: URL(fileURLWithPath: entry.path, isDirectory: true)
            ) { candidates in
                preparePatchDraft(candidates, suggestedName: entry.name)
            }
        }
        .overlay {
            ZStack {
                if let activityText {
                    ZStack {
                        Color.black.opacity(0.35)
                            .ignoresSafeArea()
                        ProgressView(activityText)
                            .padding()
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .transition(.opacity)
                }
            }
            .animation(interfaceAnimation, value: activityText != nil)
        }
        .alert(item: $replacementNotice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text(language.text("common.done")))
            )
        }
        .alert(
            namePromptTitle,
            isPresented: isNamePromptPresented
        ) {
            TextField(language.text("browser.name_placeholder"), text: $nameInput)
            Button(language.text("common.cancel"), role: .cancel) {
                namePrompt = nil
            }
            Button(language.text("common.done")) {
                commitNamePrompt()
            }
        } message: {
            Text(language.text("browser.name_message"))
        }
        .confirmationDialog(
            language.text("browser.delete_title"),
            isPresented: isDeleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button(language.text("browser.delete"), role: .destructive) {
                confirmDelete()
            }
            Button(language.text("common.cancel"), role: .cancel) {
                deleteTarget = nil
            }
        } message: {
            Text(language.text("browser.delete_message", deleteTarget?.name ?? ""))
        }
        .confirmationDialog(
            language.text("browser.import_conflict_title"),
            isPresented: isImportConflictPresented,
            titleVisibility: .visible
        ) {
            Button(language.text("browser.replace"), role: .destructive) {
                resolveImportConflict(replaceAll: false)
            }
            Button(language.text("browser.replace_all"), role: .destructive) {
                resolveImportConflict(replaceAll: true)
            }
            Button(language.text("common.cancel"), role: .cancel) {
                cancelImportSession()
            }
        } message: {
            Text(
                language.text(
                    "browser.import_conflict_message",
                    importConflict?.destinationURL.lastPathComponent ?? ""
                )
            )
        }
        .alert(item: $operationNotice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text(language.text("common.done")))
            )
        }
    }

    @ViewBuilder
    private func fileRow(_ entry: FileEntry) -> some View {
        if entry.isDirectory {
            NavigationLink {
                FileBrowserView(
                    containerPath: containerPath,
                    startPath: entry.path,
                    title: entry.name,
                    bundleID: bundleID
                )
            } label: {
                FileEntryRow(entry: entry, language: language)
            }
            .contextMenu { fileActions(for: entry) }
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 12))
        } else {
            NavigationLink {
                FileReaderView(file: entry)
            } label: {
                FileEntryRow(entry: entry, language: language)
            }
            .contextMenu { fileActions(for: entry) }
            .accessibilityHint(language.text("browser.file_actions_hint"))
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 12))
        }
    }

    @ViewBuilder
    private func fileActions(for entry: FileEntry) -> some View {
        Button {
            requestPatchCreation(for: entry)
        } label: {
            Label(
                language.text("browser.create_patch"),
                systemImage: entry.isDirectory ? "folder.badge.plus" : "shippingbox"
            )
        }
        Divider()
        if !entry.isDirectory {
            Button {
                requestReplacement(for: entry)
            } label: {
                Label(
                    language.text("browser.replace"),
                    systemImage: "arrow.triangle.2.circlepath"
                )
            }
        }
        Button {
            presentNamePrompt(.rename(entry))
        } label: {
            Label(language.text("browser.rename"), systemImage: "pencil")
        }
        Divider()
        Button(role: .destructive) {
            deleteTarget = entry
        } label: {
            Label(language.text("browser.delete"), systemImage: "trash")
        }
    }

    private var fileEmptyView: some View {
        VStack(spacing: 10) {
            Image(systemName: "folder")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text(language.text("browser.empty_folder"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var searchEmptyView: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.secondary)
            Text(language.text("browser.search_empty"))
                .font(.subheadline.weight(.medium))
            Text(language.text("browser.search_empty_message"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var isNamePromptPresented: Binding<Bool> {
        Binding(
            get: { namePrompt != nil },
            set: { isPresented in
                if !isPresented { namePrompt = nil }
            }
        )
    }

    private var isDeleteConfirmationPresented: Binding<Bool> {
        Binding(
            get: { deleteTarget != nil },
            set: { isPresented in
                if !isPresented { deleteTarget = nil }
            }
        )
    }

    private var isImportConflictPresented: Binding<Bool> {
        Binding(
            get: { importConflict != nil },
            set: { isPresented in
                if !isPresented, importConflict != nil {
                    cancelImportSession()
                }
            }
        )
    }

    private var namePromptTitle: String {
        switch namePrompt?.action {
        case .createFile: return language.text("browser.new_file")
        case .createFolder: return language.text("browser.new_folder")
        case .rename: return language.text("browser.rename")
        case nil: return ""
        }
    }

    private func presentNamePrompt(_ action: FileNamePromptAction) {
        switch action {
        case .createFile, .createFolder:
            nameInput = ""
        case .rename(let entry):
            nameInput = entry.name
        }
        namePrompt = FileNamePrompt(action: action)
    }

    private func commitNamePrompt() {
        guard let prompt = namePrompt else { return }
        let requestedName = nameInput
        namePrompt = nil
        let directoryURL = URL(fileURLWithPath: currentPath, isDirectory: true)

        switch prompt.action {
        case .createFile:
            performFileOperation(
                activity: language.text("browser.creating"),
                operationName: "create file"
            ) {
                try FileManagerService.createFile(
                    named: requestedName,
                    in: directoryURL
                ).path
            }
        case .createFolder:
            performFileOperation(
                activity: language.text("browser.creating"),
                operationName: "create folder"
            ) {
                try FileManagerService.createFolder(
                    named: requestedName,
                    in: directoryURL
                ).path
            }
        case .rename(let entry):
            performFileOperation(
                activity: language.text("browser.renaming"),
                operationName: "rename"
            ) {
                try FileManagerService.renameItem(
                    at: URL(fileURLWithPath: entry.path),
                    to: requestedName
                ).path
            }
        }
    }

    private func confirmDelete() {
        guard let entry = deleteTarget else { return }
        deleteTarget = nil
        performFileOperation(
            activity: language.text("browser.deleting"),
            operationName: "delete"
        ) {
            try FileManagerService.deleteItem(at: URL(fileURLWithPath: entry.path))
            return entry.path
        }
    }

    private func performFileOperation(
        activity: String,
        operationName: String,
        work: @escaping () throws -> String
    ) {
        activityText = activity
        let errorTitle = language.text("browser.operation_error_title")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let resultPath = try work()
                log("filebrowser: \(operationName) succeeded path=\(resultPath)")
                DispatchQueue.main.async {
                    activityText = nil
                    load()
                }
            } catch {
                log(
                    "filebrowser: \(operationName) failed " +
                        "error=\(error.localizedDescription)"
                )
                DispatchQueue.main.async {
                    activityText = nil
                    operationNotice = FileReplacementNotice(
                        title: errorTitle,
                        message: fileOperationErrorMessage(error)
                    )
                }
            }
        }
    }

    private func requestImportPicker() {
        let requestID = UUID()
        pendingImportPickerID = requestID
        log("filebrowser: import requested destination=\(currentPath)")
        DispatchQueue.main.asyncAfter(
            deadline: .now() + ReplacementPickerPolicy.presentationDelay
        ) {
            guard pendingImportPickerID == requestID else { return }
            pendingImportPickerID = nil
            isShowingImportPicker = true
        }
    }

    private func handleImportPickerResult(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            log("filebrowser: import picker failed error=\(error.localizedDescription)")
            operationNotice = FileReplacementNotice(
                title: language.text("browser.import_error_title"),
                message: fileOperationErrorMessage(error)
            )
        case .success(let sourceURLs):
            guard !sourceURLs.isEmpty else {
                operationNotice = FileReplacementNotice(
                    title: language.text("browser.import_error_title"),
                    message: language.text("browser.error_source_missing")
                )
                return
            }
            importSession = FileImportSession(
                destinationDirectory: URL(fileURLWithPath: currentPath, isDirectory: true),
                sourceURLs: sourceURLs
            )
            log("filebrowser: import session started files=\(sourceURLs.count)")
            DispatchQueue.main.async { processNextImport() }
        }
    }

    private func processNextImport() {
        guard activityText == nil,
              importConflict == nil,
              var session = importSession else { return }
        guard let sourceURL = session.takeNext() else {
            importSession = session
            finishImportSession()
            return
        }
        importSession = session

        do {
            let destinationURL = try FileManagerService.destinationURL(
                named: sourceURL.lastPathComponent,
                in: session.destinationDirectory
            )
            var isDirectory: ObjCBool = false
            let destinationExists = FileManager.default.fileExists(
                atPath: destinationURL.path,
                isDirectory: &isDirectory
            )
            if destinationExists, isDirectory.boolValue {
                recordImportFailure(
                    FileManagerOperationError.destinationIsDirectory,
                    sourceURL: sourceURL
                )
                return
            }
            if destinationExists, !session.replaceAll {
                importConflict = FileImportConflict(
                    sourceURL: sourceURL,
                    destinationURL: destinationURL
                )
                log("filebrowser: import conflict name=\(destinationURL.lastPathComponent)")
                return
            }
            performImport(
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                replaceExisting: destinationExists
            )
        } catch {
            recordImportFailure(error, sourceURL: sourceURL)
        }
    }

    private func resolveImportConflict(replaceAll: Bool) {
        guard let conflict = importConflict else { return }
        importConflict = nil
        if replaceAll, var session = importSession {
            session.enableReplaceAll()
            importSession = session
            log("filebrowser: import Replace All enabled")
        }
        performImport(
            sourceURL: conflict.sourceURL,
            destinationURL: conflict.destinationURL,
            replaceExisting: true
        )
    }

    private func performImport(
        sourceURL: URL,
        destinationURL: URL,
        replaceExisting: Bool
    ) {
        guard let destinationDirectory = importSession?.destinationDirectory else { return }
        activityText = language.text("browser.importing", sourceURL.lastPathComponent)
        log(
            "filebrowser: import begin source=\(sourceURL.lastPathComponent) " +
                "replace=\(replaceExisting)"
        )
        DispatchQueue.global(qos: .userInitiated).async {
            let hasSecurityScope = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if hasSecurityScope { sourceURL.stopAccessingSecurityScopedResource() }
            }
            do {
                let result = try FileManagerService.importFile(
                    sourceURL,
                    into: destinationDirectory,
                    replaceExisting: replaceExisting
                )
                log(
                    "filebrowser: import succeeded path=\(result.destinationURL.path) " +
                        "bytes=\(result.byteCount) disposition=\(result.disposition)"
                )
                DispatchQueue.main.async {
                    if var session = importSession {
                        session.record(result.disposition)
                        importSession = session
                    }
                    activityText = nil
                    load()
                    DispatchQueue.main.async { processNextImport() }
                }
            } catch {
                log(
                    "filebrowser: import failed source=\(sourceURL.lastPathComponent) " +
                        "error=\(error.localizedDescription)"
                )
                DispatchQueue.main.async {
                    activityText = nil
                    if error as? FileManagerOperationError == .itemAlreadyExists,
                       importSession?.replaceAll == false {
                        importConflict = FileImportConflict(
                            sourceURL: sourceURL,
                            destinationURL: destinationURL
                        )
                    } else {
                        recordImportFailure(error, sourceURL: sourceURL)
                    }
                }
            }
        }
    }

    private func recordImportFailure(_ error: Error, sourceURL: URL) {
        if var session = importSession {
            session.recordFailure()
            importSession = session
        }
        log(
            "filebrowser: import skipped source=\(sourceURL.lastPathComponent) " +
                "error=\(error.localizedDescription)"
        )
        DispatchQueue.main.async { processNextImport() }
    }

    private func cancelImportSession() {
        guard var session = importSession else {
            importConflict = nil
            return
        }
        session.cancel()
        importSession = session
        importConflict = nil
        log("filebrowser: import session cancelled")
        finishImportSession()
    }

    private func finishImportSession() {
        guard let session = importSession else { return }
        importSession = nil
        importConflict = nil
        activityText = nil
        load()
        let titleKey = session.isCancelled
            ? "browser.import_cancelled_title"
            : "browser.import_done_title"
        let message = language.text(
            "browser.import_summary",
            Int64(session.importedCount),
            Int64(session.replacedCount),
            Int64(session.failedCount)
        )
        operationNotice = FileReplacementNotice(
            title: language.text(titleKey),
            message: message
        )
        log(
            "filebrowser: import session finished imported=\(session.importedCount) " +
                "replaced=\(session.replacedCount) failed=\(session.failedCount) " +
                "cancelled=\(session.isCancelled)"
        )
    }

    private func fileOperationErrorMessage(_ error: Error) -> String {
        guard let operationError = error as? FileManagerOperationError else {
            return error.localizedDescription
        }
        let key: String
        switch operationError {
        case .invalidName: key = "browser.error_invalid_name"
        case .nameTooLong: key = "browser.error_name_too_long"
        case .itemAlreadyExists: key = "browser.error_exists"
        case .sourceMissing: key = "browser.error_source_missing"
        case .destinationMissing: key = "browser.error_destination_missing"
        case .sourceIsDirectory: key = "browser.error_source_directory"
        case .destinationIsDirectory: key = "browser.error_destination_directory"
        case .destinationNotDirectory: key = "browser.error_destination_not_directory"
        case .symbolicLinkUnsupported: key = "browser.error_symlink"
        case .sourceTooLarge: key = "browser.error_too_large"
        case .cannotCreate: key = "browser.error_create"
        case .cannotRename: key = "browser.error_rename"
        case .cannotDelete: key = "browser.error_delete"
        case .cannotImport: key = "browser.error_import"
        }
        return language.text(key)
    }

    private func load() {
        let shouldGrant = !hasGranted && ContainerAccessPolicy.shouldRequestGrant(isRoot: isRoot)
        hasGranted = true
        isLoadingEntries = true
        let path = currentPath
        let targetBundleID = bundleID
        DispatchQueue.global(qos: .userInitiated).async {
            if shouldGrant {
                var handle: Int64 = -1
                if ContainerAccessPolicy.shouldAttemptMCM(bundleID: targetBundleID),
                   let targetBundleID {
                    var activationError: NSString?
                    handle = MCMActivateContainer(2, targetBundleID, false, &activationError)
                    let detail = activationError.map { String($0) } ?? "none"
                    log("filebrowser: MCM activate \(targetBundleID) -> \(handle), detail=\(detail)")
                }
                if handle < 0 {
                    handle = ContainerStore.grantContainerAccess(path)
                    log("filebrowser: traversal grant \(path) -> \(handle)")
                }
            }
            let loadedEntries = ContainerStore.listFiles(at: path)
            DispatchQueue.main.async {
                guard currentPath == path else { return }
                entries = loadedEntries
                isLoadingEntries = false
            }
        }
    }

    private func requestPatchCreation(for entry: FileEntry) {
        guard bundleID != nil else {
            operationNotice = FileReplacementNotice(
                title: language.text("patch.create_from_browser_failed"),
                message: language.text("patch.error.invalid_bundle")
            )
            return
        }
        if entry.isDirectory {
            folderPatchEntry = entry
            return
        }
        let fileURL = URL(fileURLWithPath: entry.path, isDirectory: false)
        let containerURL = URL(fileURLWithPath: containerPath, isDirectory: true)
        do {
            let candidate = try PatchDraftService.candidate(
                for: fileURL,
                containerRoot: containerURL
            )
            let suggestedName = fileURL.deletingPathExtension().lastPathComponent
            preparePatchDraft([candidate], suggestedName: suggestedName)
        } catch let error as PatchPackageError {
            presentPatchDraftError(error)
        } catch {
            presentPatchDraftError(.invalidProject)
        }
    }

    private func preparePatchDraft(
        _ candidates: [PatchDraftCandidate],
        suggestedName: String
    ) {
        guard let bundleID else {
            presentPatchDraftError(.invalidBundleIdentifier)
            return
        }
        activityText = language.text("patch.preparing_from_browser")
        let containerURL = URL(fileURLWithPath: containerPath, isDirectory: true)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let draft = try PatchDraftService.makeDraft(
                    bundleID: bundleID,
                    containerRoot: containerURL,
                    candidates: candidates,
                    suggestedName: suggestedName
                )
                DispatchQueue.main.async {
                    activityText = nil
                    patchDraftCoordinator.present(draft)
                }
            } catch let error as PatchPackageError {
                DispatchQueue.main.async {
                    activityText = nil
                    presentPatchDraftError(error)
                }
            } catch {
                DispatchQueue.main.async {
                    activityText = nil
                    presentPatchDraftError(.invalidProject)
                }
            }
        }
    }

    private func presentPatchDraftError(_ error: PatchPackageError) {
        operationNotice = FileReplacementNotice(
            title: language.text("patch.create_from_browser_failed"),
            message: language.text(error.localizationKey)
        )
    }

    private func requestReplacement(for entry: FileEntry) {
        let request = FileReplacementRequest(
            targetURL: URL(fileURLWithPath: entry.path),
            targetName: entry.name
        )
        pendingReplacementRequest = request
        log("filebrowser: replacement requested target=\(entry.name)")
        DispatchQueue.main.asyncAfter(
            deadline: .now() + ReplacementPickerPolicy.presentationDelay
        ) {
            guard pendingReplacementRequest?.id == request.id else {
                log("filebrowser: replacement request superseded target=\(entry.name)")
                return
            }
            pendingReplacementRequest = nil
            replacementRequest = request
        }
    }

    private func handleReplacementImport(
        _ result: Result<[URL], Error>,
        request: FileReplacementRequest
    ) {
        switch result {
        case .failure(let error):
            log("filebrowser: replacement picker failed error=\(error.localizedDescription)")
            replacementNotice = FileReplacementNotice(
                title: language.text("browser.replace_error_title"),
                message: replacementErrorMessage(error)
            )
        case .success(let urls):
            let selection: FileReplacementSelection
            do {
                selection = try request.selection(from: urls)
            } catch {
                log("filebrowser: replacement picker returned no file")
                replacementNotice = FileReplacementNotice(
                    title: language.text("browser.replace_error_title"),
                    message: replacementErrorMessage(error)
                )
                return
            }
            activityText = language.text("browser.replacing")
            log(
                "filebrowser: replacement started target=\(selection.targetName) " +
                    "source=\(selection.sourceURL.lastPathComponent)"
            )
            DispatchQueue.global(qos: .userInitiated).async {
                let hasSecurityScope = selection.sourceURL.startAccessingSecurityScopedResource()
                log("filebrowser: replacement source access securityScope=\(hasSecurityScope)")
                defer {
                    if hasSecurityScope {
                        selection.sourceURL.stopAccessingSecurityScopedResource()
                    }
                }
                do {
                    log("filebrowser: replacement copy begin target=\(selection.targetName)")
                    let replacement = try FileReplacementService.replace(
                        target: selection.targetURL,
                        with: selection.sourceURL
                    )
                    let size = ByteCountFormatter.string(
                        fromByteCount: replacement.byteCount,
                        countStyle: .file
                    )
                    log(
                        "filebrowser: replaced \(selection.targetURL.path) " +
                            "bytes=\(replacement.byteCount)"
                    )
                    DispatchQueue.main.async {
                        activityText = nil
                        load()
                        replacementNotice = FileReplacementNotice(
                            title: language.text("browser.replace_done_title"),
                            message: language.text(
                                "browser.replace_done_message",
                                selection.targetName,
                                size
                            )
                        )
                    }
                } catch {
                    log(
                        "filebrowser: replace failed target=\(selection.targetURL.path) " +
                            "error=\(error.localizedDescription)"
                    )
                    DispatchQueue.main.async {
                        activityText = nil
                        replacementNotice = FileReplacementNotice(
                            title: language.text("browser.replace_error_title"),
                            message: replacementErrorMessage(error)
                        )
                    }
                }
            }
        }
    }

    private func replacementErrorMessage(_ error: Error) -> String {
        guard let replacementError = error as? FileReplacementError else {
            return error.localizedDescription
        }
        let key: String
        switch replacementError {
        case .targetMissing: key = "browser.replace_error_target_missing"
        case .sourceMissing: key = "browser.replace_error_source_missing"
        case .targetIsDirectory: key = "browser.replace_error_target_directory"
        case .sourceIsDirectory: key = "browser.replace_error_source_directory"
        case .sameFile: key = "browser.replace_error_same_file"
        case .symbolicLinkUnsupported: key = "browser.replace_error_symlink"
        case .sourceTooLarge: key = "browser.replace_error_too_large"
        case .replacementFailed: key = "browser.replace_error_failed"
        }
        return language.text(key)
    }
}

private enum FileBrowserOverlayState: Equatable {
    case loading
    case empty
    case noResults
    case none
}

struct FileDocumentPicker: UIViewControllerRepresentable {
    let allowedContentTypes: [UTType]
    let copiesSelectedDocument: Bool
    let allowsMultipleSelection: Bool
    let onSelection: (Result<[URL], Error>) -> Void
    let onCancel: () -> Void

    init(
        allowedContentTypes: [UTType] = ReplacementPickerPolicy.allowedContentTypes,
        copiesSelectedDocument: Bool = ReplacementPickerPolicy.copiesSelectedDocument,
        allowsMultipleSelection: Bool,
        onSelection: @escaping (Result<[URL], Error>) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.allowedContentTypes = allowedContentTypes
        self.copiesSelectedDocument = copiesSelectedDocument
        self.allowsMultipleSelection = allowsMultipleSelection
        self.onSelection = onSelection
        self.onCancel = onCancel
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelection: onSelection, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: allowedContentTypes,
            asCopy: copiesSelectedDocument
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = allowsMultipleSelection
        picker.shouldShowFileExtensions = true
        return picker
    }

    func updateUIViewController(
        _ uiViewController: UIDocumentPickerViewController,
        context: Context
    ) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onSelection: (Result<[URL], Error>) -> Void
        private let onCancel: () -> Void

        init(
            onSelection: @escaping (Result<[URL], Error>) -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.onSelection = onSelection
            self.onCancel = onCancel
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            onSelection(.success(urls))
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}

private struct FileEntryRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let entry: FileEntry
    let language: AppLanguage

    private var fileExtension: String {
        (entry.name as NSString).pathExtension.lowercased()
    }

    private var symbol: String {
        if entry.isDirectory { return "folder.fill" }
        if ["jpg", "jpeg", "png", "gif", "heic", "webp"].contains(fileExtension) {
            return "photo"
        }
        if ["zip", "rar", "7z", "tar", "gz"].contains(fileExtension) {
            return "archivebox.fill"
        }
        if ["plist", "json", "txt", "log", "xml", "strings"].contains(fileExtension) {
            return "doc.text.fill"
        }
        return "doc.fill"
    }

    private var tint: Color {
        if entry.isDirectory { return .blue }
        if ["jpg", "jpeg", "png", "gif", "heic", "webp"].contains(fileExtension) {
            return .purple
        }
        return AppTheme.accent
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(tint.opacity(0.12))
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 30, height: 30)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .truncationMode(.middle)
                Text(entry.isDirectory ? language.text("browser.folder") : entry.sizeText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct FileReplacementNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private enum FileNamePromptAction {
    case createFile
    case createFolder
    case rename(FileEntry)
}

private struct FileNamePrompt: Identifiable {
    let id = UUID()
    let action: FileNamePromptAction
}

private struct FileImportConflict: Identifiable {
    let id = UUID()
    let sourceURL: URL
    let destinationURL: URL
}

extension FileBrowserView {
    init(containerPath: String, startPath: String, title: String, bundleID: String?) {
        self.containerPath = containerPath
        self.title = title
        self.bundleID = bundleID
        self.isRoot = false
        _currentPath = State(initialValue: startPath)
    }
}

struct FileReaderView: View {
    let file: FileEntry
    @State private var content = ""
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else {
                ScrollView {
                    Text(content)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .navigationTitle(file.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            DispatchQueue.global(qos: .userInitiated).async {
                let c = ContainerStore.readTextFile(at: file.path)
                DispatchQueue.main.async {
                    content = c
                    isLoading = false
                }
            }
        }
    }
}
