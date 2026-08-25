#!/usr/bin/env bash
set -euo pipefail

CONTENT="ThirdParty/3105/Sources/ThreeOneOSFiveContentView.swift"
test -f "$CONTENT" || { echo "Missing staged 3105 content view: $CONTENT" >&2; exit 1; }

python3 - "$CONTENT" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

# SwiftUI's standard compact TabView is backed by UITabBarController. Once
# 3105 has more than five visible sections, UIKit replaces the extra items with
# a system "More" controller. That makes the Developer Mode and Cleaner
# toggles appear to do nothing even though FeatureVisibility changed.
#
# Keep TabView as the state-preserving content container, but use page style so
# it is no longer backed by UITabBarController. Render the visible sections in
# our own compact bottom strip, which has no five-item ceiling. Regular-width
# iPad/navigation-split behavior is unchanged.
old = '''    private var compactLayout: some View {
        TabView(selection: tabSelection) {
            ForEach(featureVisibility.visibleSections) { section in
                sectionContent(section)
                    .tabItem {
                        CompactTabLabel(
                            title: language.text(section.titleKey),
                            systemImage: section.systemImage
                        )
                    }
                    .tag(section.rawValue)
            }
        }
    }
'''
new = '''    private var compactLayout: some View {
        VStack(spacing: 0) {
            TabView(selection: tabSelection) {
                ForEach(featureVisibility.visibleSections) { section in
                    sectionContent(section)
                        .tag(section.rawValue)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            Divider()

            HStack(spacing: 0) {
                ForEach(featureVisibility.visibleSections) { section in
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            tabNavigation.select(section.rawValue)
                        }
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: section.systemImage)
                                .font(.system(size: 17, weight: .medium))
                            Text(language.text(section.titleKey))
                                .font(.caption2)
                                .lineLimit(1)
                                .minimumScaleFactor(0.62)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(
                        section.rawValue == tabNavigation.selectedTab
                            ? AppTheme.accent
                            : AppTheme.accent.opacity(0.48)
                    )
                    .accessibilityAddTraits(
                        section.rawValue == tabNavigation.selectedTab ? .isSelected : []
                    )
                }
            }
            .background(Color(uiColor: .systemBackground))
        }
    }
'''

if old not in text:
    raise SystemExit("3105 compact tabbar: native compact TabView anchor changed")

text = text.replace(old, new, 1)
path.write_text(text, encoding="utf-8")
PY

grep -Fq '.tabViewStyle(.page(indexDisplayMode: .never))' "$CONTENT"
grep -Fq 'ForEach(featureVisibility.visibleSections)' "$CONTENT"
grep -Fq 'minimumScaleFactor(0.62)' "$CONTENT"
! grep -Fq '.tabItem {' "$CONTENT"

echo "Replaced compact 3105 UITabBar five-item ceiling with dynamic bottom tab strip"
