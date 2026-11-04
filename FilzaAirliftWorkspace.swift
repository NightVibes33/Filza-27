import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Paired transport utility exposed from Filza; native Filza remains the only file browser.
/// Reads are Erosion-compatible, but all previews and edits occur on an
/// independent local snapshot. Remote writes must be explicitly confirmed.
struct FilzaAirliftWorkspaceView: View {
    @ObservedObject private var catalog = FilzaAirliftCatalogStore.shared
    @State private var remotePath: String
    @State private var isFolder = true
    @State private var busy = false
    @State private var alertMessage: String?
    @State private var showReadConfirmation = false
    @State private var showWriteConfirmation = false
    @State private var showFolderWriteConfirmation = false
    @State private var showRemoveConfirmation = false
    @State private var importing = false
    @State private var importingFolder = false
    @State private var stagedFolderURL: URL?
    @State private var stagedWriteURL: URL?
    @State private var snapshot: URL?
    @State private var extractedFolder: URL?
    @State private var lastRemotePath: String?
    @State private var packagedIPA: FilzaAirliftIPAResult?
    @State private var requestedIPA: FilzaAirliftApp?

    init(initialRemotePath: String? = nil) {
        _remotePath = State(initialValue: initialRemotePath ?? "")
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Connection") {
                    LabeledContent("Airlift pairing", value: FilzaAirlift.pairedRecord() == nil ? "Not paired" : "Record available")
                    Text(catalog.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        catalog.refresh()
                    } label: {
                        Label("Scan installed apps and groups", systemImage: "arrow.clockwise")
                    }
                    .disabled(catalog.scanning || busy)
                }
                Section("Paired operations — remote path") {
                    TextField("Absolute device path", text: $remotePath)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.footnote, design: .monospaced))
                    Picker("Read as", selection: $isFolder) {
                        Text("Folder").tag(true)
                        Text("File").tag(false)
                    }
                    .pickerStyle(.segmented)
                    Button {
                        showReadConfirmation = true
                    } label: {
                        Label("Read into Filza workspace", systemImage: "folder.badge.plus")
                    }
                    .disabled(busy || remotePath.isEmpty)
                    Button {
                        importing = true
                    } label: {
                        Label("Write local file to remote path", systemImage: "square.and.arrow.up")
                    }
                    .disabled(busy || remotePath.isEmpty || isFolder)
                    Button {
                        importingFolder = true
                    } label: {
                        Label("Upload local folder contents", systemImage: "folder.badge.plus")
                    }
                    .disabled(busy || remotePath.isEmpty || !isFolder)
                    Button(role: .destructive) {
                        showRemoveConfirmation = true
                    } label: {
                        Label("Delete remote path", systemImage: "trash")
                    }
                    .disabled(busy || remotePath.isEmpty)
                    Text("Airlift uses a paired-device staging and restoration transaction, not unrestricted sandbox access. Remote read/write can fail on any OS build.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("System paths — read-only") {
                    NavigationLink {
                        FilzaCoreMediaBrowserView(path: "/usr/libexec")
                    } label: {
                        Label("CoreMedia /usr/libexec browser", systemImage: "terminal")
                    }
                    Text("Uses Erosion's CoreMedia bytestream reader when available. Unrelated to Airlift pairing; no system write access.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let snapshot {
                    Section("Saved snapshot") {
                        LabeledContent("Remote", value: lastRemotePath ?? "")
                        LabeledContent("File", value: snapshot.lastPathComponent)
                        ShareLink(item: snapshot) {
                            Label("Export snapshot", systemImage: "square.and.arrow.up")
                        }
                        if extractedFolder != nil {
                            Text("Open the original Filza 27 file browser → Device Storage → [Airlift] Snapshots. This transport panel does not embed a second file browser.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let packagedIPA {
                    Section("Prepared IPA") {
                        ShareLink(item: packagedIPA.fileURL) {
                            Label("Export repackaged IPA", systemImage: "shippingbox")
                        }
                        Text(packagedIPA.encryptionStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Packaging does not decrypt FairPlay or resign the app.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if !catalog.apps.isEmpty {
                    Section("Installed application bundle paths") {
                        ForEach(catalog.apps) { app in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(app.name).font(.subheadline.weight(.medium))
                                Text(app.bundleID).font(.caption.monospaced()).foregroundStyle(.secondary)
                                HStack {
                                    if let bundle = app.bundlePath {
                                        Button("Select .app") {
                                            remotePath = bundle
                                            isFolder = true
                                        }
                                        Button("Package IPA") { requestedIPA = app }
                                    }
                                    if let data = app.dataPath {
                                        Button("Select data") {
                                            remotePath = data
                                            isFolder = true
                                        }
                                    }
                                }
                                .font(.caption)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
                if !catalog.appGroups.isEmpty {
                    Section("Discovered app-group paths") {
                        ForEach(catalog.appGroups, id: \.self) { path in
                            Button(path) {
                                remotePath = path
                                isFolder = true
                            }
                            .font(.caption.monospaced())
                        }
                    }
                }
            }
            .navigationTitle("Airlift Tools")
            .navigationBarTitleDisplayMode(.inline)
            .overlay {
                if busy {
                    ProgressView("Airlift operation in progress")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .onAppear {
                if FilzaAirlift.pairedRecord() != nil && catalog.apps.isEmpty {
                    catalog.refresh()
                }
            }
            .confirmationDialog(
                "Read \(remotePath) via Airlift?",
                isPresented: $showReadConfirmation,
                titleVisibility: .visible
            ) {
                Button("Perform remote read and restoration") { read() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Airlift may temporarily move device-side data. This cannot be treated as an ordinary read-only filesystem operation.")
            }
            .confirmationDialog(
                "Overwrite \(remotePath) using Airlift?",
                isPresented: $showWriteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Overwrite remote file", role: .destructive) { write() }
                Button("Cancel", role: .cancel) { clearStagedWrite() }
            } message: {
                Text("This changes device-side data. The selected source file will replace the exact remote path only if the backend permits it.")
            }
            .confirmationDialog(
                "Write local folder contents into \(remotePath)?",
                isPresented: $showFolderWriteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Upload folder contents", role: .destructive) { writeFolder() }
                Button("Cancel", role: .cancel) { clearStagedFolder() }
            } message: {
                Text("This modifies the target remote directory. The upload does not automatically create a backup.")
            }
            .confirmationDialog(
                "Delete \(remotePath) from the device?",
                isPresented: $showRemoveConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete remote path", role: .destructive) { removeRemote() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The remote file or directory will be removed if Airlift permits it. There is no undo.")
            }
            .confirmationDialog(
                "Package the installed app using Airlift?",
                isPresented: Binding(
                    get: { requestedIPA != nil },
                    set: { if !$0 { requestedIPA = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Prepare and package IPA") {
                    if let app = requestedIPA { packageIPA(app) }
                    requestedIPA = nil
                }
                Button("Cancel", role: .cancel) { requestedIPA = nil }
            } message: {
                Text("This exports the .app contents and packages an IPA. It does not decrypt FairPlay. Airlift's remote folder read may temporarily move data.")
            }
            .fileImporter(
                isPresented: $importing,
                allowedContentTypes: [.item, .data],
                allowsMultipleSelection: false
            ) { result in
                do {
                    guard let source = try result.get().first else { return }
                    let access = source.startAccessingSecurityScopedResource()
                    defer { if access { source.stopAccessingSecurityScopedResource() } }
                    let local = FileManager.default.temporaryDirectory
                        .appendingPathComponent("airlift-write-\(UUID().uuidString)")
                    try FileManager.default.copyItem(at: source, to: local)
                    stagedWriteURL = local
                    showWriteConfirmation = true
                } catch {
                    alertMessage = error.localizedDescription
                }
            }
            .fileImporter(
                isPresented: $importingFolder,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                do {
                    guard let source = try result.get().first else { return }
                    let access = source.startAccessingSecurityScopedResource()
                    defer { if access { source.stopAccessingSecurityScopedResource() } }
                    let local = FileManager.default.temporaryDirectory
                        .appendingPathComponent("airlift-folder-\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.copyItem(at: source, to: local)
                    stagedFolderURL = local
                    showFolderWriteConfirmation = true
                } catch {
                    alertMessage = error.localizedDescription
                }
            }
            .alert("Airlift", isPresented: Binding(
                get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } }
            )) {
                Button("OK", role: .cancel) { alertMessage = nil }
            } message: {
                Text(alertMessage ?? "")
            }
        }
    }

    private func read() {
        let path = remotePath
        let folder = isFolder
        busy = true
        Task {
            do {
                let saved = try await FilzaAirlift.snapshot(path: path, folder: folder)
                snapshot = saved
                lastRemotePath = path
                extractedFolder = nil
                if folder {
                    let directory = saved.deletingPathExtension()
                        .appendingPathComponent("Contents", isDirectory: true)
                    try FileManager.default.createDirectory(
                        at: directory, withIntermediateDirectories: true
                    )
                    try FileManager.default.unzipItem(at: saved, to: directory)
                    extractedFolder = directory
                }
                alertMessage = "Snapshot saved in Filza 27 → Device Storage → [Airlift] Snapshots."
            } catch {
                alertMessage = error.localizedDescription
            }
            busy = false
        }
    }

    private func packageIPA(_ app: FilzaAirliftApp) {
        busy = true
        Task {
            do {
                packagedIPA = try await FilzaAirliftIPAExporter.export(app)
                alertMessage = packagedIPA?.encryptionStatus ?? "IPA exported"
            } catch {
                alertMessage = error.localizedDescription
            }
            busy = false
        }
    }

    private func clearStagedFolder() {
        if let stagedFolderURL { try? FileManager.default.removeItem(at: stagedFolderURL) }
        stagedFolderURL = nil
    }

    private func writeFolder() {
        guard let stagedFolderURL else { return }
        let path = remotePath
        busy = true
        Task {
            defer {
                busy = false
                clearStagedFolder()
            }
            do {
                try await FilzaAirlift.writeFolder(localURL: stagedFolderURL, remoteDirectory: path)
                alertMessage = "Airlift folder upload succeeded: \(path)"
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }

    private func removeRemote() {
        let path = remotePath
        busy = true
        Task {
            do {
                try await FilzaAirlift.removeRemote(path: path)
                alertMessage = "Airlift removed: \(path)"
            } catch {
                alertMessage = error.localizedDescription
            }
            busy = false
        }
    }

    private func clearStagedWrite() {
        if let stagedWriteURL { try? FileManager.default.removeItem(at: stagedWriteURL) }
        stagedWriteURL = nil
    }

    private func write() {
        guard let stagedWriteURL else { return }
        let path = remotePath
        busy = true
        Task {
            defer {
                busy = false
                clearStagedWrite()
            }
            do {
                try await FilzaAirlift.writeFile(localURL: stagedWriteURL, remotePath: path)
                alertMessage = "Remote write succeeded: \(path)"
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }
}

/// Host stays separate from the existing Filza/NFCARD/3105 app lifecycles.
private struct FilzaAirliftEmbeddedRoot: View {
    @StateObject private var patchDraftCoordinator = PatchDraftCoordinator()
    @StateObject private var fileOperationCoordinator = FileOperationCoordinator()
    var body: some View {
        FilzaEmbeddedPanel {
            FilzaAirliftWorkspaceView()
                .environmentObject(patchDraftCoordinator)
                .environmentObject(fileOperationCoordinator)
        }
    }
}
@MainActor @objc(FilzaAirliftHostFactory)
public final class FilzaAirliftHostFactory: NSObject {
    @objc public static func makeViewController() -> UIViewController {
        let controller = UIHostingController(rootView: FilzaAirliftEmbeddedRoot())
        controller.title = "Airlift Tools"
        FilzaEmbeddedPanelPresentation.configure(controller)
        return controller
    }
}