// State for the writing room (M3): loads/creates the day's draft, autosaves
// on a 2s idle debounce + blur/quit flush (AC-002), completes with pipeline
// enqueue (AC-003/004), and computes the margin metadata (streak, on this
// day). Write latency is tracked against KPI-02 (<100ms).
import Foundation
import Observation
import ReflectCore

@Observable
@MainActor
final class TodayModel {
    private let repo: EntriesRepository
    private let calendar = Calendar.current

    private(set) var entry: Entry?
    var text: String = "" {
        didSet { if text != oldValue { scheduleAutosave() } }
    }
    var place: String = ""
    var weather: String = ""

    private(set) var streakDays = 0
    private(set) var onThisDay = 0
    private(set) var pendingJobs = false
    private(set) var lastWriteMs: Double?

    private var autosaveTask: Task<Void, Never>?
    private var persistedText = ""

    init(repo: EntriesRepository = AppServices.entries) {
        self.repo = repo
    }

    var wordCount: Int { Entry.wordCount(of: text) }
    var isCompleted: Bool { entry?.status == .completed }
    var canComplete: Bool { entry?.status == .draft && wordCount > 0 }

    // MARK: - Load

    func load(now: Date = .now) {
        do {
            let today = DBFormat.entryDate(now)
            let loaded = try repo.fetchOrCreateForDate(today, now: now)
            entry = loaded
            text = loaded.body
            persistedText = loaded.body
            place = loaded.place ?? ""
            weather = loaded.weather ?? ""
            refreshMarginMeta(now: now)
            refreshJobs()
        } catch {
            assertionFailure("Today load failed: \(error)")
        }
    }

    // MARK: - Autosave (AC-002)

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Persist immediately (idle timeout, editor blur, app quit).
    func flush() {
        autosaveTask?.cancel()
        guard let entry, text != persistedText else { return }
        do {
            let t0 = ContinuousClock.now
            try repo.updateBody(id: entry.id, title: entry.title, body: text)
            let ms = Double((ContinuousClock.now - t0).components.attoseconds) / 1e15
            lastWriteMs = ms
            persistedText = text
            refreshJobs()  // completed-entry edits re-enqueue (FR-004)
            #if DEBUG
            print("KPI-02 entry write: \(String(format: "%.1f", ms)) ms")
            #endif
        } catch {
            assertionFailure("autosave failed: \(error)")
        }
    }

    func saveContext() {
        guard let entry else { return }
        do {
            try repo.updateContext(
                id: entry.id,
                place: place.isEmpty ? nil : place,
                weather: weather.isEmpty ? nil : weather,
                isMilestone: entry.isMilestone)
        } catch {
            assertionFailure("context save failed: \(error)")
        }
    }

    // MARK: - Complete (AC-003, AC-004)

    func complete() {
        guard let current = entry, current.status == .draft else { return }
        flush()
        do {
            try repo.complete(id: current.id)
            entry = try repo.fetch(id: current.id)
            refreshJobs()
            refreshMarginMeta(now: .now)
        } catch {
            assertionFailure("complete failed: \(error)")
        }
    }

    private func refreshJobs() {
        guard let entry else { return }
        pendingJobs = (try? repo.jobs(entryId: entry.id))?
            .contains { $0.status == .pending } ?? false
    }

    // MARK: - Margin metadata

    private func refreshMarginMeta(now: Date) {
        let today = DBFormat.entryDate(now)
        let monthDay = String(today.dropFirst(5))
        onThisDay = (try? repo.onThisDayCount(
            monthDay: monthDay, excludingDate: today)) ?? 0
        streakDays = computeStreak(now: now)
    }

    private func computeStreak(now: Date) -> Int {
        guard let dates = try? repo.distinctEntryDates() else { return 0 }
        let have = Set(dates)
        var cursor = now
        // A day counts toward the streak once it has any entry; an empty
        // today doesn't break yesterday's streak.
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
}
