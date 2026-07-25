// The RAG core (Phase 2 / M17): a question becomes a token-budgeted,
// citation-stable context pack drawn from the journal — semantic KNN
// merged with FTS5 keyword hits, deduped, recency-tiebroken, and honest:
// when nothing clears the relevance floor, the verdict says so instead of
// padding weak context (FR-024 extended to retrieval).
import Foundation
import ReflectCore

public struct RetrievedContext: Equatable, Sendable {
    public enum Verdict: Equatable, Sendable {
        case relevant
        case nothingRelevant
    }

    public struct Item: Equatable, Sendable, Identifiable {
        public let citation: Int  // stable 1-based id, in rank order
        public let entryId: String
        public let entryDate: String
        public let text: String
        public let truncated: Bool
        public let summary: String?
        public let moodLabel: String?
        public let score: Double  // lower = stronger
        public let matchedKeyword: Bool
        public let matchedSemantic: Bool

        public var id: Int { citation }
    }

    public let items: [Item]
    public let verdict: Verdict

    /// The block M18 hands to the model — one numbered source per entry.
    public func promptBlock() -> String {
        items.map { item in
            var header = "[\(item.citation)] \(item.entryDate)"
            if let mood = item.moodLabel { header += " · felt \(mood)" }
            var lines = [header]
            if let summary = item.summary, !summary.isEmpty {
                lines.append("Summary: \(summary)")
            }
            lines.append(item.text)
            return lines.joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }
}

public struct JournalRetriever {
    public struct Configuration: Sendable {
        /// Most entries a pack may cite.
        public var maxEntries = 6
        /// Semantic relevance floor (echo discipline): semantic-only
        /// matches beyond this are dropped, never padded in.
        public var maxDistance = 1.25
        /// Approximate token budget for the pack's text.
        public var tokenBudget = 4000
        /// Rough chars-per-token used for budgeting.
        public var charsPerToken = 4
        /// Per-entry text cap before budget truncation (chars).
        public var maxCharsPerEntry = 1600

        public init() {}
    }

    private let db: AppDatabase
    private let provider: any AiProvider
    private let embeddingModel: @Sendable () -> String
    private let config: Configuration

    public init(
        db: AppDatabase,
        provider: any AiProvider,
        embeddingModel: @escaping @Sendable () -> String,
        configuration: Configuration = Configuration()
    ) {
        self.db = db
        self.provider = provider
        self.embeddingModel = embeddingModel
        self.config = configuration
    }

    /// Builds the pack. Deterministic given identical stores; if the
    /// query embedding fails (offline, AI off), retrieval degrades to
    /// keyword-only rather than failing the caller.
    public func retrieve(question: String) async throws -> RetrievedContext {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return RetrievedContext(items: [], verdict: .nothingRelevant)
        }

        let entries = EntriesRepository(db)
        let metadata = MetadataRepository(db)
        let embeddings = EmbeddingsRepository(db)

        // Semantic candidates (graceful when embedding is unavailable).
        var semanticDistance: [String: Double] = [:]
        if let (vectors, usage) = try? await provider.embed(
            model: embeddingModel(), texts: [trimmed]),
            let queryVector = vectors.first
        {
            _ = usage  // callers meter their own ledger stage
            let neighbors = (try? embeddings.nearestEntries(
                to: queryVector, k: config.maxEntries * 3)) ?? []
            for neighbor in neighbors where neighbor.distance <= config.maxDistance {
                semanticDistance[neighbor.entryId] = neighbor.distance
            }
        }

        // Keyword candidates keep their FTS rank order; an exact word match
        // is strong evidence, so they are never floor-dropped.
        var keywordRank: [String: Int] = [:]
        for (index, hit) in ((try? entries.searchKeyword(trimmed)) ?? []).enumerated()
        where keywordRank[hit.entry.id] == nil {
            keywordRank[hit.entry.id] = index
        }

        // Merge + score (lower is stronger, fully deterministic).
        var scored: [(entryId: String, score: Double, kw: Bool, sem: Bool)] = []
        for entryId in Set(semanticDistance.keys).union(keywordRank.keys) {
            let sem = semanticDistance[entryId]
            let kw = keywordRank[entryId].map { 0.95 + 0.01 * Double($0) }
            let score: Double
            switch (sem, kw) {
            case (let s?, let k?): score = Swift.min(s, k) - 0.1  // dual-match boost
            case (let s?, nil): score = s
            case (nil, let k?): score = k
            case (nil, nil): continue
            }
            scored.append((entryId, score, kw != nil, sem != nil))
        }

        guard !scored.isEmpty else {
            return RetrievedContext(items: [], verdict: .nothingRelevant)
        }

        // Resolve entries; rank by score, then recency, then id (stable).
        var resolved: [(Entry, Double, Bool, Bool)] = []
        for candidate in scored {
            guard let entry = try? entries.fetch(id: candidate.entryId),
                  !entry.isDeleted,
                  !entry.body.trimmingCharacters(in: .whitespaces).isEmpty
            else { continue }
            resolved.append((entry, candidate.score, candidate.kw, candidate.sem))
        }
        resolved.sort { a, b in
            if a.1 != b.1 { return a.1 < b.1 }
            if a.0.entryDate != b.0.entryDate { return a.0.entryDate > b.0.entryDate }
            return a.0.id < b.0.id
        }

        // Token-budgeted assembly: the strongest sources first; the first
        // item always fits (truncated if it must).
        var items: [RetrievedContext.Item] = []
        var remainingChars = config.tokenBudget * config.charsPerToken
        for (entry, score, kw, sem) in resolved.prefix(config.maxEntries) {
            // The first item always ships (floored allowance); later items
            // need meaningful room left or the pack closes.
            guard remainingChars >= 200 || items.isEmpty else { break }
            let allowance = Swift.min(
                config.maxCharsPerEntry, Swift.max(200, remainingChars))
            let fitted = Self.truncate(entry.body, maxChars: allowance)
            let reflection = try? metadata.reflection(entryId: entry.id)
            items.append(RetrievedContext.Item(
                citation: items.count + 1,
                entryId: entry.id,
                entryDate: entry.entryDate,
                text: fitted.text,
                truncated: fitted.truncated,
                summary: reflection?.summary,
                moodLabel: reflection?.moodLabel,
                score: score,
                matchedKeyword: kw,
                matchedSemantic: sem))
            remainingChars -= fitted.text.count
            if remainingChars <= 0 { break }
        }

        return RetrievedContext(
            items: items,
            verdict: items.isEmpty ? .nothingRelevant : .relevant)
    }

    /// Whitespace-boundary truncation with an ellipsis; deterministic.
    static func truncate(_ text: String, maxChars: Int) -> (text: String, truncated: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxChars else { return (trimmed, false) }
        let hardCut = trimmed.index(trimmed.startIndex, offsetBy: maxChars)
        let slice = trimmed[..<hardCut]
        let cut = slice.lastIndex(where: \.isWhitespace) ?? hardCut
        return (
            String(slice[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines) + "…",
            true
        )
    }
}
