// The read view an entry morphs open into (§3.6): serif date header, meta
// row, body paragraphs. Media gallery lands in M5; the memory-echo block
// arrives with Phase 1.
import ReflectCore
import SwiftUI

struct EntryReadView: View {
    let entry: Entry
    let mood: Theme.Mood?
    var onClose: () -> Void
    var onPrev: () -> Void
    var onNext: () -> Void

    @State private var contentVisible = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    Kicker(text: weekday)
                        .padding(.bottom, 14)
                    Text(dateLong)
                        .font(Typography.serif(52, weight: .regular))
                        .foregroundStyle(Theme.ink)
                    metaRow.padding(.top, 16).padding(.bottom, 44)

                    ForEach(paragraphs.indices, id: \.self) { index in
                        Text(paragraphs[index])
                            .font(Typography.serif(21))
                            .foregroundStyle(Theme.ink)
                            .lineSpacing(9)
                            .padding(.bottom, 26)
                    }
                }
                .frame(maxWidth: 660, alignment: .leading)
                .padding(.horizontal, 56)
                .padding(.top, 80)
                .padding(.bottom, 120)
                .frame(maxWidth: .infinity)
                // Design: content fades in after the morph settles.
                .opacity(contentVisible ? 1 : 0)
            }

            closeButton.padding(16)

            HStack {
                edgeNavButton("chevron.left", action: onPrev)
                Spacer()
                edgeNavButton("chevron.right", action: onNext)
            }
            .frame(maxHeight: .infinity)
            .padding(.horizontal, 10)
            .opacity(contentVisible ? 1 : 0)
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.paper)
                .shadow(color: Theme.ink.opacity(0.35), radius: 40, y: 24)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onAppear {
            withAnimation(.easeIn(duration: 0.4).delay(0.22)) {
                contentVisible = true
            }
        }
    }

    // MARK: - Pieces

    private var metaRow: some View {
        HStack(spacing: 14) {
            HStack(spacing: 7) {
                if let mood {
                    Circle().fill(mood.dot).frame(width: 8, height: 8)
                    Text(mood.rawValue)
                } else {
                    Circle().stroke(Theme.ink4, lineWidth: 1.5)
                        .frame(width: 8, height: 8)
                }
            }
            if let place = entry.place, !place.isEmpty {
                Circle().fill(Theme.ink4).frame(width: 3, height: 3)
                Text(place)
            }
            if entry.status == .draft {
                Circle().fill(Theme.ink4).frame(width: 3, height: 3)
                Text("draft").foregroundStyle(Theme.ink4)
            }
        }
        .font(Typography.sans(12.5))
        .foregroundStyle(Theme.ink3)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.ink3)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Theme.paper))
                .overlay(Circle().stroke(Theme.hair, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private func edgeNavButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.ink3)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Theme.paper.opacity(0.9)))
                .overlay(Circle().stroke(Theme.hair, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Derived

    private var entryDateAsDate: Date? {
        let parts = entry.entryDate.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(
            from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private var weekday: String {
        entryDateAsDate?.formatted(.dateTime.weekday(.wide)) ?? ""
    }

    private var dateLong: String {
        entryDateAsDate?.formatted(.dateTime.month(.wide).day()) ?? entry.entryDate
    }

    private var paragraphs: [String] {
        let body = entry.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return ["A quiet day. Not every page needs to be full."] }
        return body
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
