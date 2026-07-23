// State for the Life month map (§3.6): one item per calendar day with
// density (from word_count), mood wash (from Reflection, when it exists),
// glyph sources, and the selected entry for the morph-open read view.
import Foundation
import Observation
import ReflectCore

@Observable
@MainActor
final class LifeModel {
    struct DayItem: Identifiable {
        let day: Int
        let entry: Entry?
        let mood: Theme.Mood?
        let density: Int  // 0–3 bars
        let hasPhoto: Bool
        let isToday: Bool
        let isFuture: Bool

        var id: Int { day }
        var hasEntry: Bool { entry != nil }
    }

    private let repo: EntriesRepository
    private let calendar = Calendar.current

    var monthOffset = 0 {
        didSet { load() }
    }
    private(set) var days: [DayItem] = []
    private(set) var leadingBlanks = 0
    private(set) var monthName = ""
    private(set) var yearText = ""
    private(set) var seasonName = ""
    var selected: Entry?

    init(repo: EntriesRepository = AppServices.entries) {
        self.repo = repo
    }

    // MARK: - Month navigation

    func shift(_ delta: Int) {
        monthOffset += delta
    }

    /// Entries of the shown month in date order — prev/next in the read view.
    var monthEntries: [Entry] {
        days.compactMap(\.entry)
    }

    func selectNeighbor(_ delta: Int) {
        guard let selected,
              let index = monthEntries.firstIndex(where: { $0.id == selected.id }),
              monthEntries.indices.contains(index + delta)
        else { return }
        self.selected = monthEntries[index + delta]
    }

    // MARK: - Load

    func load(now: Date = .now) {
        guard let shown = calendar.date(byAdding: .month, value: monthOffset, to: now)
        else { return }
        let components = calendar.dateComponents([.year, .month], from: shown)
        guard let year = components.year, let month = components.month,
              let firstOfMonth = calendar.date(
                  from: DateComponents(year: year, month: month, day: 1)),
              let dayRange = calendar.range(of: .day, in: .month, for: firstOfMonth)
        else { return }

        monthName = firstOfMonth.formatted(.dateTime.month(.wide))
        yearText = String(year)
        seasonName = Self.seasons[month - 1]
        // Grid starts on Sunday, like the design.
        leadingBlanks = calendar.component(.weekday, from: firstOfMonth) - 1

        let yearMonth = String(format: "%04d-%02d", year, month)
        let entries = (try? repo.month(yearMonth)) ?? []
        let byDay = Dictionary(grouping: entries) { Int($0.entryDate.suffix(2)) ?? 0 }
        let ids = entries.map(\.id)
        let moods = (try? repo.moodLabels(entryIds: ids)) ?? [:]
        let withMedia = (try? repo.entryIdsWithMedia(ids)) ?? []
        let today = DBFormat.entryDate(now)

        days = dayRange.map { day in
            let entry = byDay[day]?.first
            let dateString = String(format: "%@-%02d", yearMonth, day)
            return DayItem(
                day: day,
                entry: entry,
                mood: entry.flatMap { moods[$0.id] }.flatMap(Theme.Mood.init(rawValue:)),
                density: Self.density(wordCount: entry?.wordCount ?? 0),
                hasPhoto: entry.map { withMedia.contains($0.id) } ?? false,
                isToday: dateString == today,
                isFuture: dateString > today)
        }
    }

    /// 1–3 bars by entry length; any words at all earn one bar.
    static func density(wordCount: Int) -> Int {
        switch wordCount {
        case ..<1: 0
        case ..<120: 1
        case ..<300: 2
        default: 3
        }
    }

    private static let seasons = [
        "Deep winter", "Late winter", "Early spring", "Spring", "Late spring",
        "Early summer", "High summer", "Late summer", "Early autumn", "Autumn",
        "Late autumn", "Winter",
    ]
}
