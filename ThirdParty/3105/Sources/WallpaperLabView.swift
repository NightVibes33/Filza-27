import SwiftUI
import UniformTypeIdentifiers

private enum WallpaperPickerPolicy {
    static let packageType = UTType(filenameExtension: "tendies") ?? .data
    static let allowedContentTypes: [UTType] = [packageType, .data]
}

struct WallpaperLabView: View {
    @Environment(\.appLanguage) private var language
    @State private var report: WallpaperAccessReport?
    @State private var accessError: String?
    @State private var packages: [WallpaperStagedPackage] = []
    @State private var receipts: [WallpaperInstallReceipt] = []
    @State private var selectedPackageID: UUID?
    @State private var isBusy = false
    @State private var operationKey = "wallpaper.checking"
    @State private var showImporter = false
    @State private var alert: WallpaperLabAlert?
    @State private var hasLoaded = false

    private var selectedPackage: WallpaperStagedPackage? {
        packages.first { $0.id == selectedPackageID }
    }

    private var activeReceipts: [WallpaperInstallReceipt] {
        receipts.filter { $0.status == .installed || $0.status == .preparing }
    }

    var body: some View {
        NavigationStack {
            List {
                accessSection
                packagesSection
                if !activeReceipts.isEmpty { resetSection }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(language.text("wallpaper.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .overlay { busyOverlay }
            .alert(item: $alert, content: alertContent)
            .sheet(isPresented: $showImporter) {
                FileDocumentPicker(
                    allowedContentTypes: WallpaperPickerPolicy.allowedContentTypes,
                    copiesSelectedDocument: true,
                    allowsMultipleSelection: true,
                    onSelection: { result in
                        showImporter = false
                        if case .success(let urls) = result, !urls.isEmpty {
                            importPackages(urls)
                        }
                    },
                    onCancel: { showImporter = false }
                )
                .ignoresSafeArea()
            }
            .onAppear {
                guard !hasLoaded else { return }
                hasLoaded = true
                reloadLocalData()
                checkAccess()
            }
        }
    }

    private var accessSection: some View {
        Section {
            if let report {
                HStack {
                    Label(
                        language.text(report.canInstall
                            ? "wallpaper.access_ready"
                            : "wallpaper.access_read_only"),
                        systemImage: report.canInstall
                            ? "checkmark.shield.fill"
                            : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(report.canInstall ? Color.green : Color.orange)
                    Spacer()
                    Text("MHA-C2")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Text(
                    language.text(
                        "wallpaper.store_summary",
                        report.layout.generation,
                        Int64(report.layout.extensionDescriptorDirectories.count),
                        Int64(report.descriptorCount)
                    )
                )
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            } else if let accessError {
                Label(accessError, systemImage: "xmark.shield.fill")
                    .foregroundStyle(.red)
                Button(language.text("wallpaper.try_again")) { checkAccess() }
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(language.text("wallpaper.checking"))
                }
            }
        } header: { Text(language.text("wallpaper.access")) }
    }

    private var packagesSection: some View {
        Section {
            if packages.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(AppTheme.accent)
                    Text(language.text("wallpaper.empty_packages"))
                        .font(.headline)
                    Text(language.text("wallpaper.empty_packages_message"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button(language.text("wallpaper.import")) { showImporter = true }
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                ForEach(packages) { package in
                    Button {
                        selectedPackageID = package.id
                    } label: {
                        packageRow(package)
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button(role: .destructive) {
                            alert = WallpaperLabAlert(kind: .deletePackage(package))
                        } label: {
                            Label(language.text("browser.delete"), systemImage: "trash")
                        }
                    }
                }
                installAction
            }
        } header: { Text(language.text("wallpaper.packages")) }
    }

    private func packageRow(_ package: WallpaperStagedPackage) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.title3)
                .foregroundStyle(AppTheme.accent)
                .frame(width: 36, height: 36)
                .background(
                    AppTheme.accent.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(package.displayName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(
                    language.text(
                        "wallpaper.package_summary",
                        Int64(package.payload.descriptors.count),
                        sizeText(package.payload.totalBytes)
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(
                systemName: selectedPackageID == package.id
                    ? "checkmark.circle.fill" : "circle"
            )
            .font(.title3)
            .foregroundStyle(
                selectedPackageID == package.id ? AppTheme.accent : Color.secondary
            )
        }
        .contentShape(Rectangle())
        .padding(.vertical, 3)
    }

    private var resetSection: some View {
        Section {
            LabeledContent(language.text("wallpaper.installed_by_3105")) {
                Text("\(activeReceipts.reduce(0) { $0 + $1.installedDescriptors.count })")
                    .monospacedDigit()
            }
            Button(role: .destructive) {
                alert = WallpaperLabAlert(kind: .reset(activeReceipts))
            } label: {
                Label(language.text("wallpaper.reset"), systemImage: "arrow.counterclockwise")
            }
            .disabled(isBusy)
        } footer: { Text(language.text("wallpaper.reset_footer")) }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button { checkAccess() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(isBusy)
            .accessibilityLabel(language.text("wallpaper.try_again"))
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Button { showImporter = true } label: {
                Image(systemName: "plus")
            }
            .disabled(isBusy)
            .accessibilityLabel(language.text("wallpaper.import"))
        }
    }

    private var installAction: some View {
        Button {
            if let selectedPackage {
                alert = WallpaperLabAlert(kind: .install(selectedPackage))
            }
        } label: {
            Label(language.text("wallpaper.install"), systemImage: "square.and.arrow.down")
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .disabled(selectedPackage == nil || report?.canInstall != true || isBusy)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var busyOverlay: some View {
        if isBusy {
            ZStack {
                Color.black.opacity(0.12).ignoresSafeArea()
                VStack(spacing: 12) {
                    ProgressView()
                    Text(language.text(operationKey))
                        .font(.subheadline.weight(.medium))
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    private func alertContent(_ alert: WallpaperLabAlert) -> Alert {
        switch alert.kind {
        case .install(let package):
            return Alert(
                title: Text(language.text("wallpaper.install_warning_title")),
                message: Text(
                    language.text(
                        "wallpaper.install_warning_message",
                        package.displayName,
                        Int64(package.payload.descriptors.count),
                        AppInfo.osVersion,
                        AppInfo.osBuild
                    )
                ),
                primaryButton: .destructive(Text(language.text("wallpaper.install"))) {
                    install(package)
                },
                secondaryButton: .cancel(Text(language.text("common.cancel")))
            )
        case .reset(let activeReceipts):
            return Alert(
                title: Text(language.text("wallpaper.reset_title")),
                message: Text(
                    language.text(
                        "wallpaper.reset_message",
                        Int64(activeReceipts.reduce(0) { $0 + $1.installedDescriptors.count })
                    )
                ),
                primaryButton: .destructive(Text(language.text("wallpaper.reset"))) {
                    resetAllWallpapers(activeReceipts)
                },
                secondaryButton: .cancel(Text(language.text("common.cancel")))
            )
        case .deletePackage(let package):
            return Alert(
                title: Text(language.text("wallpaper.delete_title")),
                message: Text(language.text("wallpaper.delete_message", package.displayName)),
                primaryButton: .destructive(Text(language.text("browser.delete"))) {
                    delete(package)
                },
                secondaryButton: .cancel(Text(language.text("common.cancel")))
            )
        case .message(let titleKey, let message):
            return Alert(
                title: Text(language.text(titleKey)),
                message: Text(message),
                dismissButton: .default(Text(language.text("common.ok")))
            )
        }
    }

    private func reloadLocalData() {
        packages = WallpaperPackageStore.packages()
        if selectedPackageID == nil { selectedPackageID = packages.first?.id }
        if let backupRoot = try? WallpaperPackageStore.backupRoot() {
            receipts = WallpaperInstaller.receipts(in: backupRoot).filter {
                $0.status == .installed || $0.status == .preparing
            }
        }
    }

    private func checkAccess() {
        guard !isBusy else { return }
        isBusy = true
        operationKey = "wallpaper.checking"
        accessError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try deviceAccessReport() }
            DispatchQueue.main.async {
                isBusy = false
                switch result {
                case .success(let newReport):
                    report = newReport
                    log(
                        "wallpaper: probe generation=\(newReport.layout.generation) " +
                            "extensions=\(newReport.layout.extensionDescriptorDirectories.count) " +
                            "writable=\(newReport.canInstall)"
                    )
                case .failure(let error):
                    report = nil
                    accessError = message(for: error)
                    log("wallpaper: probe failed \(error.localizedDescription)")
                }
            }
        }
    }

    private func importPackages(_ urls: [URL]) {
        guard !isBusy else { return }
        isBusy = true
        operationKey = "wallpaper.importing"
        DispatchQueue.global(qos: .userInitiated).async {
            var imported = 0
            var failures: [String] = []
            for url in urls {
                do {
                    _ = try WallpaperPackageStore.importPackage(from: url)
                    imported += 1
                    log("wallpaper: staged \(url.lastPathComponent)")
                } catch {
                    failures.append("\(url.lastPathComponent): \(message(for: error))")
                    log("wallpaper: import rejected \(url.lastPathComponent)")
                }
            }
            DispatchQueue.main.async {
                isBusy = false
                reloadLocalData()
                alert = WallpaperLabAlert(
                    kind: .message(
                        titleKey: failures.isEmpty
                            ? "wallpaper.import_done_title" : "wallpaper.import_result_title",
                        message: failures.isEmpty
                            ? language.text("wallpaper.import_done_message", Int64(imported))
                            : failures.joined(separator: "\n")
                    )
                )
            }
        }
    }

    private func install(_ package: WallpaperStagedPackage) {
        guard !isBusy else { return }
        isBusy = true
        operationKey = "wallpaper.installing"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () throws -> (WallpaperInstallReceipt, WallpaperAccessReport) in
                let requiredExtensions = Set(
                    package.payload.descriptors.map(\.extensionIdentifier)
                )
                let currentReport = try deviceAccessReport(
                    requiredExtensionIdentifiers: requiredExtensions
                )
                guard currentReport.canInstall else { throw WallpaperLabError.accessDenied }
                let backupRoot = try WallpaperPackageStore.backupRoot()
                let receipt = try WallpaperInstaller.install(
                    payload: package.payload,
                    layout: currentReport.layout,
                    backupRoot: backupRoot
                )
                let refreshedReport = try deviceAccessReport(
                    requiredExtensionIdentifiers: requiredExtensions
                )
                return (receipt, refreshedReport)
            }
            DispatchQueue.main.async {
                isBusy = false
                switch result {
                case .success(let (receipt, refreshedReport)):
                    reloadLocalData()
                    report = refreshedReport
                    log("wallpaper: installed descriptors=\(receipt.installedDescriptors.count)")
                    let opened = openApplicationForBundleID("com.apple.PosterBoard")
                    alert = WallpaperLabAlert(
                        kind: .message(
                            titleKey: "wallpaper.install_done_title",
                            message: language.text(
                                opened
                                    ? "wallpaper.install_done_opened"
                                    : "wallpaper.install_done_manual"
                            )
                        )
                    )
                case .failure(let error):
                    log("wallpaper: install failed \(error.localizedDescription)")
                    alert = WallpaperLabAlert(
                        kind: .message(
                            titleKey: "wallpaper.operation_failed",
                            message: message(for: error)
                        )
                    )
                }
            }
        }
    }

    private func resetAllWallpapers(_ receiptsToReset: [WallpaperInstallReceipt]) {
        guard !isBusy else { return }
        isBusy = true
        operationKey = "wallpaper.restoring"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () throws -> WallpaperAccessReport in
                guard let path = ContainerStore.resolveAppContainerPath(
                    bundleID: "com.apple.PosterBoard"
                ) else { throw WallpaperLabError.accessDenied }
                let containerURL = URL(fileURLWithPath: path, isDirectory: true)
                let backupRoot = try WallpaperPackageStore.backupRoot()
                for receipt in receiptsToReset {
                    try WallpaperInstaller.restore(
                        receipt: receipt,
                        containerURL: containerURL,
                        rootValidator: { ContainerStore.isApplicationContainerPath($0.path) }
                    )
                    try WallpaperInstaller.removeReceipt(receipt, from: backupRoot)
                }
                return try deviceAccessReport()
            }
            DispatchQueue.main.async {
                isBusy = false
                switch result {
                case .success(let refreshedReport):
                    reloadLocalData()
                    report = refreshedReport
                    _ = openApplicationForBundleID("com.apple.PosterBoard")
                    alert = WallpaperLabAlert(
                        kind: .message(
                            titleKey: "wallpaper.reset_done_title",
                            message: language.text("wallpaper.reset_done_message")
                        )
                    )
                case .failure(let error):
                    alert = WallpaperLabAlert(
                        kind: .message(
                            titleKey: "wallpaper.operation_failed",
                            message: message(for: error)
                        )
                    )
                }
            }
        }
    }

    private func delete(_ package: WallpaperStagedPackage) {
        do {
            try WallpaperPackageStore.delete(package)
            if selectedPackageID == package.id { selectedPackageID = nil }
            reloadLocalData()
        } catch {
            alert = WallpaperLabAlert(
                kind: .message(
                    titleKey: "wallpaper.operation_failed",
                    message: message(for: error)
                )
            )
        }
    }

    private func deviceAccessReport(
        requiredExtensionIdentifiers: Set<String>? = nil
    ) throws -> WallpaperAccessReport {
#if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--simulate-wallpaper-data") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "3105-Simulated-PosterBoard",
                isDirectory: true
            )
            let descriptors = root.appendingPathComponent(
                "Library/Application Support/PRBPosterExtensionDataStore/72/Extensions/" +
                    "com.apple.WallpaperKit.CollectionsPoster/descriptors",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: descriptors, withIntermediateDirectories: true)
            return try WallpaperAccessProbe.probe(
                containerURL: root,
                rootValidator: { $0.standardizedFileURL == root.standardizedFileURL },
                requiredExtensionIdentifiers: requiredExtensionIdentifiers
            )
        }
#endif
        guard let path = ContainerStore.resolveAppContainerPath(
            bundleID: "com.apple.PosterBoard"
        ) else { throw WallpaperLabError.accessDenied }
        return try WallpaperAccessProbe.probe(
            containerURL: URL(fileURLWithPath: path, isDirectory: true),
            rootValidator: { ContainerStore.isApplicationContainerPath($0.path) },
            requiredExtensionIdentifiers: requiredExtensionIdentifiers
        )
    }

    private func message(for error: Error) -> String {
        if let wallpaperError = error as? WallpaperLabError {
            return language.text(wallpaperError.localizationKey)
        }
        return language.text("wallpaper.error.unknown")
    }

    private func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct WallpaperLabAlert: Identifiable {
    let id = UUID()
    let kind: Kind

    enum Kind {
        case install(WallpaperStagedPackage)
        case reset([WallpaperInstallReceipt])
        case deletePackage(WallpaperStagedPackage)
        case message(titleKey: String, message: String)
    }
}
