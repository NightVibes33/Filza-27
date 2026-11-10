#!/usr/bin/env python3
"""Fix the hidden Erosion IPA actions in 3105's outer context menu.

The NavigationLink's Open in New Tab menu shadows the inner appRow menu.
Apply after Airlift and IPA and View/Sort staging, on the actual host rows.
"""
from pathlib import Path
path = Path("ThirdParty/3105/Sources/AppDataBrowserView.swift")
view = path.read_text(encoding="utf-8")
marker = "FILZA_3105_IPA_CONTEXT_PARITY"
if marker in view:
    print("IPA row context parity already installed")
    raise SystemExit(0)

def one(before, after, label):
    global view
    count = view.count(before)
    if count != 1:
        raise SystemExit(f"3105 IPA context: {label} anchor count={count}")
    view = view.replace(before, after, 1)

one('''        .contextMenu {
            // Erosion's ORIGINAL two-item context menu, without another tab.
            Button {
                prepareIPA(app)
            } label: {
                Label("Prepare", systemImage: "arrow.down.doc")
            }
            .disabled(exportingBundleID != nil)
            Button {
                decryptPreparedIPA(app)
            } label: {
                Label("Decrypt", systemImage: "doc.zipper")
            }
            .disabled(preparedDirectories[app.bundleID] == nil || exportingBundleID != nil)
        }
''', '', "shadowed inner context menu")

one('''    private func appRow(_ app: InstalledApp) -> some View {''',
'''    // FILZA_3105_IPA_CONTEXT_PARITY
    @ViewBuilder
    private func filzaIPAContextActions(_ app: InstalledApp) -> some View {
        Button {
            prepareIPA(app)
        } label: {
            Label("Prepare", systemImage: "arrow.down.doc")
        }
        .disabled(exportingBundleID != nil)
        Button {
            decryptPreparedIPA(app)
        } label: {
            Label("Decrypt", systemImage: "doc.zipper")
        }
        .disabled(preparedDirectories[app.bundleID] == nil || exportingBundleID != nil)
    }

    private func appRow(_ app: InstalledApp) -> some View {''', "new shared IPA actions")

one('''                            .buttonStyle(.plain)
                            .disabled(snapshotBusy)
''',
'''                            .buttonStyle(.plain)
                            .disabled(snapshotBusy)
                            .contextMenu {
                                filzaIPAContextActions(app)
                            }
''', "remote paired app row")
one('''                        } else {
                            appRow(app)
                        }
                    } else {''',
'''                        } else {
                            appRow(app)
                                .contextMenu {
                                    filzaIPAContextActions(app)
                                }
                        }
                    } else {''', "unresolved app row")
one('''                        .contextMenu {
                            openInNewTabButton(appDestination)
                        }''',
'''                        .contextMenu {
                            openInNewTabButton(appDestination)
                            filzaIPAContextActions(app)
                        }''', "local app navigation link")

assert view.count('filzaIPAContextActions(app)') == 3
assert view.count('Label("Prepare", systemImage: "arrow.down.doc")') == 1
assert view.count('Label("Decrypt", systemImage: "doc.zipper")') == 1
path.write_text(view, encoding="utf-8")
print("GREEN: native 3105 row menus now expose Prepare/Decrypt")
