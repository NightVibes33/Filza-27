import SwiftUI
import UIKit
import UniformTypeIdentifiers
import QuickLook

struct FileBrowserView: View {
    @Environment(\.appLanguage) private var language
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var patchDraftCoordinator: PatchDraftCoordinator
    @EnvironmentObject private var fileOperationCoordinator: FileOperationCoordinator
    let containerPath: String
    let title: String
    let bundleID: String?
    let isRoot: Bool
    private let filesTabSession: Binding<FilesTabSession>?
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
    @State private var pendingImportPickerID: UUID?
    @State private var isShowingImportPicker = false
    @State private var importSession: FileImportSession?
    @State private var importConflict: FileImportConflict?
    @State private var isSelecting = false
    @State private var selectedEntryIDs = Set<String>()
    @State private var transferSession: FileTransferSession?
    @State private var transferConflict: FileTransferConflict?
    @State private var deleteTargets: [FileEntry] = []
    @AppStorage(FileBrowserSortOrder.storageKey)
    private var sortOrderRaw = FileBrowserSortOrder.nameAscending.rawValue

    private var filteredEntries: [FileEntry] {
        let query = fileSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = query.isEmpty
            ? entries
            : entries.filter { $0.name.localizedCaseInsensitiveContains(query) }
        return FileBrowserSortPolicy.sorted(
            filtered,
            order: sortOrder,
            name: \.name,
            isDirectory: \.isDirectory,
            size: \.size,
            modifiedAt: \.modifiedAt
        )
    }

    private var selectedEntries: [FileEntry] {
        entries.filter { selectedEntryIDs.contains($0.id) }
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

    init(
        containerPath: String,
        title: String,
        bundleID: String? = nil,
        filesTabSession: Binding<FilesTabSession>? = nil
    ) {
        self.containerPath = containerPath
        self.title = title
        self.bundleID = bundleID
        self.isRoot = true
        self.filesTabSession = filesTabSession
        _currentPath = State(initialValue: containerPath)
    }

    var body: some View {
        VStack(spacing: 0) {
            AppSearchField(
                text: $fileSearchText,
                prompt: language.text("browser.search_files"),
                clearLabel: language.text("common.clear")
            )
            Divider()
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
            .listStyle(.insetGrouped)
            .environment(\.defaultMinListRowHeight, AppTheme.fileRowHeight)
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
        }
        .navigationTitle(currentPath == containerPath ? title : (currentPath as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: FileBrowserDestination.self) { destination in
            FileBrowserView(
                containerPath: destination.containerPath,
                startPath: destination.startPath,
                title: destination.title,
                bundleID: destination.bundleID,
                filesTabSession: filesTabSession
            )
        }
        .toolbar {
            if let filesTabSession {
                ToolbarItem(placement: .navigationBarTrailing) {
                    FilesTabToolbarButton(session: filesTabSession)
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                sortMenu
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(isSelecting
                       ? language.text("common.cancel")
                       : language.text("browser.select")) {
                    toggleSelectionMode()
                }
                .disabled(activityText != nil || importSession != nil)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if isSelecting {
                    Button(selectionActionTitle, action: toggleAllSelection)
                        .disabled(entries.isEmpty)
                } else {
                    Menu {
                        if let payload = fileOperationCoordinator.payload {
                            Button {
                                beginPaste(payload)
                            } label: {
                                Label(
                                    language.text("browser.paste_count", Int64(payload.itemCount)),
                                    systemImage: "doc.on.clipboard"
                                )
                            }
                            Button(role: .destructive) {
                                fileOperationCoordinator.clear()
                            } label: {
                                Label(language.text("browser.clear_clipboard"), systemImage: "xmark")
                            }
                            Divider()
                        }
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
                    .disabled(activityText != nil || importSession != nil || transferSession != nil)
                    .accessibilityLabel(language.text("browser.add"))
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isSelecting {
                FileSelectionActionBar(
                    selectedCount: selectedEntryIDs.count,
                    language: language,
                    onCopy: { prepareTransfer(.copy) },
                    onMove: { prepareTransfer(.move) },
                    onArchive: prepareArchive,
                    onDelete: prepareBulkDelete
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let payload = fileOperationCoordinator.payload {
                FilePasteBar(
                    itemCount: payload.itemCount,
                    mode: payload.mode,
                    language: language,
                    onPaste: { beginPaste(payload) },
                    onCancel: fileOperationCoordinator.clear
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if horizontalSizeClass == .regular, let filesTabSession {
                FilesTabStrip(session: filesTabSession)
            }
        }
        .animation(interfaceAnimation, value: isSelecting)
        .animation(interfaceAnimation, value: fileOperationCoordinator.payload)
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
                deleteTargets = []
            }
        } message: {
            Text(deleteConfirmationMessage)
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
        .confirmationDialog(
            language.text("browser.transfer_conflict_title"),
            isPresented: isTransferConflictPresented,
            titleVisibility: .visible
        ) {
            Button(language.text("browser.replace"), role: .destructive) {
                resolveTransferConflict(policy: .replace, applyToAll: false)
            }
            Button(language.text("browser.keep_both")) {
                resolveTransferConflict(policy: .keepBoth, applyToAll: false)
            }
            Button(language.text("browser.replace_all"), role: .destructive) {
                resolveTransferConflict(policy: .replace, applyToAll: true)
            }
            Button(language.text("browser.keep_both_all")) {
                resolveTransferConflict(policy: .keepBoth, applyToAll: true)
            }
            Button(language.text("common.cancel"), role: .cancel) {
                cancelTransferSession()
            }
        } message: {
            Text(language.text(
                "browser.transfer_conflict_message",
                transferConflict?.destinationURL.lastPathComponent ?? ""
            ))
        }
        .alert(item: $operationNotice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text(language.text("common.done")))
            )
        }
    }

    private var sortOrder: FileBrowserSortOrder {
        FileBrowserSortOrder(rawValue: sortOrderRaw) ?? .nameAscending
    }

    private var sortMenu: some View {
        Menu {
            Picker(language.text("browser.sort"), selection: $sortOrderRaw) {
                ForEach(FileBrowserSortOrder.allCases) { order in
                    Label(
                        language.text(order.localizationKey),
                        systemImage: order.systemImage
                    )
                    .tag(order.rawValue)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .accessibilityLabel(language.text("browser.sort"))
    }

    @ViewBuilder
    private func fileRow(_ entry: FileEntry) -> some View {
        if isSelecting {
            Button {
                toggleSelection(entry)
            } label: {
                FileEntryRow(
                    entry: entry,
                    language: language,
                    selectionState: selectedEntryIDs.contains(entry.id)
                )
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 12))
        } else if entry.isDirectory {
            NavigationLink(
                value: FileBrowserDestination(
                    containerPath: containerPath,
                    startPath: entry.path,
                    title: entry.name,
                    bundleID: bundleID
                )
            ) {
                FileEntryRow(entry: entry, language: language, selectionState: nil)
            }
            .contextMenu { fileActions(for: entry) }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 12))
        } else {
            NavigationLink {
                FileQuickLookView(file: entry)
            } label: {
                FileEntryRow(entry: entry, language: language, selectionState: nil)
            }
            .contextMenu { fileActions(for: entry) }
            .accessibilityHint(language.text("browser.file_actions_hint"))
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 12))
        }
    }

    @ViewBuilder
    private func fileActions(for entry: FileEntry) -> some View {
        if entry.isDirectory, filesTabSession != nil {
            Button {
                openDirectoryInNewTab(entry)
            } label: {
                Label(language.text("browser.open_new_tab"), systemImage: "square.on.square")
            }
            Divider()
        }
        Button {
            selectedEntryIDs = [entry.id]
            isSelecting = true
        } label: {
            Label(language.text("browser.select"), systemImage: "checkmark.circle")
        }
        Button {
            prepareTransfer([entry], mode: .copy)
        } label: {
            Label(language.text("browser.copy"), systemImage: "doc.on.doc")
        }
        Button {
            prepareTransfer([entry], mode: .move)
        } label: {
            Label(language.text("browser.move"), systemImage: "folder")
        }
        ShareLink(item: URL(fileURLWithPath: entry.path)) {
            Label(language.text("browser.share"), systemImage: "square.and.arrow.up")
        }
        Divider()
        if bundleID != nil {
            Button {
                requestPatchCreation(for: entry)
            } label: {
                Label(
                    language.text("browser.create_patch"),
                    systemImage: entry.isDirectory ? "folder.badge.plus" : "shippingbox"
                )
            }
        }
        if !entry.isDirectory, entry.name.lowercased().hasSuffix(".zip") {
            Button {
                extractArchive(entry)
            } label: {
                Label(language.text("browser.extract_zip"), systemImage: "archivebox")
            }
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
            deleteTargets = [entry]
        } label: {
            Label(language.text("browser.delete"), systemImage: "trash")
        }
    }

    private func openDirectoryInNewTab(_ entry: FileEntry) {
        guard let filesTabSession else { return }
        var updatedSession = filesTabSession.wrappedValue
        updatedSession.openTab(
            navigationPath: [
                FileBrowserDestination(
                    containerPath: containerPath,
                    startPath: entry.path,
                    title: entry.name,
                    bundleID: bundleID
                )
            ]
        )
        filesTabSession.wrappedValue = updatedSession
    }

    private var fileEmptyView: some View {
        VStack(spacing: 10) {
            Image(systemName: "folder")
                .font(.system(size: AppTheme.emptyIconSize, weight: .light))
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
                .font(.system(size: AppTheme.emptyIconSize, weight: .light))
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
            get: { !deleteTargets.isEmpty },
            set: { isPresented in
                if !isPresented { deleteTargets = [] }
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

    private var isTransferConflictPresented: Binding<Bool> {
        Binding(
            get: { transferConflict != nil },
            set: { isPresented in
                if !isPresented, transferConflict != nil {
                    cancelTransferSession()
                }
            }
        )
    }

    private var deleteConfirmationMessage: String {
        if deleteTargets.count == 1 {
            return language.text("browser.delete_message", deleteTargets[0].name)
        }
        return language.text("browser.delete_multiple_message", Int64(deleteTargets.count))
    }

    private var selectionActionTitle: String {
        let visibleIDs = Set(filteredEntries.map(\.id))
        return !visibleIDs.isEmpty && visibleIDs.isSubset(of: selectedEntryIDs)
            ? language.text("patch.deselect_all")
            : language.text("patch.select_all")
    }

    private var namePromptTitle: String {
        switch namePrompt?.action {
        case .createFile: return language.text("browser.new_file")
        case .createFolder: return language.text("browser.new_folder")
        case .rename: return language.text("browser.rename")
        case .archive: return language.text("browser.create_zip")
        case nil: return ""
        }
    }

    private func presentNamePrompt(_ action: FileNamePromptAction) {
        switch action {
        case .createFile, .createFolder:
            nameInput = ""
        case .rename(let entry):
            nameInput = entry.name
        case .archive:
            nameInput = language.text("browser.default_archive_name")
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
        case .archive(let selectedEntries):
            performFileOperation(
                activity: language.text("browser.archiving"),
                operationName: "create ZIP",
                successNotice: { path in
                    FileReplacementNotice(
                        title: language.text("browser.archive_done_title"),
                        message: language.text(
                            "browser.archive_done_message",
                            (path as NSString).lastPathComponent
                        )
                    )
                }
            ) {
                try FileManagerService.createZIPArchive(
                    containing: selectedEntries.map { URL(fileURLWithPath: $0.path) },
                    named: requestedName,
                    in: directoryURL
                ).archiveURL.path
            }
        }
    }

    private func confirmDelete() {
        let targets = deleteTargets
        guard !targets.isEmpty else { return }
        deleteTargets = []
        performFileOperation(
            activity: language.text("browser.deleting"),
            operationName: "delete"
        ) {
            for entry in targets {
                try FileManagerService.deleteItem(at: URL(fileURLWithPath: entry.path))
            }
            return targets.map(\.path).joined(separator: ",")
        }
    }

    private func toggleSelectionMode() {
        isSelecting.toggle()
        if !isSelecting { selectedEntryIDs.removeAll() }
    }

    private func toggleSelection(_ entry: FileEntry) {
        if selectedEntryIDs.remove(entry.id) == nil {
            selectedEntryIDs.insert(entry.id)
        }
    }

    private func toggleAllSelection() {
        let visibleIDs = Set(filteredEntries.map(\.id))
        if !visibleIDs.isEmpty, visibleIDs.isSubset(of: selectedEntryIDs) {
            selectedEntryIDs.subtract(visibleIDs)
        } else {
            selectedEntryIDs.formUnion(visibleIDs)
        }
    }

    private func prepareTransfer(_ mode: FileTransferMode) {
        prepareTransfer(selectedEntries, mode: mode)
    }

    private func prepareTransfer(_ entries: [FileEntry], mode: FileTransferMode) {
        guard !entries.isEmpty else { return }
        fileOperationCoordinator.prepare(
            entries.map { URL(fileURLWithPath: $0.path, isDirectory: $0.isDirectory) },
            mode: mode
        )
        isSelecting = false
        selectedEntryIDs.removeAll()
    }

    private func prepareArchive() {
        let items = selectedEntries
        guard !items.isEmpty else { return }
        isSelecting = false
        selectedEntryIDs.removeAll()
        presentNamePrompt(.archive(items))
    }

    private func prepareBulkDelete() {
        let items = selectedEntries
        guard !items.isEmpty else { return }
        isSelecting = false
        selectedEntryIDs.removeAll()
        deleteTargets = items
    }

    private func beginPaste(_ payload: FileOperationPayload) {
        guard transferSession == nil, activityText == nil else { return }
        transferSession = FileTransferSession(
            payload: payload,
            destinationDirectory: URL(fileURLWithPath: currentPath, isDirectory: true)
        )
        fileOperationCoordinator.clear()
        log(
            "filebrowser: transfer started mode=\(payload.mode) " +
                "items=\(payload.itemCount) destination=\(currentPath)"
        )
        DispatchQueue.main.async { processNextTransfer() }
    }

    private func processNextTransfer() {
        guard activityText == nil,
              transferConflict == nil,
              var session = transferSession else { return }
        guard let sourceURL = session.takeNext() else {
            transferSession = session
            finishTransferSession()
            return
        }
        transferSession = session

        if session.mode == .move,
           sourceURL.deletingLastPathComponent().standardizedFileURL
            == session.destinationDirectory.standardizedFileURL {
            session.record(.moved)
            transferSession = session
            DispatchQueue.main.async { processNextTransfer() }
            return
        }

        let destinationURL = session.destinationDirectory.appendingPathComponent(
            sourceURL.lastPathComponent
        )
        let destinationExists = FileManager.default.fileExists(atPath: destinationURL.path)
        if destinationExists, !session.replaceAll, !session.keepBothAll {
            transferConflict = FileTransferConflict(
                sourceURL: sourceURL,
                destinationURL: destinationURL
            )
            return
        }
        let policy: FileConflictPolicy = destinationExists
            ? (session.keepBothAll ? .keepBoth : .replace)
            : .fail
        performTransfer(sourceURL: sourceURL, policy: policy)
    }

    private func resolveTransferConflict(
        policy: FileConflictPolicy,
        applyToAll: Bool
    ) {
        guard let conflict = transferConflict else { return }
        transferConflict = nil
        if applyToAll, var session = transferSession {
            if policy == .replace { session.useReplaceAll() }
            if policy == .keepBoth { session.useKeepBothAll() }
            transferSession = session
        }
        performTransfer(sourceURL: conflict.sourceURL, policy: policy)
    }

    private func performTransfer(
        sourceURL: URL,
        policy: FileConflictPolicy
    ) {
        guard let session = transferSession else { return }
        let mode = session.mode
        let destinationDirectory = session.destinationDirectory
        activityText = language.text(mode == .copy ? "browser.copying" : "browser.moving")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try FileManagerService.transferItem(
                    at: sourceURL,
                    into: destinationDirectory,
                    mode: mode,
                    conflictPolicy: policy
                )
                log(
                    "filebrowser: transfer succeeded mode=\(mode) " +
                        "source=\(sourceURL.path) destination=\(result.destinationURL.path)"
                )
                DispatchQueue.main.async {
                    if var session = transferSession {
                        session.record(result.disposition)
                        transferSession = session
                    }
                    activityText = nil
                    load()
                    DispatchQueue.main.async { processNextTransfer() }
                }
            } catch {
                log(
                    "filebrowser: transfer failed mode=\(mode) source=\(sourceURL.path) " +
                        "error=\(error.localizedDescription)"
                )
                DispatchQueue.main.async {
                    activityText = nil
                    if error as? FileManagerOperationError == .itemAlreadyExists {
                        transferConflict = FileTransferConflict(
                            sourceURL: sourceURL,
                            destinationURL: destinationDirectory.appendingPathComponent(
                                sourceURL.lastPathComponent
                            )
                        )
                    } else {
                        recordTransferFailure()
                    }
                }
            }
        }
    }

    private func recordTransferFailure() {
        if var session = transferSession {
            session.recordFailure()
            transferSession = session
        }
        DispatchQueue.main.async { processNextTransfer() }
    }

    private func cancelTransferSession() {
        guard var session = transferSession else {
            transferConflict = nil
            return
        }
        session.cancel()
        transferSession = session
        transferConflict = nil
        finishTransferSession()
    }

    private func finishTransferSession() {
        guard let session = transferSession else { return }
        transferSession = nil
        transferConflict = nil
        activityText = nil
        load()
        operationNotice = FileReplacementNotice(
            title: language.text(session.isCancelled
                ? "browser.transfer_cancelled_title"
                : "browser.transfer_done_title"),
            message: language.text(
                "browser.transfer_summary",
                Int64(session.copiedCount),
                Int64(session.movedCount),
                Int64(session.replacedCount),
                Int64(session.renamedCount),
                Int64(session.failedCount)
            )
        )
    }

    private func performFileOperation(
        activity: String,
        operationName: String,
        successNotice: ((String) -> FileReplacementNotice)? = nil,
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
                    operationNotice = successNotice?(resultPath)
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
        case .recursiveDestination: key = "browser.error_recursive_destination"
        case .sourceTooLarge: key = "browser.error_too_large"
        case .cannotCreate: key = "browser.error_create"
        case .cannotRename: key = "browser.error_rename"
        case .cannotDelete: key = "browser.error_delete"
        case .cannotImport: key = "browser.error_import"
        case .cannotCopy: key = "browser.error_copy"
        case .cannotMove: key = "browser.error_move"
        case .cannotArchive: key = "browser.error_archive"
        case .cannotExtract: key = "browser.error_extract"
        case .unsafeArchive: key = "browser.error_unsafe_archive"
        case .insufficientSpace: key = "browser.error_insufficient_space"
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
                selectedEntryIDs.formIntersection(Set(loadedEntries.map(\.id)))
                isLoadingEntries = false
            }
            for directory in loadedEntries where directory.isDirectory {
                let summary = try? FileBrowserMetadataScanner.directorySummary(
                    at: URL(fileURLWithPath: directory.path, isDirectory: true)
                )
                DispatchQueue.main.async {
                    guard currentPath == path,
                          let index = entries.firstIndex(where: { $0.id == directory.id })
                    else { return }
                    entries[index] = directory.withDirectorySummary(summary)
                }
            }
        }
    }

    private func requestPatchCreation(for entry: FileEntry) {
        guard let bundleID else {
            operationNotice = FileReplacementNotice(
                title: language.text("patch.create_from_browser_failed"),
                message: language.text("patch.error.invalid_bundle")
            )
            return
        }
        let itemURL = URL(fileURLWithPath: entry.path, isDirectory: entry.isDirectory)
        let containerURL = URL(fileURLWithPath: containerPath, isDirectory: true)
        activityText = language.text("patch.preparing_from_browser")
        let suggestedName = entry.isDirectory
            ? entry.name
            : itemURL.deletingPathExtension().lastPathComponent
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let draft = try PatchDraftService.makeDraft(
                    bundleID: bundleID,
                    containerRoot: containerURL,
                    itemURL: itemURL,
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

    private func extractArchive(_ entry: FileEntry) {
        let archiveURL = URL(fileURLWithPath: entry.path, isDirectory: false)
        let directoryURL = URL(fileURLWithPath: currentPath, isDirectory: true)
        performFileOperation(
            activity: language.text("browser.extracting"),
            operationName: "extract ZIP",
            successNotice: { path in
                FileReplacementNotice(
                    title: language.text("browser.extract_done_title"),
                    message: language.text(
                        "browser.extract_done_message",
                        (path as NSString).lastPathComponent
                    )
                )
            }
        ) {
            try FileManagerService.extractZIPArchive(
                archiveURL,
                into: directoryURL
            ).destinationURL.path
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
    let selectionState: Bool?

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

    private var detailText: String {
        var components: [String] = []
        if entry.isDirectory {
            switch entry.size {
            case -1:
                components.append(language.text("browser.calculating_size"))
            case -2:
                components.append(language.text("browser.size_unavailable"))
            default:
                components.append(entry.sizeText)
            }
            if let childCount = entry.childCount {
                components.append(language.text("browser.children_count", Int64(childCount)))
            }
        } else {
            components.append(entry.sizeText)
        }
        if let modifiedAt = entry.modifiedAt {
            components.append(
                DateFormatter.localizedString(
                    from: modifiedAt,
                    dateStyle: .short,
                    timeStyle: .short
                )
            )
        }
        return components.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 11) {
            AppRowIcon(
                systemName: symbol,
                tint: tint,
                symbolSize: AppTheme.fileRowIconSize,
                frameSize: AppTheme.fileRowIconFrame
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .truncationMode(.middle)
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            if let selectionState {
                Image(systemName: selectionState ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: AppTheme.selectionIconSize, weight: .medium))
                    .foregroundStyle(selectionState ? AppTheme.accent : Color.secondary)
                    .accessibilityHidden(true)
            }
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
    case archive([FileEntry])
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

private struct FileTransferConflict: Identifiable {
    let id = UUID()
    let sourceURL: URL
    let destinationURL: URL
}

private struct FileSelectionActionBar: View {
    let selectedCount: Int
    let language: AppLanguage
    let onCopy: () -> Void
    let onMove: () -> Void
    let onArchive: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            action("browser.copy", systemImage: "doc.on.doc", action: onCopy)
            action("browser.move", systemImage: "folder", action: onMove)
            action("browser.create_zip", systemImage: "archivebox", action: onArchive)
            action("browser.delete", systemImage: "trash", role: .destructive, action: onDelete)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .disabled(selectedCount == 0)
    }

    private func action(
        _ key: String,
        systemImage: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                Text(language.text(key))
                    .font(.caption2)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 34)
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive ? Color.red : AppTheme.accent)
        .accessibilityLabel(language.text(key))
        .accessibilityValue(language.text("browser.selected_count", Int64(selectedCount)))
    }
}

private struct FilePasteBar: View {
    let itemCount: Int
    let mode: FileTransferMode
    let language: AppLanguage
    let onPaste: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: mode == .copy ? "doc.on.doc" : "folder")
                .foregroundStyle(AppTheme.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(language.text(mode == .copy
                    ? "browser.copy_ready"
                    : "browser.move_ready"))
                    .font(.subheadline.weight(.semibold))
                Text(language.text("browser.selected_count", Int64(itemCount)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(language.text("common.cancel"), action: onCancel)
                .buttonStyle(.borderless)
            Button(language.text("browser.paste"), action: onPaste)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

extension FileBrowserView {
    init(
        containerPath: String,
        startPath: String,
        title: String,
        bundleID: String?,
        filesTabSession: Binding<FilesTabSession>? = nil
    ) {
        self.containerPath = containerPath
        self.title = title
        self.bundleID = bundleID
        self.isRoot = false
        self.filesTabSession = filesTabSession
        _currentPath = State(initialValue: startPath)
    }
}

struct FileQuickLookView: View {
    @Environment(\.appLanguage) private var language
    let file: FileEntry
    @State private var previewURL: URL?
    @State private var previewDirectory: URL?
    @State private var previewFailed = false

    var body: some View {
        Group {
            if let previewURL {
                FileQuickLookController(url: previewURL)
                    .ignoresSafeArea(edges: .bottom)
            } else if previewFailed {
                VStack(spacing: 12) {
                    Image(systemName: "doc.questionmark")
                        .font(.system(size: AppTheme.emptyIconSize, weight: .light))
                        .foregroundStyle(.secondary)
                    Text(language.text("browser.preview_error"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                ProgressView(language.text("browser.loading"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(file.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if let previewURL {
                    ShareLink(item: previewURL) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
        .task(id: file.id) {
            let sourceURL = URL(fileURLWithPath: file.path)
            let result = await Task.detached(priority: .userInitiated) {
                Result { try FilePreviewService.makePreviewCopy(of: sourceURL) }
            }.value
            guard !Task.isCancelled else {
                if case .success(let prepared) = result {
                    try? FileManager.default.removeItem(at: prepared.directoryURL)
                }
                return
            }
            switch result {
            case .success(let prepared):
                previewURL = prepared.fileURL
                previewDirectory = prepared.directoryURL
            case .failure:
                previewFailed = true
            }
        }
        .onDisappear {
            if let previewDirectory {
                try? FileManager.default.removeItem(at: previewDirectory)
            }
            previewURL = nil
            previewDirectory = nil
            previewFailed = false
        }
    }
}

private struct PreparedFilePreview {
    let fileURL: URL
    let directoryURL: URL
}

private enum FilePreviewService {
    static func makePreviewCopy(of sourceURL: URL) throws -> PreparedFilePreview {
        let values = try sourceURL.resourceValues(
            forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true,
              values.isDirectory != true,
              values.isSymbolicLink != true else {
            throw FileManagerOperationError.sourceMissing
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("3105-Preview", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = directory.appendingPathComponent(sourceURL.lastPathComponent)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            return PreparedFilePreview(fileURL: destination, directoryURL: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}

private struct FileQuickLookController: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        if context.coordinator.url != url {
            context.coordinator.url = url
            controller.reloadData()
        }
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(
            _ controller: QLPreviewController,
            previewItemAt index: Int
        ) -> any QLPreviewItem {
            url as NSURL
        }
    }
}
