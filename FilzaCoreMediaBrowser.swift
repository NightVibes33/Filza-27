import SwiftUI

/// Read-only /usr/libexec tree supplied by the optional CoreMedia XPC reader.
/// No Airlift pairing, sandbox extension, or device-side mutation is performed.
struct FilzaCoreMediaBrowserView: View {
    let path: String
    @State private var entries: [FilzaCoreMediaItem] = []
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var localPreview: URL?

    var body: some View {
        List {
            Section {
                Text(path)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                Text("Read-only CoreMedia bytestream viewer. This capability is device- and OS-dependent; it never grants general system filesystem access.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if loading {
                ProgressView("Reading CoreMedia directory…")
            } else if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.secondary)
                    Button("Retry") { reload() }
                }
            } else {
                Section("Directory entries") {
                    ForEach(entries) { entry in
                        if entry.isDirectory {
                            NavigationLink {
                                FilzaCoreMediaBrowserView(path: entry.path)
                            } label: {
                                Label(entry.name, systemImage: "folder")
                            }
                        } else {
                            Button {
                                read(entry)
                            } label: {
                                HStack {
                                    Label(entry.name, systemImage: "doc")
                                    Spacer()
                                    Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    if entries.isEmpty {
                        Text("No readable entries returned")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let localPreview {
                Section("Local preview") {
                    LabeledContent("Saved copy", value: localPreview.lastPathComponent)
                    ShareLink(item: localPreview) {
                        Label("Export local copy", systemImage: "square.and.arrow.up")
                    }
                    Text("This is a local temporary copy; changes are not written to /usr/libexec.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(path == "/usr/libexec" ? "CoreMedia /usr/libexec" : URL(fileURLWithPath: path).lastPathComponent)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { reload() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(loading)
            }
        }
        .onAppear { if entries.isEmpty && errorMessage == nil { reload() } }
    }

    private func reload() {
        guard !loading else { return }
        loading = true
        errorMessage = nil
        let requested = path
        Task {
            do {
                let result = try await Task.detached(priority: .utility) {
                    try FilzaCoreMediaReader.listDirectory(at: URL(fileURLWithPath: requested))
                }.value
                entries = result.sorted {
                    if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
            } catch {
                errorMessage = error.localizedDescription
                entries = []
            }
            loading = false
        }
    }

    private func read(_ entry: FilzaCoreMediaItem) {
        guard !loading else { return }
        loading = true
        errorMessage = nil
        Task {
            do {
                let bytes = try await Task.detached(priority: .utility) {
                    try FilzaCoreMediaReader.readFileData(atPath: entry.path, maximumBytes: 64 * 1024 * 1024)
                }.value
                let root = FileManager.default.temporaryDirectory
                    .appendingPathComponent("FilzaCoreMediaPreviews", isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let safeName = URL(fileURLWithPath: entry.path).lastPathComponent
                let local = root.appendingPathComponent(UUID().uuidString + "-" + safeName)
                try bytes.write(to: local, options: .atomic)
                localPreview = local
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
            loading = false
        }
    }
}