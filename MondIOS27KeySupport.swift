import Foundation
import SwiftUI
import UIKit
import CoreFoundation

// Filza integration extension for the iOS 27 MobileGestalt keys supplied for
// this project. These types deliberately do not replace upstream GestaltView;
// the build-time patch only adds one section to the current upstream view.
enum MondIOS27GestaltScalarKind: String, CaseIterable, Identifiable {
    case boolean = "Boolean"
    case integer = "Integer"
    case decimal = "Decimal"
    case string = "String"

    var id: String { rawValue }
}

struct MondIOS27GestaltKeyDefinition: Identifiable {
    let key: String
    let name: String
    let preferredKind: MondIOS27GestaltScalarKind

    var id: String { key }
}

let mondIOS27GestaltKeys: [MondIOS27GestaltKeyDefinition] = [
    .init(key: "7brdL5xrEUWnlF9C0kdg5A", name: "DeviceSupportsHighLuminanceAlwaysOnDisplay", preferredKind: .boolean),
    .init(key: "A/74xUbqJwBsaWTjSDd0fQ", name: "ChassisSlotFunctionNumber", preferredKind: .integer),
    .init(key: "a3n5T9sFtlyQ74NEp9ESxg", name: "SiriMode", preferredKind: .integer),
    .init(key: "HBG+hj/Oz89PjVgn93Jd8A", name: "Image4SecureBootKeyScheme", preferredKind: .string),
    .init(key: "ikn/KMyeztXJhAj/dqBjBg", name: "LowPowerRendererCapability", preferredKind: .integer),
    .init(key: "J2+oJRiGdbAzTi6U5nhqdQ", name: "PostQuantumCryptographyEnforced", preferredKind: .boolean),
    .init(key: "Kpfa0nb8nn8EVzI/UgcMfQ", name: "CoalescedSubTargetID", preferredKind: .integer),
    .init(key: "lyJZrSDc8J8eQ5b7A1Rvw", name: "DeviceSupportsTouchSensitiveCameraControl", preferredKind: .boolean),
    .init(key: "m4xs4mhvxnAopYrApoLDMw", name: "DeviceSupportsInstructionFollowingPruningModels", preferredKind: .boolean),
    .init(key: "mnPU37/y4i0TJFnJc+r4lA", name: "DeviceSupportsLowPowerWake", preferredKind: .boolean),
    .init(key: "odI0U9Etrx7hObzvJ9xJ8Q", name: "DeviceSupportsSandcat", preferredKind: .boolean),
    .init(key: "P4ZJVy/zYuLy4ejRKP+0DA", name: "DeviceSupportsRegionalCameraShutterRelaxation", preferredKind: .boolean),
    .init(key: "qqrspu7CpuPdZwSDxNY+Fg", name: "MaximumFlipbookCount", preferredKind: .integer),
    .init(key: "s1ZXqZtUSpr+BjUgZXZ/2g", name: "ChassisSlotInstanceNumber", preferredKind: .integer),
    .init(key: "TusANsf9Lfe3P/9fIXXSrQ", name: "DeviceSupportsAlwaysListeningHeySiri", preferredKind: .boolean),
    .init(key: "VXc3L66nqQ6bn4z60ChX+A", name: "ResponsiveAirPlayAudioCapability", preferredKind: .integer),
    .init(key: "ym8C/Ut5YcBnqAdm4NEDLQ", name: "Image4SecureBootCertificateFormat", preferredKind: .string),
]

private func mondIOS27ScalarKind(
    for value: Any?,
    fallback: MondIOS27GestaltScalarKind
) -> MondIOS27GestaltScalarKind {
    guard let value = value else { return fallback }
    if let number = value as? NSNumber {
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return .boolean }
        let type = String(cString: number.objCType)
        return ["f", "d"].contains(type) ? .decimal : .integer
    }
    if value is NSString || value is String { return .string }
    return fallback
}

func mondIOS27ScalarText(_ value: Any?) -> String {
    guard let value = value else { return "" }
    if let number = value as? NSNumber {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue ? "true" : "false"
        }
        return number.stringValue
    }
    if let string = value as? String { return string }
    if let string = value as? NSString { return String(string) }
    return String(describing: value)
}

struct MondIOS27GestaltKeyToggle: View {
    let definition: MondIOS27GestaltKeyDefinition
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(definition.name, isOn: $isOn)
            Text(definition.key)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

private struct MondIOS27RawGestaltKeyEditor: View {
    let definition: MondIOS27GestaltKeyDefinition
    let onSave: (Any?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var kind: MondIOS27GestaltScalarKind
    @State private var text: String
    @State private var booleanValue: Bool
    @State private var errorMessage: String?

    init(
        definition: MondIOS27GestaltKeyDefinition,
        value: Any?,
        onSave: @escaping (Any?) -> Void
    ) {
        self.definition = definition
        self.onSave = onSave
        let detectedKind = mondIOS27ScalarKind(for: value, fallback: definition.preferredKind)
        _kind = State(initialValue: detectedKind)
        _text = State(initialValue: mondIOS27ScalarText(value))
        _booleanValue = State(initialValue: (value as? NSNumber)?.boolValue ?? false)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(definition.name)
                    Text(definition.key)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                } header: {
                    Label("Gestalt Key", systemImage: "key")
                }

                Section {
                    Picker("Value Type", selection: $kind) {
                        ForEach(MondIOS27GestaltScalarKind.allCases) { kind in
                            Text(kind.rawValue).tag(kind)
                        }
                    }

                    if kind == .boolean {
                        Toggle("Value", isOn: $booleanValue)
                    } else {
                        TextField("Value", text: $text)
                            .keyboardType(kind == .string ? .default : .numbersAndPunctuation)
                    }
                } header: {
                    Label("Value", systemImage: "slider.horizontal.3")
                } footer: {
                    Text("The existing MobileGestalt scalar type is detected automatically. A missing key starts with its suggested type.")
                }

                Section {
                    Button("Remove Key", role: .destructive) {
                        onSave(nil)
                        dismiss()
                    }
                }
            }
            .navigationTitle("Edit iOS 27 Key")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                }
            }
            .alert("Invalid Value", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func save() {
        switch kind {
        case .boolean:
            onSave(NSNumber(value: booleanValue))
        case .integer:
            guard let value = Int64(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                errorMessage = "Enter a valid signed integer."
                return
            }
            onSave(NSNumber(value: value))
        case .decimal:
            guard let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite else {
                errorMessage = "Enter a valid finite decimal value."
                return
            }
            onSave(NSNumber(value: value))
        case .string:
            onSave(text)
        }
        dismiss()
    }
}

struct MondIOS27RawGestaltKeyRow: View {
    let definition: MondIOS27GestaltKeyDefinition
    let onSave: (Any?) -> Void

    @State private var currentValue: Any?
    @State private var showingEditor = false

    init(
        definition: MondIOS27GestaltKeyDefinition,
        value: Any?,
        onSave: @escaping (Any?) -> Void
    ) {
        self.definition = definition
        self.onSave = onSave
        _currentValue = State(initialValue: value)
    }

    var body: some View {
        Button {
            showingEditor = true
        } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(definition.name)
                    Text(definition.key)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(currentValue == nil ? "Not set" : mondIOS27ScalarText(currentValue))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showingEditor) {
            MondIOS27RawGestaltKeyEditor(definition: definition, value: currentValue) { value in
                currentValue = value
                onSave(value)
            }
        }
    }
}
