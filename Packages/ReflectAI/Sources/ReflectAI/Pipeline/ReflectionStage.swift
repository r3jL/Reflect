// Reflection stage (FR-022): consumes the entry plus its extraction
// output, writes the single entry_reflection row — summary, 4-mood label
// (§3.6), confidence/sentiment (range-validated per AC-022), energy, and
// the entry-local note that becomes "Reflect noticed".
import Foundation
import ReflectCore

struct ReflectionOutput: Decodable, Equatable, Sendable {
    struct Mood: Decodable, Equatable, Sendable {
        let label: String
        let confidence: Double
    }

    let summary: String
    let mood: Mood
    let sentimentScore: Double
    let energy: String
    let reflectionNote: String

    enum CodingKeys: String, CodingKey {
        case summary, mood, energy
        case sentimentScore = "sentiment_score"
        case reflectionNote = "reflection_note"
    }
}

public struct ReflectionStage: PipelineStageRunner {
    static let moodLabels: Set<String> = ["bright", "warm", "calm", "quiet"]
    static let energyLevels: Set<String> = ["low", "medium", "high"]

    private let db: AppDatabase
    private let provider: any AiProvider
    private let model: @Sendable () -> String

    public init(
        db: AppDatabase,
        provider: any AiProvider,
        model: @escaping @Sendable () -> String
    ) {
        self.db = db
        self.provider = provider
        self.model = model
    }

    public func run(entry: Entry) async throws -> StageOutcome {
        let body = entry.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Entry.wordCount(of: body) >= ExtractionStage.minimumWords else {
            throw StageNotApplicable(reason: "entry too short to reflect on")
        }

        let metadata = MetadataRepository(db)
        let modelId = model()
        let (output, usage) = try await provider.structuredChat(
            model: modelId,
            system: Prompts.reflectionSystem,
            user: Prompts.reflectionUser(
                title: entry.title, body: body,
                themes: (try? metadata.themes(entryId: entry.id)) ?? [],
                tags: (try? metadata.tags(entryId: entry.id)) ?? [],
                entityNames: ((try? metadata.entities(entryId: entry.id)) ?? [])
                    .map(\.name)),
            maxTokens: 600,
            as: ReflectionOutput.self)

        // AC-022 range/vocabulary validation — out-of-contract output is a
        // schema failure (terminal, null + warning), never clamped data.
        let label = output.mood.label.lowercased()
        guard Self.moodLabels.contains(label) else {
            throw AiError.schema("unknown mood label '\(output.mood.label)'")
        }
        guard (0.0...1.0).contains(output.mood.confidence) else {
            throw AiError.schema("mood confidence \(output.mood.confidence) outside [0,1]")
        }
        guard (-1.0...1.0).contains(output.sentimentScore) else {
            throw AiError.schema("sentiment \(output.sentimentScore) outside [-1,1]")
        }
        let energy = output.energy.lowercased()
        guard Self.energyLevels.contains(energy) else {
            throw AiError.schema("unknown energy '\(output.energy)'")
        }

        try metadata.replaceReflection(
            entryId: entry.id,
            MetadataRepository.Reflection(
                summary: output.summary,
                moodLabel: label,
                moodConfidence: output.mood.confidence,
                sentimentScore: output.sentimentScore,
                energy: energy,
                reflectionNote: output.reflectionNote,
                model: modelId),
            modelVersion: Prompts.reflectionPromptVersion)

        return StageOutcome(model: modelId, usage: usage)
    }
}
