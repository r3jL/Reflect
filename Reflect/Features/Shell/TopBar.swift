// The whole app chrome (§3.6): wordmark · Today/Life/Insights · Remember.
// The system supplies traffic lights in the hidden titlebar; the leading
// padding keeps the wordmark clear of them.
import SwiftUI

struct TopBar: View {
    @Binding var section: AppSection

    var body: some View {
        HStack(spacing: 20) {
            Text("Reflect")
                .font(Typography.serif(16, weight: .medium))
                .foregroundStyle(Theme.ink)
                .padding(.leading, 78)

            HStack(spacing: 2) {
                ForEach(AppSection.allCases, id: \.self) { item in
                    navButton(item)
                }
            }
            .padding(.leading, 14)

            Spacer()

            RememberButton()
        }
        .padding(.horizontal, 18)
        .frame(height: Theme.topBarHeight)
        .background(Theme.paper)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hair).frame(height: 1)
        }
    }

    private func navButton(_ item: AppSection) -> some View {
        Button {
            section = item
        } label: {
            Text(item.rawValue)
                .font(Typography.sans(13, weight: section == item ? .medium : .regular))
                .foregroundStyle(section == item ? Theme.ink : Theme.ink3)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: Theme.cornerRadius)
                        .fill(section == item ? Theme.paper3 : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Placeholder until M6 — visual only, matching the mockup's search affordance.
private struct RememberButton: View {
    var body: some View {
        Button {
            // ⌘K overlay lands in M6.
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                Text("Remember")
                    .font(Typography.sans(12.5))
            }
            .foregroundStyle(Theme.ink3)
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.paper2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8).stroke(Theme.hair, lineWidth: 1)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("k", modifiers: .command)
    }
}
