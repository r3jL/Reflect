// DEBUG-only sample month: launch with REFLECT_SEED=1 to populate recent
// weeks so the Life map can be browsed before real history exists.
// Idempotent via a UserDefaults marker; never compiled into Release.
#if DEBUG
import Foundation
import ReflectCore

enum DebugSeed {
    static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["REFLECT_SEED"] == "1",
              !UserDefaults.standard.bool(forKey: "reflect.debug.seeded")
        else { return }

        let repo = AppServices.entries
        let calendar = Calendar.current
        let now = Date.now
        let bodies = [
            "Slow morning. The city is emptying out for summer.",
            String(repeating: "A long day of small decisions, each one lighter than the last. ", count: 4),
            String(repeating: "Wrote until the afternoon lost its color and the room went quiet around the desk. ", count: 8),
            "Read on the tram all afternoon. Missed my stop twice.",
            String(repeating: "The market, the hill, the small green door we could not open. ", count: 6),
        ]

        for dayOffset in 1...18 {
            guard let date = calendar.date(byAdding: .day, value: -dayOffset, to: now)
            else { continue }
            // A lived-in month has gaps.
            if dayOffset % 5 == 0 { continue }
            let entryDate = DBFormat.entryDate(date)
            guard let entry = try? repo.fetchOrCreateForDate(entryDate, now: date)
            else { continue }
            try? repo.updateBody(
                id: entry.id, title: nil,
                body: bodies[dayOffset % bodies.count], now: date)
            if dayOffset == 4 || dayOffset == 11 {
                try? repo.updateContext(
                    id: entry.id, place: "The studio", weather: nil, isMilestone: true)
            }
            try? repo.complete(id: entry.id, now: date)
        }
        UserDefaults.standard.set(true, forKey: "reflect.debug.seeded")
    }
}
#endif
