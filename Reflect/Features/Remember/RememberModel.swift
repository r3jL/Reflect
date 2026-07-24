// State for the Remember overlay (§3.6, M15): faceted results in the
// design's shape — People / Places / Projects / Books from entities,
// Threads from themes, keyword hits, and a "Feels related" semantic group
// via one query embedding. The AI lead sentence arrives on a 700ms
// debounce; everything degrades gracefully with AI off.
import Foundation
import Observation
import ReflectAI
import ReflectCore

@Observable
@MainActor
final class RememberModel {
    struct Group: Identifiable {
        let label: String
        let items: [EntriesRepository.SearchHit]
        var id: String { label }
    }

    private let repo: EntriesRepository
    private let metadata: MetadataRepository

    var query = "" {
        didSet { if query != oldValue { scheduleSearch() } }
    }
    private(set) var groups: [Group] = []
    private(set) var lead = ""
    private(set) var hints: [String] = []
    var opened: Entry?
    private(set) var openedMood: Theme.Mood?

    private var searchTask: Task<Void, Never>?
    private var semanticTask: Task<Void, Never>?
    private var leadTask: Task<Void, Never>?

    /// Facet display order (design's ordering, adapted to real data).
    private static let facetOrder = [
        "People", "Places", "Projects", "Books", "Work",
        "Threads", "In your words", "Feels related",
    ]

    private static let entityFacets: [String: String] = [
        "person": "People", "place": "Places", "project": "Projects",
        "book": "Books", "company": "Work", "other": "Mentioned",
    ]

    init(
        repo: EntriesRepository = AppServices.entries,
        metadata: MetadataRepository = AppServices.metadata
    ) {
        self.repo = repo
        self.metadata = metadata
    }

    var isEmptyState: Bool {
        query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func loadHints() {
        var chips = (try? repo.recentPlaces()) ?? []
        for theme in (try? metadata.topThemes(limit: 4)) ?? []
        where chips.count < 5 {
            chips.append(theme.name)
        }
        for fallback in ["this week", "a good day"] where chips.count < 5 {
            chips.append(fallback)
        }
        hints = chips
    }

    func open(_ entry: Entry) {
        openedMood = (try? repo.moodLabels(entryIds: [entry.id]))?[entry.id]
            .flatMap(Theme.Mood.init(rawValue:))
        opened = entry
    }

    /// Re-run the current query (after a trash action, for instance).
    func refresh() {
        guard !isEmptyState else { return }
        runSearch()
    }

    // MARK: - Search

    private func scheduleSearch() {
        searchTask?.cancel()
        semanticTask?.cancel()
        leadTask?.cancel()
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

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespaces)
        var used = Set<String>()
        var byFacet: [String: [EntriesRepository.SearchHit]] = [:]

        func add(_ entry: Entry, to facet: String, snippet: String? = nil) {
            guard !used.contains(entry.id) else { return }
            used.insert(entry.id)
            byFacet[facet, default: []].append(
                EntriesRepository.SearchHit(
                    entry: entry,
                    snippet: snippet ?? EchoService.snippet(entry.body)))
        }

        // Entity facets (People / Places / Projects / Books / Work)
        for entity in (try? metadata.entitiesMatching(q)) ?? [] {
            let facet = Self.entityFacets[entity.type] ?? "Mentioned"
            for entry in (try? metadata.entries(
                forEntity: entity.name, type: entity.type)) ?? []
            {
                add(entry, to: facet)
            }
        }

        // Themes → Threads
        for theme in (try? metadata.themesMatching(q)) ?? [] {
            for entry in (try? metadata.entries(forTheme: theme)) ?? [] {
                add(entry, to: "Threads")
            }
        }

        // Keyword hits → In your words (keeps FTS snippets)
        for hit in (try? repo.searchKeyword(q)) ?? []
        where !used.contains(hit.entry.id) {
            used.insert(hit.entry.id)
            byFacet["In your words", default: []].append(hit)
        }

        groups = Self.ordered(byFacet)
        updateLead(resultCount: used.count, query: q)
        runSemantic(query: q, alreadyUsed: used)
    }

    private static func ordered(
        _ byFacet: [String: [EntriesRepository.SearchHit]]
    ) -> [Group] {
        var out: [Group] = []
        for label in facetOrder {
            if let items = byFacet[label], !items.isEmpty {
                out.append(Group(label: label, items: Array(items.prefix(6))))
            }
        }
        for (label, items) in byFacet
        where !facetOrder.contains(label) && !items.isEmpty {
            out.append(Group(label: label, items: Array(items.prefix(6))))
        }
        return out
    }

    // MARK: - Hybrid retrieval (one query embedding, AI-on only)

    private func runSemantic(query q: String, alreadyUsed: Set<String>) {
        guard AppServices.aiIsConfigured, q.count >= 3 else { return }
        semanticTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (vectors, usage) = try await AppServices.aiProvider.embed(
                    model: AppServices.embeddingModelId, texts: [q])
                guard !Task.isCancelled, let vector = vectors.first else { return }
                try? AppServices.usage.record(
                    entryId: nil, stage: "search",
                    model: AppServices.embeddingModelId,
                    promptTokens: usage.promptTokens,
                    completionTokens: usage.completionTokens,
                    costEstimate: ModelPricing.estimate(
                        model: AppServices.embeddingModelId, usage: usage))

                let embeddings = EmbeddingsRepository(AppServices.database)
                let neighbors = (try? embeddings.nearestEntries(
                    to: vector, k: 5, excluding: alreadyUsed)) ?? []
                let hits: [EntriesRepository.SearchHit] = neighbors
                    .filter { $0.distance <= 1.25 }
                    .compactMap { neighbor in
                        guard let entry = try? self.repo.fetch(id: neighbor.entryId),
                              !entry.body.isEmpty
                        else { return nil }
                        return EntriesRepository.SearchHit(
                            entry: entry, snippet: EchoService.snippet(entry.body))
                    }
                guard !hits.isEmpty, self.query.trimmingCharacters(in: .whitespaces) == q
                else { return }
                self.groups.append(Group(label: "Feels related", items: hits))
            } catch {
                // Semantic layer is additive — keyword results stand alone.
            }
        }
    }

    // MARK: - Lead sentence (700ms debounce; static fallback)

    private func updateLead(resultCount: Int, query q: String) {
        lead = resultCount == 0
            ? "Nothing surfaces yet. Try a place, a person, a feeling."
            : "Some of this is coming back to you…"
        guard AppServices.aiIsConfigured, q.count >= 3 else { return }
        leadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, let self else { return }
            do {
                let (out, usage) = try await AppServices.aiProvider.structuredChat(
                    model: (try? AppServices.settings.get(.modelReflection))
                        ?? "anthropic/claude-sonnet-4.6",
                    system: SearchPrompts.system,
                    user: SearchPrompts.user(query: q, resultCount: resultCount),
                    maxTokens: 80,
                    as: SearchPrompts.Lead.self)
                try? AppServices.usage.record(
                    entryId: nil, stage: "search",
                    model: (try? AppServices.settings.get(.modelReflection)) ?? "",
                    promptTokens: usage.promptTokens,
                    completionTokens: usage.completionTokens,
                    costEstimate: nil)
                guard !Task.isCancelled,
                      self.query.trimmingCharacters(in: .whitespaces) == q,
                      !out.lead.isEmpty
                else { return }
                self.lead = out.lead
            } catch {
                // Keep the static lead — never block search on the model.
            }
        }
    }
}
