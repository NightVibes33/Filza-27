import SwiftUI

struct ThreeOneOSFiveContentView: View {
    @Environment(\.appLanguage) private var language
    @EnvironmentObject private var patchDraftCoordinator: PatchDraftCoordinator
    @State private var selectedTab: Int

    init(initialTab requestedInitialTab: Int = 0) {
#if targetEnvironment(simulator)
        let arguments = ProcessInfo.processInfo.arguments
        let initialTab: Int
        if arguments.contains("--simulate-patch-tab") {
            initialTab = 2
        } else if arguments.contains("--simulate-cleaner-tab") {
            initialTab = 3
        } else if arguments.contains("--simulate-wallpaper-tab") {
            initialTab = 4
        } else {
            initialTab = requestedInitialTab
        }
        _selectedTab = State(initialValue: initialTab)
#else
        _selectedTab = State(initialValue: requestedInitialTab)
#endif
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardView()
                .tabItem {
                    Label(language.text("tab.home"), systemImage: "house")
                }
                .tag(0)

            AppDataBrowserView()
                .tabItem {
                    Label(language.text("tab.files"), systemImage: "folder")
                }
                .tag(1)

            PatchProjectsView()
                .tabItem {
                    Label(language.text("tab.patches"), systemImage: "shippingbox")
                }
                .tag(2)

            CleanerView()
                .tabItem {
                    Label(language.text("tab.cleaner"), systemImage: "sparkles")
                }
                .tag(3)

            WallpaperLabView()
                .tabItem {
                    Label(language.text("tab.wallpapers"), systemImage: "photo.on.rectangle.angled")
                }
                .tag(4)
        }
        .tint(AppTheme.accent)
        .onChange(of: patchDraftCoordinator.request?.id) { requestID in
            if requestID != nil { selectedTab = 2 }
        }
        .onChange(of: patchDraftCoordinator.importRequest?.id) { requestID in
            if requestID != nil { selectedTab = 2 }
        }
    }
}

private struct DashboardView: View {
    @Environment(\.appLanguage) private var language
    @EnvironmentObject private var appState: AppState
    @State private var showSettings = false
    @State private var showLogs = false

    var body: some View {
        NavigationStack {
            List {
                deviceSection
                signingSection
            }
            .navigationBarTitleDisplayMode(.inline)
            .tint(AppTheme.accent)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showLogs = true } label: {
                        Image(systemName: "apple.terminal")
                    }
                    .accessibilityLabel(language.text("accessibility.open_logs"))
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel(language.text("accessibility.open_settings"))
                }
            }
            .sheet(isPresented: $showSettings) { ThreeOneOSFiveSettingsView() }
            .sheet(isPresented: $showLogs) { LogView() }
        }
    }

    private var signingSection: some View {
        Section {
            Label {
                Text(language.text("dashboard.enterprise_signing"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "checkmark.seal")
                    .foregroundStyle(AppTheme.accent)
            }
            .padding(.vertical, 4)
        } header: {
            Text(language.text("dashboard.installation"))
        }
    }

    private var deviceSection: some View {
        Section {
            LabeledContent(language.text("dashboard.hardware_model")) {
                Text(AppInfo.displayMachineName)
                    .font(.body.monospaced())
            }
            LabeledContent(language.text("settings.ios_version")) {
                Text("\(AppInfo.osVersion) (\(AppInfo.osBuild))")
                    .font(.body.monospaced())
            }
            HStack {
                Text(language.text("settings.compatibility"))
                Spacer()
                Label(
                    language.text(appState.isSupported ? "settings.supported" : "settings.unsupported"),
                    systemImage: appState.isSupported ? "checkmark.circle.fill" : "xmark.circle.fill"
                )
                .foregroundStyle(appState.isSupported ? Color.green : Color.red)
            }
        } header: {
            Text(language.text("common.device"))
        } footer: {
            Text(language.text("settings.supported_range_summary"))
        }
    }
}
