// Insights (M15): real month stats, theme/entity browse (FR-027), and
// open action items (FR-028). The monthly essay itself is Phase 4; this
// view carries everything the pipeline already knows.
import Foundation
import Observation
import ReflectCore

@Observable
@MainActor
final class InsightsModel {
    struct FilteredList: Identifiable {
        let title: String
        let entries: [Entry]
        var id: String { title }
    }

    private let repo = AppServices.entries
    private let metadata = AppServices.metadata
    private let calendar = Calendar.current

    private(set) var monthName = ""
    private(set) var seasonKicker = ""
    private(set) var stats = EntriesRepository.MonthStats(
        entryCount: 0, wordCount: 0, photoCount: 0)
    private(set) var streakDays = 0
    private(set) var themes: [(name: String, count: Int)] = []
    private(set) var entities: [(entity: MetadataRepository.EntityRef, count: Int)] = []
    private(set) var actions: [MetadataRepository.OpenAction] = []

    var browsing: FilteredList?
    var opened: Entry?
    private(set) var openedMood: Theme.Mood?

    func load(now: Date = .now) {
        let components = calendar.dateComponents([.year, .month], from: now)
        let yearMonth = String(
            format: "%04d-%02d", components.year ?? 2026, components.month ?? 1)
        monthName = now.formatted(.dateTime.month(.wide))
        seasonKicker = Self.seasons[(components.month ?? 1) - 1]
            + " · " + String(components.year ?? 2026)

        stats = (try? repo.monthStats(yearMonth))
            ?? EntriesRepository.MonthStats(entryCount: 0, wordCount: 0, photoCount: 0)
        streakDays = computeStreak(now: now)
        themes = (try? metadata.topThemes()) ?? []
        entities = (try? metadata.topEntities()) ?? []
        actions = (try? metadata.openActionItems()) ?? []
    }

    // MARK: - Browse (FR-027 / AC-027)

    func browseTheme(_ name: String) {
        let entries = (try? metadata.entries(forTheme: name)) ?? []
        browsing = FilteredList(title: name, entries: entries)
    }

    func browseEntity(_ entity: MetadataRepository.EntityRef) {
        let entries = (try? metadata.entries(
            forEntity: entity.name, type: entity.type)) ?? []
        browsing = FilteredList(title: entity.name, entries: entries)
    }

    func open(_ entry: Entry) {
        openedMood = (try? repo.moodLabels(entryIds: [entry.id]))?[entry.id]
            .flatMap(Theme.Mood.init(rawValue:))
        opened = entry
    }

    // MARK: - Action items (FR-028)

    func markAction(_ action: MetadataRepository.OpenAction, done: Bool) {
        try? metadata.setActionStatus(id: action.id, status: done ? "done" : "dropped")
        actions = (try? metadata.openActionItems()) ?? []
    }

    // MARK: - Helpers

    private func computeStreak(now: Date) -> Int {
        guard let dates = try? repo.distinctEntryDates() else { return 0 }
        let have = Set(dates)
        var cursor = now
        if !have.contains(DBFormat.entryDate(cursor)) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor)
            else { return 0 }
            cursor = yesterday
        }
        var streak = 0
        while have.contains(DBFormat.entryDate(cursor)) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor)
            else { break }
            cursor = previous
        }
        return streak
    }

    private static let seasons = [
        "Deep winter", "Late winter", "Early spring", "Spring", "Late spring",
        "Early summer", "High summer", "Late summer", "Early autumn", "Autumn",
        "Late autumn", "Winter",
    ]
}
