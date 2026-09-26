import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

enum NFCARDTheme {
    static let background = Color(red: 0.015, green: 0.022, blue: 0.024)
    static let surface = Color(red: 0.035, green: 0.052, blue: 0.052)
    static let surfaceRaised = Color(red: 0.050, green: 0.069, blue: 0.068)
    static let border = Color.white.opacity(0.075)
    static let accent = Color(red: 0.27, green: 0.88, blue: 0.62)
    static let accentSoft = Color(red: 0.11, green: 0.31, blue: 0.24)
    static let text = Color.white
    static let secondary = Color(red: 0.63, green: 0.67, blue: 0.68)
    static let danger = Color(red: 1.00, green: 0.34, blue: 0.37)
}

private struct NFCARDPanel<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .fill(NFCARDTheme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 17, style: .continuous)
                            .stroke(NFCARDTheme.border, lineWidth: 1)
                    )
            )
    }
}

private struct NFCARDWordmark: View {
    var body: some View {
        HStack(spacing: 0) {
            Text("NFC")
                .foregroundStyle(NFCARDTheme.text)
            Text("ARD")
                .foregroundStyle(NFCARDTheme.accent)
        }
        .font(.system(size: 29, weight: .black, design: .default))
        .tracking(-0.8)
    }
}

struct NFCARDPairingTab: View {
    @EnvironmentObject private var vm: AppViewModel
    @State private var showDeleteConfirm = false

    var body: some View {
        ZStack {
            NFCARDTheme.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 12) {
                    header
                    readyPanel
                    pairingPanel
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            vm.refreshNetworkStatus()
            vm.refreshPairingFile()
        }
        .refreshable {
            vm.refreshNetworkStatus()
            vm.refreshPairingFile()
        }
        .confirmationDialog(
            "Remove pairing?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) { vm.deletePairingFile() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("NFCARD will forget this iPhone. You can pair it again at any time.")
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            NFCARDWordmark()
            Spacer()

            Menu {
                Button {
                    vm.refreshNetworkStatus()
                    vm.refreshPairingFile()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(NFCARDTheme.text)
                    .frame(width: 40, height: 40)
                    .background(NFCARDTheme.surfaceRaised, in: Circle())
                    .overlay(Circle().stroke(NFCARDTheme.border))
            }
        }
        .padding(.horizontal, 2)
    }

    private var readyPanel: some View {
        NFCARDPanel {
            VStack(spacing: 12) {
                HStack(spacing: 11) {
                    Circle()
                        .fill(vm.vpnUp ? NFCARDTheme.accent : Color.orange)
                        .frame(width: 12, height: 12)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(vm.vpnUp ? "NFCARD Ready" : "Connection Required")
                            .font(.headline)
                            .foregroundStyle(NFCARDTheme.text)
                        Text(vm.vpnUp
                             ? "NFCARD is ready to pair and scan Wallet cards."
                             : "Connect LocalDevVPN to continue in NFCARD.")
                            .font(.caption)
                            .foregroundStyle(NFCARDTheme.secondary)
                    }

                    Spacer()

                    Text("iOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)\nv1.3")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(NFCARDTheme.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(NFCARDTheme.accentSoft, in: RoundedRectangle(cornerRadius: 9))
                }

                Button {
                    if let url = URL(string: "localdevvpn://") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "arrow.up.forward.app")
                        Text(vm.vpnUp ? "Open LocalDevVPN" : "Connect LocalDevVPN")
                    }
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(NFCARDTheme.accent, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var pairingPanel: some View {
        NFCARDPanel {
            VStack(alignment: .leading, spacing: 14) {
                if vm.hasPairingFile && vm.pairingPhase != .pairing {
                    HStack(spacing: 11) {
                        ZStack {
                            Circle()
                                .fill(NFCARDTheme.accent)
                                .frame(width: 34, height: 34)
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .black))
                                .foregroundStyle(.black)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Connected")
                                .font(.headline)
                                .foregroundStyle(NFCARDTheme.text)
                            Text("This iPhone is paired with NFCARD and ready for Wallet cards.")
                                .font(.caption)
                                .foregroundStyle(NFCARDTheme.secondary)
                        }

                        Spacer()

                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(NFCARDTheme.danger)
                                .frame(width: 38, height: 38)
                                .background(NFCARDTheme.surfaceRaised, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove pairing")
                    }

                    Button {
                        vm.startPairing()
                    } label: {
                        Label("Pair Again", systemImage: "arrow.triangle.2.circlepath")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .background(NFCARDTheme.accent, in: RoundedRectangle(cornerRadius: 13))
                    }
                    .buttonStyle(.plain)
                } else if vm.pairingPhase == .pairing {
                    if let pin = vm.pairingPIN {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Pairing code ready", systemImage: "key.fill")
                                .font(.headline)
                                .foregroundStyle(NFCARDTheme.text)

                            HStack {
                                Text(pin)
                                    .font(.system(size: 38, weight: .black, design: .monospaced))
                                    .foregroundStyle(NFCARDTheme.text)

                                Spacer()

                                Button {
                                    UIPasteboard.general.string = pin
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .foregroundStyle(NFCARDTheme.accent)
                                        .frame(width: 38, height: 38)
                                        .background(NFCARDTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Copy pairing code")
                            }
                            .padding(12)
                            .background(NFCARDTheme.accentSoft.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))

                            Text("Enter this code when iOS asks to pair with NFCARD. Approve the request, then return here.")
                                .font(.caption)
                                .foregroundStyle(NFCARDTheme.secondary)
                        }
                    } else {
                        HStack(spacing: 11) {
                            ProgressView()
                                .tint(NFCARDTheme.accent)

                            VStack(alignment: .leading, spacing: 3) {
                                Text("Pairing with NFCARD")
                                    .font(.headline)
                                    .foregroundStyle(NFCARDTheme.text)
                                Text("Keep NFCARD open while iOS prepares the pairing request.")
                                    .font(.caption)
                                    .foregroundStyle(NFCARDTheme.secondary)
                            }
                        }
                    }

                    Button(role: .cancel) {
                        vm.cancelPairing()
                    } label: {
                        Label("Stop Pairing", systemImage: "stop.fill")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(NFCARDTheme.danger, in: RoundedRectangle(cornerRadius: 13))
                    }
                    .buttonStyle(.plain)
                } else {
                    HStack(spacing: 11) {
                        Image(systemName: "iphone.gen3")
                            .font(.title2)
                            .foregroundStyle(NFCARDTheme.accent)
                            .frame(width: 34)

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Pair this iPhone")
                                .font(.headline)
                                .foregroundStyle(NFCARDTheme.text)
                            Text("Pair once with NFCARD, then choose and customize your Wallet cards.")
                                .font(.caption)
                                .foregroundStyle(NFCARDTheme.secondary)
                        }
                    }

                    Button {
                        vm.startPairing()
                    } label: {
                        Label("Pair This iPhone", systemImage: "antenna.radiowaves.left.and.right")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .background(NFCARDTheme.accent, in: RoundedRectangle(cornerRadius: 13))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

struct NFCARDWalletCardsTab: View {
    @EnvironmentObject private var vm: AppViewModel
    @State private var newHashText = ""
    @State private var showAddSheet = false

    enum ActiveCardPicker: Identifiable {
        case singleCard(String)
        case bulkAll

        var id: String {
            switch self {
            case .singleCard(let id): return id
            case .bulkAll: return "bulk_all"
            }
        }
    }

    @State private var activePicker: ActiveCardPicker?
    @State private var showSourceDialog = false
    @State private var isPhotosPickerPresented = false
    @State private var isDocumentPickerPresented = false
    @State private var selectedPhotos: [PhotosPickerItem] = []

    var body: some View {
        ZStack {
            NFCARDTheme.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 12) {
                    headerControls

                    if vm.isScanningCards || !vm.scanStatusText.isEmpty {
                        scannerBanner
                    }

                    flashStatus

                    if vm.cards.isEmpty {
                        emptyState
                    } else {
                        ForEach(Array(vm.cards.enumerated()), id: \.element.id) { index, card in
                            NFCARDDetectedCardView(
                                card: card,
                                cardIndex: index,
                                onToggleSelected: { vm.setCardSelected(id: card.id, selected: $0) },
                                onPickImage: {
                                    activePicker = .singleCard(card.id)
                                    showSourceDialog = true
                                },
                                onClearImage: { vm.clearCardImage(for: card.id) },
                                onDelete: { vm.deleteCard(id: card.id) }
                            )
                        }
                    }

                    if !vm.cardFlashLog.isEmpty {
                        flashLog
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showAddSheet) {
            AddCardSheet(hashText: $newHashText) {
                vm.addCardHash(newHashText)
                newHashText = ""
                showAddSheet = false
            }
            .preferredColorScheme(.dark)
            .tint(NFCARDTheme.accent)
        }
        .confirmationDialog("Choose Image Source", isPresented: $showSourceDialog, titleVisibility: .visible) {
            Button {
                isPhotosPickerPresented = true
            } label: {
                Label("Photo Library", systemImage: "photo.on.rectangle")
            }

            Button {
                isDocumentPickerPresented = true
            } label: {
                Label("Choose from Files…", systemImage: "folder")
            }

            Button("Cancel", role: .cancel) {
                activePicker = nil
            }
        }
        .photosPicker(
            isPresented: $isPhotosPickerPresented,
            selection: $selectedPhotos,
            maxSelectionCount: 1,
            matching: .images
        )
        .onChange(of: selectedPhotos) { _, items in
            guard let item = items.first, let picker = activePicker else {
                if items.isEmpty { activePicker = nil }
                return
            }

            let currentPicker = picker
            Task {
                if let image = await item.loadUIImage(maxDimension: 2560) {
                    await MainActor.run {
                        apply(image: image, picker: currentPicker)
                    }
                }

                await MainActor.run {
                    selectedPhotos = []
                    activePicker = nil
                }
            }
        }
        .sheet(isPresented: $isDocumentPickerPresented) {
            DocumentPickerView(allowedContentTypes: [
                .image, .png, .jpeg, .heic,
                UTType(filenameExtension: "webp") ?? .image,
                UTType(filenameExtension: "tiff") ?? .image
            ]) { url in
                guard let picker = activePicker,
                      let data = try? Data(contentsOf: url),
                      let image = ImageEngine.safeImageFromData(data, maxDimension: 2560) else {
                    activePicker = nil
                    return
                }

                apply(image: image, picker: picker)
                activePicker = nil
            }
        }
    }

    private var headerControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Wallet Cards (\(vm.cards.count))")
                    .font(.system(size: 29, weight: .bold))
                    .foregroundStyle(NFCARDTheme.text)

                Spacer()

                Menu {
                    Button {
                        showAddSheet = true
                    } label: {
                        Label("Add Card Manually", systemImage: "plus")
                    }

                    if !vm.cards.isEmpty {
                        Button {
                            activePicker = .bulkAll
                            showSourceDialog = true
                        } label: {
                            Label("Set Skin for All Cards", systemImage: "photo.on.rectangle.angled")
                        }

                        Divider()

                        Button { vm.selectAllCards(true) } label: {
                            Label("Select All", systemImage: "checkmark.circle")
                        }

                        Button { vm.selectAllCards(false) } label: {
                            Label("Deselect All", systemImage: "circle")
                        }

                        Divider()

                        Button(role: .destructive) {
                            vm.clearAllCards()
                        } label: {
                            Label("Clear All Cards", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(NFCARDTheme.text)
                        .frame(width: 40, height: 40)
                        .background(NFCARDTheme.surfaceRaised, in: Circle())
                        .overlay(Circle().stroke(NFCARDTheme.border))
                }
            }

            HStack(spacing: 10) {
                Button {
                    vm.toggleCardScanning()
                } label: {
                    Label(vm.isScanningCards ? "Stop Scan" : "Scan Cards",
                          systemImage: vm.isScanningCards ? "stop.fill" : "antenna.radiowaves.left.and.right")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(vm.isScanningCards ? NFCARDTheme.danger : NFCARDTheme.accent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(
                            (vm.isScanningCards ? NFCARDTheme.danger : NFCARDTheme.accent).opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 14)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(vm.isScanningCards ? NFCARDTheme.danger.opacity(0.65) : NFCARDTheme.accent.opacity(0.65))
                        )
                }
                .buttonStyle(.plain)

                Button {
                    vm.flashCards()
                } label: {
                    HStack(spacing: 7) {
                        if vm.cardFlashPhase == .running {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        } else {
                            Image(systemName: "bolt.fill")
                        }
                        Text(vm.cardFlashPhase == .running ? "Flashing" : "Flash")
                    }
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(vm.canFlashCards ? .black : NFCARDTheme.secondary)
                    .frame(width: 112, height: 44)
                    .background(
                        vm.canFlashCards ? NFCARDTheme.accent : NFCARDTheme.surfaceRaised,
                        in: RoundedRectangle(cornerRadius: 14)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!vm.canFlashCards || vm.cardFlashPhase == .running)
            }
        }
    }

    @ViewBuilder
    private var scannerBanner: some View {
        NFCARDPanel {
            HStack(alignment: .top, spacing: 10) {
                if vm.isScanningCards {
                    ProgressView()
                        .tint(NFCARDTheme.accent)
                } else {
                    Image(systemName: "wave.3.left")
                        .foregroundStyle(NFCARDTheme.secondary)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(vm.isScanningCards ? "Live Scanner Active" : "Scanner Status")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(vm.isScanningCards ? NFCARDTheme.accent : NFCARDTheme.text)
                    Text(vm.scanStatusText)
                        .font(.caption)
                        .foregroundStyle(NFCARDTheme.secondary)
                        .lineLimit(3)
                }

                Spacer()

                if vm.isScanningCards {
                    Button("Stop") {
                        vm.stopCardScanning()
                    }
                    .font(.caption.weight(.bold))
                    .foregroundStyle(NFCARDTheme.danger)
                }
            }
        }
    }

    @ViewBuilder
    private var flashStatus: some View {
        switch vm.cardFlashPhase {
        case .idle:
            EmptyView()

        case .running:
            NFCARDPanel {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Flashing selected cards")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(NFCARDTheme.text)
                        Spacer()
                        Text("\(Int(vm.cardFlashProgress * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(NFCARDTheme.secondary)
                    }

                    ProgressView(value: vm.cardFlashProgress)
                        .tint(NFCARDTheme.accent)
                }
            }

        case .done(let ok):
            NFCARDPanel {
                Label(ok ? "Wallet artwork updated" : "Flash failed",
                      systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(ok ? NFCARDTheme.accent : NFCARDTheme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 18)

            ZStack {
                ForEach(0..<4, id: \.self) { idx in
                    Circle()
                        .stroke(NFCARDTheme.accent.opacity(0.09 + Double(idx) * 0.045), lineWidth: 1)
                        .frame(width: CGFloat(95 + idx * 28), height: CGFloat(95 + idx * 28))
                }

                Image(systemName: "creditcard.fill")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(NFCARDTheme.accent)
            }
            .frame(height: 175)

            VStack(spacing: 5) {
                Text(vm.isScanningCards ? "Scanning for Cards…" : "No Cards Detected Yet")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(NFCARDTheme.text)
                Text(vm.isScanningCards
                     ? "Open Apple Pay with the Side button and tap your card."
                     : "Tap Scan Cards, then open Apple Pay and select a card.")
                    .font(.subheadline)
                    .foregroundStyle(NFCARDTheme.secondary)
                    .multilineTextAlignment(.center)
            }

            NFCARDPanel {
                VStack(alignment: .leading, spacing: 12) {
                    instructionRow(number: "1", text: "Tap Scan Cards above.")
                    instructionRow(number: "2", text: "Double-click the Side button, authenticate with Face ID, then tap your Wallet card.")
                    instructionRow(number: "3", text: "The detected card appears here automatically.")
                }
            }

            HStack(spacing: 10) {
                Button {
                    vm.toggleCardScanning()
                } label: {
                    Label(vm.isScanningCards ? "Stop Scan" : "Scan",
                          systemImage: vm.isScanningCards ? "stop.fill" : "antenna.radiowaves.left.and.right")
                        .font(.headline)
                        .foregroundStyle(vm.isScanningCards ? .white : .black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(vm.isScanningCards ? NFCARDTheme.danger : NFCARDTheme.accent,
                                    in: RoundedRectangle(cornerRadius: 15))
                }
                .buttonStyle(.plain)

                Button {
                    showAddSheet = true
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(.headline)
                        .foregroundStyle(NFCARDTheme.text)
                        .frame(width: 112, height: 48)
                        .background(NFCARDTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 15))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func instructionRow(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.caption.weight(.bold))
                .foregroundStyle(NFCARDTheme.accent)
                .frame(width: 25, height: 25)
                .background(NFCARDTheme.accentSoft, in: Circle())

            Text(text)
                .font(.subheadline)
                .foregroundStyle(NFCARDTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var flashLog: some View {
        NFCARDPanel {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Flash Activity")
                        .font(.headline)
                        .foregroundStyle(NFCARDTheme.text)
                    Spacer()
                    Button("Clear") { vm.cardFlashLog.removeAll() }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(NFCARDTheme.accent)
                }

                ForEach(Array(vm.cardFlashLog.suffix(5).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(NFCARDTheme.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    private func apply(image: UIImage, picker: ActiveCardPicker) {
        switch picker {
        case .singleCard(let id):
            vm.setCardImage(for: id, image: image)
        case .bulkAll:
            vm.setSkinForAllCards(image: image)
        }
    }
}

private struct NFCARDDetectedCardView: View {
    let card: CardItem
    let cardIndex: Int
    let onToggleSelected: (Bool) -> Void
    let onPickImage: () -> Void
    let onClearImage: () -> Void
    let onDelete: () -> Void

    @State private var copied = false

    var body: some View {
        NFCARDPanel {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "creditcard.fill")
                        .font(.title3)
                        .foregroundStyle(NFCARDTheme.accent)
                        .frame(width: 34, height: 34)
                        .background(NFCARDTheme.accentSoft, in: RoundedRectangle(cornerRadius: 9))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Card Detected")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(NFCARDTheme.text)

                        Text(shortID)
                            .font(.caption.monospaced())
                            .foregroundStyle(NFCARDTheme.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Button {
                        UIPasteboard.general.string = card.id
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            copied = false
                        }
                    } label: {
                        Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                            .foregroundStyle(copied ? NFCARDTheme.accent : NFCARDTheme.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Divider().overlay(NFCARDTheme.border)

                HStack {
                    Text("Status")
                        .font(.caption)
                        .foregroundStyle(NFCARDTheme.secondary)
                    Spacer()
                    HStack(spacing: 6) {
                        Circle().fill(NFCARDTheme.accent).frame(width: 8, height: 8)
                        Text("Card detected")
                            .font(.caption)
                            .foregroundStyle(NFCARDTheme.text)
                    }
                }

                imageArea

                HStack(spacing: 8) {
                    Toggle("", isOn: Binding(
                        get: { card.isSelected },
                        set: { onToggleSelected($0) }
                    ))
                    .labelsHidden()
                    .tint(NFCARDTheme.accent)

                    Text("Card #\(cardIndex + 1)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(NFCARDTheme.text)

                    Text(shortID)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(NFCARDTheme.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(NFCARDTheme.surfaceRaised, in: Capsule())
                        .lineLimit(1)

                    Spacer()

                    if card.uiImage != nil {
                        Button(action: onClearImage) {
                            Image(systemName: "xmark.circle")
                                .foregroundStyle(NFCARDTheme.secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                            .foregroundStyle(NFCARDTheme.danger)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 17)
                .stroke(card.isSelected ? NFCARDTheme.accent.opacity(0.55) : Color.clear, lineWidth: 1.4)
        )
    }

    @ViewBuilder
    private var imageArea: some View {
        if let image = card.uiImage {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .aspectRatio(1.586, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .contentShape(Rectangle())
                .onTapGesture { onPickImage() }
        } else {
            Button(action: onPickImage) {
                VStack(spacing: 8) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(NFCARDTheme.accent)
                    Text("Assign Card Skin")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(NFCARDTheme.text)
                    Text("Tap to choose a photo")
                        .font(.caption)
                        .foregroundStyle(NFCARDTheme.secondary)
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(1.586, contentMode: .fit)
                .background(NFCARDTheme.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(NFCARDTheme.border, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var shortID: String {
        guard card.id.count > 18 else { return card.id }
        return "\(card.id.prefix(9))…\(card.id.suffix(7))"
    }
}
