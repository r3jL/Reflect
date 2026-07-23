// Trash (FR-010 / AC-008): soft-deleted entries wait here; restore brings
// them back, Empty Trash hard-deletes rows and removes media files.
import ReflectCore
import SwiftUI

@Observable
@MainActor
final class TrashModel {
    private let repo = AppServices.entries
    private(set) var entries: [Entry] = []

    func load() {
        entries = (try? repo.trash()) ?? []
    }

    func restore(_ entry: Entry) {
        try? repo.restore(id: entry.id)
        load()
    }

    func emptyTrash() {
        if let paths = try? repo.emptyTrash() {
            AppServices.mediaStore.remove(relativePaths: paths)
        }
        load()
    }
}

struct TrashView: View {
    var onClose: () -> Void

    @State private var model = TrashModel()
    @State private var confirmingEmpty = false

    var body: some View {
        ZStack {
            Theme.paper3.opacity(0.72)
                .background(.ultraThinMaterial)
                .ignoresSafeArea()
                .onTapGesture { onClose() }

            VStack(alignment: .leading, spacing: 0) {
                header
                if model.entries.isEmpty {
                    Text("Nothing here. The page stays turned.")
                        .font(Typography.serifItalic(17))
                        .foregroundStyle(Theme.ink3)
                        .padding(.top, 40)
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 22) {
                            ForEach(model.entries) { entry in
                                row(entry)
                            }
                        }
                        .padding(.top, 30)
                    }
                    footer
                }
            }
            .padding(36)
            .frame(maxWidth: 560, maxHeight: 520)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Theme.paper)
                    .shadow(color: Theme.ink.opacity(0.3), radius: 34, y: 18)
            )
            .padding(60)
        }
        .transition(.opacity)
        .onAppear { model.load() }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 10) {
                Kicker(text: "Trash")
                Text("Turned pages")
                    .font(Typography.serif(30, weight: .light))
                    .foregroundStyle(Theme.ink)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.ink3)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Theme.paper))
                    .overlay(Circle().stroke(Theme.hair, lineWidth: 1))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
    }

    private func row(_ entry: Entry) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.entryDate)
                    .font(Typography.sans(11))
                    .foregroundStyle(Theme.ink4)
                Text(entry.body.isEmpty ? "(empty entry)" : String(entry.body.prefix(110)))
                    .font(Typography.serif(15))
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(2)
            }
            Spacer()
            Button("Restore") { model.restore(entry) }
                .buttonStyle(.plain)
                .font(Typography.sans(11, weight: .medium))
                .foregroundStyle(Theme.accent)
        }
        .padding(.bottom, 16)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hair).frame(height: 1)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(action: { confirmingEmpty = true }) {
                Text("Empty Trash")
                    .font(Typography.sans(12))
                    .foregroundStyle(Theme.ink3)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.cornerRadius)
                            .stroke(Theme.hair2, lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .confirmationDialog(
                "Permanently delete these entries and their photos?",
                isPresented: $confirmingEmpty
            ) {
                Button("Delete Forever", role: .destructive) {
                    model.emptyTrash()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        .padding(.top, 22)
    }
}
