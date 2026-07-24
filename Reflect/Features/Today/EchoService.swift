// Memory echoes (§3.6): local-only retrieval over stored vectors — the
// entry's first-chunk embedding queried against *past* entries. No provider
// calls (DEC-P1-01); weak matches are hidden rather than shown.
import Foundation
import ReflectCore

struct Echo: Identifiable, Equatable {
    let entryId: String
    let text: String
    let when: String
    let distance: Double

    var id: String { entryId }
}

enum EchoService {
    /// L2 distance ceiling on normalized embeddings — beyond this, an
    /// "echo" is noise; an empty margin beats a wrong memory. Calibrate
    /// against real data in M16.
    static let maxDistance = 1.2

    static func echoes(for entry: Entry, limit: Int = 2) -> [Echo] {
        let embeddings = EmbeddingsRepository(AppServices.database)
        guard let vector = try? embeddings.firstChunkVector(entryId: entry.id)
        else { return [] }
        guard let neighbors = try? embeddings.nearestEntries(
            to: vector, k: limit + 6, excluding: [entry.id])
        else { return [] }

        let repo = AppServices.entries
        var out: [Echo] = []
        for neighbor in neighbors where neighbor.distance <= maxDistance {
            guard let past = try? repo.fetch(id: neighbor.entryId),
                  past.entryDate < entry.entryDate,  // echoes come from the past
                  !past.body.isEmpty
            else { continue }
            out.append(Echo(
                entryId: past.id,
                text: snippet(past.body),
                when: whenLabel(past.entryDate),
                distance: neighbor.distance))
            if out.count == limit { break }
        }
        #if DEBUG
        for echo in out {
            print("echo d=\(String(format: "%.3f", echo.distance)) — \(echo.when)")
        }
        fflush(stdout)
        #endif
        return out
    }

    /// First sentence-ish of the body, softly bounded.
    static func snippet(_ body: String, maxLength: Int = 140) -> String {
        let trimmed = body
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let period = trimmed.firstIndex(of: "."),
           trimmed.distance(from: trimmed.startIndex, to: period) < maxLength
        {
            return String(trimmed[...period])
        }
        guard trimmed.count > maxLength else { return trimmed }
        let cut = trimmed.index(trimmed.startIndex, offsetBy: maxLength)
        return String(trimmed[..<cut]) + "…"
    }

    /// The design's when-language: relative for the near past, month-year
    /// beyond, "a year ago this week" for anniversaries.
    static func whenLabel(_ entryDate: String, now: Date = .now) -> String {
        let parts = entryDate.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = Calendar.current.date(
                  from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        else { return entryDate }

        let days = Calendar.current.dateComponents(
            [.day], from: date, to: now).day ?? 0
        if (358...372).contains(days) {
            return "a year ago this week"
        }
        if days < 60 {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            formatter.dateTimeStyle = .named
            return formatter.localizedString(for: date, relativeTo: now)
        }
        return date.formatted(.dateTime.month(.wide).year())
    }
}
