import SwiftUI

private enum OnboardingStep: Int, CaseIterable {
    case language = 0, welcome, versions, install

    var next: OnboardingStep? { Self(rawValue: rawValue + 1) }
    var prev: OnboardingStep? { Self(rawValue: rawValue - 1) }
}

private enum OnboardingNavigationDirection {
    case forward
    case backward
}

struct OnboardingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.english.rawValue
    @State private var step: OnboardingStep = .language
    @State private var navigationDirection: OnboardingNavigationDirection = .forward
    var onComplete: () -> Void

    private var language: AppLanguage { AppLanguage(rawValue: languageCode) ?? .english }
    private var motionAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.24)
    }

    var body: some View {
        ZStack {
            AppTheme.pageBackground
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                pageContent
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            controls
        }
        .tint(AppTheme.accent)
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(OnboardingStep.allCases, id: \.rawValue) { s in
                    Capsule()
                        .fill(s.rawValue <= step.rawValue ? AppTheme.accent : Color.secondary.opacity(0.22))
                        .frame(height: 4)
                        .frame(maxWidth: s == step ? 28 : 18)
                        .animation(motionAnimation, value: step)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 20)

            Text(language.text("onboarding.step", "\(step.rawValue + 1)", "\(OnboardingStep.allCases.count)"))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        }
        .padding(.top, 16)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(AppTheme.pageBackground)
    }

    @ViewBuilder
    private var pageContent: some View {
        ZStack {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { s in
                if s == step {
                    ScrollView(.vertical, showsIndicators: false) {
                        page(for: s)
                            .frame(maxWidth: 560)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 20)
                            .padding(.top, 12)
                            .padding(.bottom, 28)
                    }
                    .transition(pageTransition)
                    .id(s.rawValue)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var pageTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let insertionEdge: Edge = navigationDirection == .forward ? .trailing : .leading
        let removalEdge: Edge = navigationDirection == .forward ? .leading : .trailing
        return .asymmetric(
            insertion: .move(edge: insertionEdge).combined(with: .opacity),
            removal: .move(edge: removalEdge).combined(with: .opacity)
        )
    }

    @ViewBuilder
    private func page(for s: OnboardingStep) -> some View {
        switch s {
        case .language: languagePage
        case .welcome: welcomePage
        case .versions: versionsPage
        case .install: installPage
        }
    }

    private var languagePage: some View {
        VStack(spacing: 24) {
            AppLogo(size: 72)

            VStack(spacing: 8) {
                Text(language.text("onboarding.language_title"))
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(language.text("onboarding.language_subtitle"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 12) {
                ForEach(AppLanguage.allCases) { option in
                    let isSelected = languageCode == option.rawValue
                    Button {
                        languageCode = option.rawValue
                    } label: {
                        HStack(spacing: 12) {
                            Text(option.displayName)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            if isSelected {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(AppTheme.accent)
                                    .font(.title3)
                                    .transition(.scale.combined(with: .opacity))
                            } else {
                                Image(systemName: "circle")
                                    .foregroundStyle(.secondary.opacity(0.5))
                            }
                        }
                        .padding(.horizontal, 16)
                        .frame(minHeight: 56)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color(uiColor: .secondarySystemBackground))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(isSelected ? AppTheme.accent : Color.secondary.opacity(0.12), lineWidth: 1)
                                )
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .animation(motionAnimation, value: languageCode)
                }
            }

            Text(language.text("onboarding.language_hint", language.displayName))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var welcomePage: some View {
        VStack(spacing: 20) {
            featureIcon(systemName: "sparkles", color: AppTheme.accent)

            VStack(spacing: 10) {
                Text(language.text("onboarding.welcome_title"))
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(language.text("onboarding.welcome_message"))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Label(language.text("onboarding.welcome_badge"), systemImage: "checkmark.seal.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AppTheme.accent)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var versionsPage: some View {
        VStack(spacing: 20) {
            featureIcon(systemName: "iphone.gen2", color: AppTheme.accent)

            VStack(spacing: 8) {
                Text(language.text("onboarding.versions_title"))
                    .font(.title3.weight(.bold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(language.text("onboarding.versions_subtitle"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 10) {
                versionRow(icon: "checkmark.circle.fill", title: "iOS 17", value: ExploitSupportPolicy.verifiedIOS17Range, color: .green)
                versionRow(icon: "checkmark.circle.fill", title: "iOS 18", value: ExploitSupportPolicy.verifiedIOS18Range, color: .green)
                versionRow(icon: "checkmark.circle.fill", title: "iOS 26", value: ExploitSupportPolicy.verifiedIOS26Range, color: .green)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("iOS 27.0").font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(language.text("onboarding.beta")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    ForEach(ExploitSupportPolicy.verifiedIOS27Builds, id: \.build) { v in
                        let betaLabel = language.text("onboarding.developer_beta", "\(v.beta)")
                            + (v.publicBeta.map {
                                " · " + language.text("onboarding.public_beta", "\($0)")
                            } ?? "")
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 12) {
                                Text(betaLabel)
                                Spacer()
                                Text(v.build)
                                    .font(.caption.monospaced().weight(.medium))
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(betaLabel)
                                Text(v.build)
                                    .font(.caption.monospaced().weight(.medium))
                            }
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 24)
                    }
                }
                .padding(12)
                .background(
                    Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
            }

            Text(language.text("onboarding.versions_footer", AppInfo.osVersion, AppInfo.osBuild))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var installPage: some View {
        VStack(spacing: 20) {
            featureIcon(systemName: "exclamationmark.shield.fill", color: .orange)

            VStack(spacing: 8) {
                Text(language.text("onboarding.install_title"))
                    .font(.title3.weight(.bold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(language.text("onboarding.install_message"))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 10) {
                installBullet(icon: "checkmark.seal.fill", text: language.text("onboarding.install_ok"), color: .green)
                installBullet(icon: "xmark.octagon.fill", text: language.text("onboarding.install_bad"), color: .red)
                installBullet(icon: "exclamationmark.triangle.fill", text: language.text("onboarding.install_jailbreak"), color: .orange)
            }
            .padding(14)
            .background(
                Color(uiColor: .secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )

            Text(language.text("onboarding.install_footer"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func featureIcon(systemName: String, color: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(color.opacity(0.3), lineWidth: 1)
                )
            Image(systemName: systemName)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(color)
        }
        .frame(width: 72, height: 72)
        .accessibilityHidden(true)
    }

    private func versionRow(icon: String, title: String, value: String, color: Color) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(color)
                Text(title).fontWeight(.semibold)
                Spacer()
                Text(value)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .foregroundStyle(color)
                    Text(title)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                }
                Text(value)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.leading, 26)
            }
        }
        .font(.subheadline)
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func installBullet(icon: String, text: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.body.weight(.semibold))
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    controlButtons
                }
                VStack(spacing: 10) {
                    controlButtons
                }
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 20)
        }
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    @ViewBuilder
    private var controlButtons: some View {
        if step != .language {
            Button {
                guard let previousStep = step.prev else { return }
                navigate(to: previousStep, direction: .backward)
            } label: {
                Label(language.text("common.back"), systemImage: "chevron.left")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }

        Button {
            if let nextStep = step.next {
                navigate(to: nextStep, direction: .forward)
            } else {
                onComplete()
            }
        } label: {
            HStack(spacing: 6) {
                Text(language.text(step == .install ? "common.finish" : "common.next"))
                if step != .install {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    private func navigate(to destination: OnboardingStep, direction: OnboardingNavigationDirection) {
        withAnimation(motionAnimation) {
            navigationDirection = direction
            step = destination
        }
    }
}

enum OnboardingStore {
    static let completedVersionKey = "onboarding.completedVersion"
    static let completedFingerprintKey = "onboarding.completedFingerprint"

    static var currentVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(v) (\(b))"
    }

    /// Per-install token: executable mtime changes on every overwrite even if version stays the same.
    static var bundleToken: String {
        if let exe = Bundle.main.executablePath,
           let attrs = try? FileManager.default.attributesOfItem(atPath: exe),
           let date = attrs[.modificationDate] as? Date {
            return String(Int(date.timeIntervalSince1970))
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: Bundle.main.bundlePath),
           let date = (attrs[.creationDate] as? Date) ?? (attrs[.modificationDate] as? Date) {
            return String(Int(date.timeIntervalSince1970))
        }
        return "0"
    }

    static var currentFingerprint: String { "\(currentVersion)#\(bundleToken)" }

    static var completedVersion: String? {
        UserDefaults.standard.string(forKey: completedVersionKey)
    }

    static var completedFingerprint: String? {
        UserDefaults.standard.string(forKey: completedFingerprintKey)
    }

    static func shouldShow() -> Bool {
#if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--skip-onboarding") { return false }
        if ProcessInfo.processInfo.arguments.contains("--reset-onboarding") { return true }
#endif
        let fp = currentFingerprint
        if let stored = completedFingerprint, !stored.isEmpty {
            return stored != fp
        }
        // Migration: old installs only have completedVersion
        if let completed = completedVersion, !completed.isEmpty {
            if completed == currentVersion {
                // Same version, migrate silently — next overwrite will be detected via fingerprint
                UserDefaults.standard.set(fp, forKey: completedFingerprintKey)
                return false
            }
            return true
        }
        return true
    }

    static func markCompleted() {
        UserDefaults.standard.set(currentVersion, forKey: completedVersionKey)
        UserDefaults.standard.set(currentFingerprint, forKey: completedFingerprintKey)
    }
}
