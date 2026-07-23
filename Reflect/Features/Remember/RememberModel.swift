// State for the Remember overlay (§3.6): debounced FTS5 search grouped by
// month, suggestion chips from recent places, and the lead line. In Phase 1
// the lead becomes a Reflection-stage sentence and groups become facets
// (People/Places/…) from extraction; the view is built for that shape.
import Foundation
import Observation
import ReflectCore

@Observable
@MainActor
final class RememberModel {
    struct Group: Identifiable {
        let label: String  // "July 2026" (facets in Phase 1)
        let items: [EntriesRepository.SearchHit]
        var id: String { label }
    }

    private let repo: EntriesRepository

    var query = "" {
        didSet { if query != oldValue { scheduleSearch() } }
    }
    private(set) var groups: [Group] = []
    private(set) var lead = ""
    private(set) var hints: [String] = []
    var opened: Entry?
    private(set) var openedMood: Theme.Mood?

    private var searchTask: Task<Void, Never>?

    init(repo: EntriesRepository = AppServices.entries) {
        self.repo = repo
    }

    var isEmptyState: Bool {
        query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func loadHints() {
        var chips = (try? repo.recentPlaces()) ?? []
        for fallback in ["this week", "morning", "a good day"]
        where chips.count < 5 {
            chips.append(fallback)
        }
        hints = chips
    }

    func open(_ entry: Entry) {
        openedMood = (try? repo.moodLabels(entryIds: [entry.id]))?[entry.id]
            .flatMap(Theme.Mood.init(rawValue:))
        opened = entry
    }

    // MARK: - Search

    private func scheduleSearch() {
        searchTask?.cancel()
        guard !isEmptyState else {
            groups = []
            lead = ""
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.runSearch()
        }
    }

    /// Re-run the current query (after a trash action, for instance).
    func refresh() {
        guard !isEmptyState else { return }
        runSearch()
    }

    private func runSearch() {
        let hits = (try? repo.searchKeyword(query)) ?? []
        var order: [String] = []
        var byMonth: [String: [EntriesRepository.SearchHit]] = [:]
        for hit in hits {
            let label = Self.monthLabel(hit.entry.entryDate)
            if byMonth[label] == nil { order.append(label) }
            byMonth[label, default: []].append(hit)
        }
        groups = order.map { Group(label: $0, items: byMonth[$0] ?? []) }
        // Static leads until the Reflection-stage sentence arrives (Phase 1).
        lead = hits.isEmpty
            ? "Nothing surfaces yet. Try a place, a person, a feeling."
            : "Some of this is coming back to you…"
    }

    private static func monthLabel(_ entryDate: String) -> String {
        let parts = entryDate.split(separator: "-").compactMap { Int($0) }
        guard parts.count >= 2,
              let date = Calendar.current.date(
                  from: DateComponents(year: parts[0], month: parts[1], day: 1))
        else { return entryDate }
        return date.formatted(.dateTime.month(.wide).year())
    }
}
