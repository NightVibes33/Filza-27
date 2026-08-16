import SwiftUI

struct FilesTabToolbarButton: View {
    @Environment(\.appLanguage) private var language
    @Binding var session: FilesTabSession
    @State private var isShowingSwitcher = false

    var body: some View {
        Button {
            isShowingSwitcher = true
        } label: {
            Image(systemName: "square.on.square")
        }
        .accessibilityLabel(language.text("browser.tabs"))
        .accessibilityValue("\(session.tabs.count)")
        .sheet(isPresented: $isShowingSwitcher) {
            FilesTabSwitcherView(session: $session)
        }
    }
}

struct FilesTabStrip: View {
    @Environment(\.appLanguage) private var language
    @Binding var session: FilesTabSession
    @State private var renameTargetID: UUID?
    @State private var renameText = ""

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(session.tabs) { tab in
                    tabItem(tab)
                }

                Button {
                    session.openTab()
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.accent)
                .accessibilityLabel(language.text("browser.new_tab"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .alert(
            language.text("browser.rename_tab"),
            isPresented: renamePresentation
        ) {
            TextField(language.text("browser.tab_name"), text: $renameText)
            Button(language.text("common.cancel"), role: .cancel) {
                renameTargetID = nil
            }
            Button(language.text("common.done")) {
                if let renameTargetID {
                    session.renameTab(renameTargetID, to: renameText)
                }
                renameTargetID = nil
            }
        } message: {
            Text(language.text("browser.tab_name_message"))
        }
    }

    private func tabItem(_ tab: FilesTabState) -> some View {
        let isSelected = tab.id == session.selectedTabID
        return HStack(spacing: 2) {
            Button {
                session.selectTab(tab.id)
            } label: {
                Label(
                    tab.displayTitle(defaultTitle: language.text("browser.tabs_root")),
                    systemImage: isSelected ? "folder.fill" : "folder"
                )
                .font(.caption.weight(isSelected ? .semibold : .regular))
                .lineLimit(1)
                .padding(.leading, 8)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)

            Button {
                session.closeTab(tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .frame(width: 24, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(language.text("browser.close_tab"))
        }
        .foregroundStyle(isSelected ? AppTheme.accent : Color.secondary)
        .background(
            isSelected ? AppTheme.accent.opacity(0.12) : Color.secondary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .contextMenu {
            Button {
                beginRename(tab)
            } label: {
                Label(language.text("browser.rename_tab"), systemImage: "pencil")
            }
            Button {
                session.closeOtherTabs(keeping: tab.id)
            } label: {
                Label(language.text("browser.close_other_tabs"), systemImage: "square.on.square.dashed")
            }
            Button(role: .destructive) {
                session.closeTab(tab.id)
            } label: {
                Label(language.text("browser.close_tab"), systemImage: "xmark")
            }
        }
    }

    private var renamePresentation: Binding<Bool> {
        Binding(
            get: { renameTargetID != nil },
            set: { if !$0 { renameTargetID = nil } }
        )
    }

    private func beginRename(_ tab: FilesTabState) {
        renameText = tab.displayTitle(defaultTitle: language.text("browser.tabs_root"))
        renameTargetID = tab.id
    }
}
