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
    @State private var isBusy = false
    @State private var operationKey = "wallpaper.checking"
    @State private var showImporter = false
    @State private var alert: WallpaperLabAlert?
    @State private var hasLoaded = false
    @State private var showSimulatedPackageDetail = false

    let onOpenSettings: () -> Void
    let onOpenLogs: () -> Void

    init(
        onOpenSettings: @escaping () -> Void = {},
        onOpenLogs: @escaping () -> Void = {}
    ) {
        self.onOpenSettings = onOpenSettings
        self.onOpenLogs = onOpenLogs
    }

    var body: some View {
        NavigationStack {
            List {
                accessSection
                packagesSection
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
            .navigationDestination(isPresented: $showSimulatedPackageDetail) {
                if let package = packages.first {
                    WallpaperPackageDetailView(
                        package: package,
                        canInstall: report?.canInstall == true && !isBusy,
                        onApply: {
                            alert = WallpaperLabAlert(kind: .install(package))
                        }
                    )
                }
            }
            .onAppear {
                guard !hasLoaded else { return }
                hasLoaded = true
                reloadLocalData()
                checkAccess()
#if targetEnvironment(simulator)
                if ProcessInfo.processInfo.arguments.contains(
                    "--simulate-wallpaper-detail"
                ), !packages.isEmpty {
                    DispatchQueue.main.async {
                        showSimulatedPackageDetail = true
                    }
                }
#endif
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
                        .font(.system(size: AppTheme.emptyIconSize, weight: .light))
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
                    NavigationLink {
                        WallpaperPackageDetailView(
                            package: package,
                            canInstall: report?.canInstall == true && !isBusy,
                            onApply: {
                                alert = WallpaperLabAlert(kind: .install(package))
                            }
                        )
                    } label: {
                        packageRow(package)
                    }
                }
            }
        } header: {
            Text(language.text("wallpaper.packages"))
        } footer: {
            Text(language.text("wallpaper.after_apply_guide"))
        }
    }

    private func packageRow(_ package: WallpaperStagedPackage) -> some View {
        HStack(spacing: 12) {
            AppRowIcon(systemName: "photo.on.rectangle.angled")
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
        }
        .contentShape(Rectangle())
        .padding(.vertical, 3)
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
        AppUtilityToolbar(
            language: language,
            onOpenSettings: onOpenSettings,
            onOpenLogs: onOpenLogs
        )
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
                do {
                    try WallpaperPackageStore.delete(package)
                } catch {
                    log("wallpaper: staged package leftover after apply")
                }
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

private struct WallpaperPackageDetailView: View {
    @Environment(\.appLanguage) private var language
    let package: WallpaperStagedPackage
    let canInstall: Bool
    let onApply: () -> Void

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    AppRowIcon(
                        systemName: "photo.on.rectangle.angled",
                        symbolSize: 24,
                        frameSize: 52
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        Text(package.displayName)
                            .font(.title3.weight(.bold))
                        Text(language.text(
                            "wallpaper.package_summary",
                            Int64(package.payload.descriptors.count),
                            sizeText(package.payload.totalBytes)
                        ))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        Text(language.text(
                            "wallpaper.package_files",
                            Int64(package.payload.fileCount)
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }

            Section(language.text("wallpaper.package_details")) {
                ForEach(package.payload.descriptors) { descriptor in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(descriptor.directoryURL.lastPathComponent)
                            .font(.body.weight(.semibold))
                        Text(descriptor.extensionIdentifier)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Text(
                            "\(descriptor.fileCount) · \(sizeText(descriptor.byteCount))"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                }
            }

            Section {
                Button(action: onApply) {
                    Text(language.text("wallpaper.install"))
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canInstall)
            } footer: {
                Text(language.text("wallpaper.after_apply_guide"))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(package.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

struct InstalledWallpaperPackageDetailView: View {
    @Environment(\.appLanguage) private var language
    @Environment(\.dismiss) private var dismiss
    @State private var report: WallpaperAccessReport?
    @State private var isBusy = true
    @State private var operationKey = "wallpaper.checking"
    @State private var alert: InstalledWallpaperAlert?

    let package: WallpaperStagedPackage
    let onApplied: () -> Void

    var body: some View {
        WallpaperPackageDetailView(
            package: package,
            canInstall: report?.canInstall == true && !isBusy,
            onApply: {
                alert = InstalledWallpaperAlert(kind: .confirmInstall)
            }
        )
        .overlay { busyOverlay }
        .alert(item: $alert, content: alertContent)
        .onAppear(perform: checkAccess)
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
                .background(
                    .regularMaterial,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
            }
        }
    }

    private func alertContent(_ alert: InstalledWallpaperAlert) -> Alert {
        switch alert.kind {
        case .confirmInstall:
            return Alert(
                title: Text(language.text("wallpaper.install_warning_title")),
                message: Text(language.text(
                    "wallpaper.install_warning_message",
                    package.displayName,
                    Int64(package.payload.descriptors.count),
                    AppInfo.osVersion,
                    AppInfo.osBuild
                )),
                primaryButton: .destructive(
                    Text(language.text("wallpaper.install")),
                    action: install
                ),
                secondaryButton: .cancel(Text(language.text("common.cancel")))
            )
        case .success(let openedPosterBoard):
            return Alert(
                title: Text(language.text("wallpaper.install_done_title")),
                message: Text(language.text(
                    openedPosterBoard
                        ? "wallpaper.install_done_opened"
                        : "wallpaper.install_done_manual"
                )),
                dismissButton: .default(Text(language.text("common.ok"))) {
                    dismiss()
                }
            )
        case .failure(let message):
            return Alert(
                title: Text(language.text("wallpaper.operation_failed")),
                message: Text(message),
                dismissButton: .default(Text(language.text("common.ok")))
            )
        }
    }

    private func checkAccess() {
        guard isBusy else { return }
        operationKey = "wallpaper.checking"
        DispatchQueue.global(qos: .userInitiated).async {
            let requiredExtensions = Set(
                package.payload.descriptors.map(\.extensionIdentifier)
            )
            let result = Result {
                try WallpaperDeviceAccessService.report(
                    requiredExtensionIdentifiers: requiredExtensions
                )
            }
            DispatchQueue.main.async {
                isBusy = false
                switch result {
                case .success(let newReport):
                    report = newReport
                case .failure(let error):
                    report = nil
                    alert = InstalledWallpaperAlert(
                        kind: .failure(message(for: error))
                    )
                }
            }
        }
    }

    private func install() {
        guard !isBusy else { return }
        isBusy = true
        operationKey = "wallpaper.installing"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try WallpaperDeviceAccessService.install(package)
            }
            DispatchQueue.main.async {
                isBusy = false
                switch result {
                case .success(let (receipt, refreshedReport)):
                    report = refreshedReport
                    onApplied()
                    log(
                        "wallpaper: installed descriptors=" +
                            "\(receipt.installedDescriptors.count)"
                    )
                    let opened = openApplicationForBundleID("com.apple.PosterBoard")
                    alert = InstalledWallpaperAlert(kind: .success(opened))
                case .failure(let error):
                    log("wallpaper: install failed \(error.localizedDescription)")
                    alert = InstalledWallpaperAlert(
                        kind: .failure(message(for: error))
                    )
                }
            }
        }
    }

    private func message(for error: Error) -> String {
        if let wallpaperError = error as? WallpaperLabError {
            return language.text(wallpaperError.localizationKey)
        }
        return language.text("wallpaper.error.unknown")
    }
}

private struct InstalledWallpaperAlert: Identifiable {
    let id = UUID()
    let kind: Kind

    enum Kind {
        case confirmInstall
        case success(Bool)
        case failure(String)
    }
}

struct WallpaperResetSettingsView: View {
    @Environment(\.appLanguage) private var language
    @State private var report: WallpaperAccessReport?
    @State private var isBusy = false
    @State private var operationKey = "wallpaper.checking"
    @State private var alert: WallpaperResetAlert?

    var body: some View {
        List {
            Section(language.text("wallpaper.access")) {
                if let report {
                    Label(
                        language.text(
                            report.canInstall
                                ? "wallpaper.access_ready"
                                : "wallpaper.access_read_only"
                        ),
                        systemImage: report.canInstall
                            ? "checkmark.shield.fill"
                            : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(report.canInstall ? Color.green : Color.orange)
                    LabeledContent(language.text("wallpaper.custom_count")) {
                        Text("\(report.customDescriptorCount)")
                            .monospacedDigit()
                    }
                } else if !isBusy {
                    Label(
                        language.text("wallpaper.error.access"),
                        systemImage: "xmark.shield.fill"
                    )
                    .foregroundStyle(.red)
                }
            }

            if let report, report.customDescriptorCount > 0 {
                Section {
                    Button(role: .destructive) {
                        alert = WallpaperResetAlert(kind: .confirm)
                    } label: {
                        Label(
                            language.text("wallpaper.reset"),
                            systemImage: "arrow.counterclockwise"
                        )
                    }
                    .disabled(isBusy || !report.canInstall)
                } footer: {
                    Text(language.text("wallpaper.reset_footer"))
                }
            } else if report != nil {
                Section {
                    VStack(spacing: 10) {
                        Image(systemName: "photo.stack")
                            .font(.system(
                                size: AppTheme.emptyIconSize,
                                weight: .light
                            ))
                            .foregroundStyle(AppTheme.accent)
                        Text(language.text("wallpaper.no_custom_title"))
                            .font(.headline)
                        Text(language.text("wallpaper.no_custom_message"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(language.text("wallpaper.reset"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: checkAccess) {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isBusy)
                .accessibilityLabel(language.text("wallpaper.try_again"))
            }
        }
        .overlay { busyOverlay }
        .alert(item: $alert, content: alertContent)
        .onAppear(perform: checkAccess)
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
                .background(
                    .regularMaterial,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
            }
        }
    }

    private func alertContent(_ alert: WallpaperResetAlert) -> Alert {
        switch alert.kind {
        case .confirm:
            return Alert(
                title: Text(language.text("wallpaper.reset_title")),
                message: Text(language.text(
                    "wallpaper.reset_message",
                    Int64(report?.customDescriptorCount ?? 0)
                )),
                primaryButton: .destructive(
                    Text(language.text("wallpaper.reset")),
                    action: resetCollections
                ),
                secondaryButton: .cancel(Text(language.text("common.cancel")))
            )
        case .success:
            return Alert(
                title: Text(language.text("wallpaper.reset_done_title")),
                message: Text(language.text("wallpaper.reset_done_message")),
                dismissButton: .default(Text(language.text("common.ok")))
            )
        case .failure(let message):
            return Alert(
                title: Text(language.text("wallpaper.operation_failed")),
                message: Text(message),
                dismissButton: .default(Text(language.text("common.ok")))
            )
        }
    }

    private func checkAccess() {
        guard !isBusy else { return }
        isBusy = true
        operationKey = "wallpaper.checking"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try WallpaperDeviceAccessService.report()
            }
            DispatchQueue.main.async {
                isBusy = false
                switch result {
                case .success(let newReport):
                    report = newReport
                case .failure(let error):
                    report = nil
                    alert = WallpaperResetAlert(
                        kind: .failure(message(for: error))
                    )
                }
            }
        }
    }

    private func resetCollections() {
        guard !isBusy else { return }
        isBusy = true
        operationKey = "wallpaper.restoring"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try WallpaperDeviceAccessService.resetCustomCollections()
            }
            DispatchQueue.main.async {
                isBusy = false
                switch result {
                case .success(let (removed, refreshedReport)):
                    report = refreshedReport
                    log("wallpaper: reset removed \(removed) custom descriptors")
                    _ = openApplicationForBundleID("com.apple.PosterBoard")
                    alert = WallpaperResetAlert(kind: .success)
                case .failure(let error):
                    alert = WallpaperResetAlert(
                        kind: .failure(message(for: error))
                    )
                }
            }
        }
    }

    private func message(for error: Error) -> String {
        if let wallpaperError = error as? WallpaperLabError {
            return language.text(wallpaperError.localizationKey)
        }
        return language.text("wallpaper.error.unknown")
    }
}

private struct WallpaperResetAlert: Identifiable {
    let id = UUID()
    let kind: Kind

    enum Kind {
        case confirm
        case success
        case failure(String)
    }
}

private struct WallpaperLabAlert: Identifiable {
    let id = UUID()
    let kind: Kind

    enum Kind {
        case install(WallpaperStagedPackage)
        case message(titleKey: String, message: String)
    }
}
