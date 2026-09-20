#!/usr/bin/env python3
from pathlib import Path

p = Path("ThirdParty/AirCard/ios-app/AirCardContentView.swift")
s = p.read_text()

# AirCard v1.3 removed the pairing-file picker UI even though AppViewModel still
# ships the import/select/scanner implementation. Restore that upstream feature
# only for the embedded build; do not fork the rest of AirCard's UI.
needle = """    @State private var showDeleteConfirm = false
    @State private var showCredits = false
"""
replacement = """    @State private var showDeleteConfirm = false
    @State private var showFilePicker = false
    @State private var showCredits = false
"""
assert needle in s
s = s.replace(needle, replacement, 1)

needle = """                // On-Device Pairing Section (available for all iOS versions)
                Section("Pair on This iPhone") {
"""
replacement = """                // Pairing-file import remains supported by AirCard's v1.3
                // AppViewModel but its UI was removed upstream. Keep it exposed
                // in Filza so existing SideStore/Jitterbug/Mac/PC pairing files
                // can still be selected.
                Section("Pairing File") {
                    Button {
                        showFilePicker = true
                    } label: {
                        Label("Choose Pairing File from Files…", systemImage: "folder.badge.plus")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)

                    if !vm.documentsPlistFiles.isEmpty {
                        ForEach(vm.documentsPlistFiles, id: \.self) { file in
                            HStack {
                                Image(systemName: file == vm.pairingFileName ? "checkmark.circle.fill" : "doc.text")
                                    .foregroundStyle(file == vm.pairingFileName ? .green : .blue)
                                Text(file)
                                    .font(.system(size: 13, design: .monospaced))
                                    .lineLimit(1)
                                Spacer()
                                if file != vm.pairingFileName {
                                    Button("Select") {
                                        vm.selectPairingFile(filename: file)
                                    }
                                    .font(.caption.bold())
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                }

                // On-Device Pairing Section (available for all iOS versions)
                Section("Pair on This iPhone") {
"""
assert needle in s
s = s.replace(needle, replacement, 1)

needle = """            .sheet(isPresented: $showCredits) {
                CreditsSheet()
            }
            .onAppear {
"""
replacement = """            .sheet(isPresented: $showCredits) {
                CreditsSheet()
            }
            .sheet(isPresented: $showFilePicker) {
                DocumentPickerView(allowedContentTypes: [
                    UTType(filenameExtension: "plist") ?? .propertyList,
                    UTType(filenameExtension: "mobiledevicepairing") ?? .data,
                    UTType(filenameExtension: "mobilepair") ?? .data,
                    UTType.propertyList,
                    UTType.xmlPropertyList
                ]) { pickedURL in
                    let success = vm.importPairingFile(
                        from: pickedURL,
                        originalName: pickedURL.lastPathComponent
                    )
                    if !success {
                        vm.errorMessage = "Failed to read or save pairing file"
                    }
                }
            }
            .onAppear {
"""
assert needle in s
s = s.replace(needle, replacement, 1)
# Individual-key image picking is nested inside AirCard's Form. In the standalone
# app that presentation usually survives, but inside Filza's page-sheet host the
# confirmationDialog -> PhotosPicker/UIDocumentPicker transition can dismiss the
# embedded host or trip UIKit presentation assertions. Poster Slice does not use
# this same nested presentation path. Present the individual-key pickers from a
# stable background anchor instead of the Section itself.
old = """        .photosPicker(
            isPresented: $isKeyPhotosPickerPresented,
            selection: $selectedKey,
            maxSelectionCount: 1,
            matching: .images
        )
        .onChange(of: selectedKey) { _, items in
            guard let item = items.first,
                  let digit = selectedDigitForPicker else {
                if items.isEmpty { selectedDigitForPicker = nil }
                return
            }
            let currentDigit = digit
            Task {
                if let image = await item.loadUIImage(maxDimension: 1024) {
                    await MainActor.run { vm.setIndividualKey(digit: currentDigit, image: image) }
                }
                await MainActor.run {
                    selectedKey = []
                    selectedDigitForPicker = nil
                }
            }
        }
        .sheet(isPresented: $isKeyDocumentPickerPresented) {
            DocumentPickerView(allowedContentTypes: [
                .image, .png, .jpeg, .heic,
                UTType(filenameExtension: "webp") ?? .image,
                UTType(filenameExtension: "tiff") ?? .image
            ]) { url in
                guard let digit = selectedDigitForPicker else { return }
                if let data = try? Data(contentsOf: url),
                   let image = ImageEngine.safeImageFromData(data, maxDimension: 1024) {
                    vm.setIndividualKey(digit: digit, image: image)
                }
                selectedDigitForPicker = nil
            }
        }
"""
new = """        .background {
            Color.clear
                .photosPicker(
                    isPresented: $isKeyPhotosPickerPresented,
                    selection: $selectedKey,
                    maxSelectionCount: 1,
                    matching: .images
                )
                .sheet(isPresented: $isKeyDocumentPickerPresented) {
                    DocumentPickerView(allowedContentTypes: [
                        .image, .png, .jpeg, .heic,
                        UTType(filenameExtension: "webp") ?? .image,
                        UTType(filenameExtension: "tiff") ?? .image
                    ]) { url in
                        guard let digit = selectedDigitForPicker else { return }
                        if let data = try? Data(contentsOf: url),
                           let image = ImageEngine.safeImageFromData(data, maxDimension: 1024) {
                            vm.setIndividualKey(digit: digit, image: image)
                        }
                        selectedDigitForPicker = nil
                    }
                }
        }
        .onChange(of: selectedKey) { _, items in
            guard let item = items.first,
                  let digit = selectedDigitForPicker else {
                if items.isEmpty { selectedDigitForPicker = nil }
                return
            }
            let currentDigit = digit
            Task { @MainActor in
                if let image = await item.loadUIImage(maxDimension: 1024) {
                    vm.setIndividualKey(digit: currentDigit, image: image)
                }
                selectedKey = []
                selectedDigitForPicker = nil
            }
        }
"""
assert old in s, "AirCard individual-key picker surface changed upstream"
s = s.replace(old, new, 1)

p.write_text(s)
