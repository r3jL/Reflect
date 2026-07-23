// Extraction stage (FR-021): one grouped structured-JSON call producing
// themes, tags, entities, action items and self-questions — written in a
// single superseding transaction (AC-005/AC-021). Only title+body leave
// the device.
import Foundation
import ReflectCore

/// The model-output contract; decoding *is* validation (a mismatch fails
/// the call as `.schema` upstream).
struct ExtractionOutput: Decodable, Equatable, Sendable {
    struct Entity: Decodable, Equatable, Sendable {
        let name: String
        let type: String
    }

    struct ActionItem: Decodable, Equatable, Sendable {
        let text: String
        let dueHint: String?

        enum CodingKeys: String, CodingKey {
            case text
            case dueHint = "due_hint"
        }
    }

    let themes: [String]
    let tags: [String]
    let entities: [Entity]
    let actionItems: [ActionItem]
    let selfQuestions: [String]

    enum CodingKeys: String, CodingKey {
        case themes, tags, entities
        case actionItems = "action_items"
        case selfQuestions = "self_questions"
    }
}

public struct ExtractionStage: PipelineStageRunner {
    private let db: AppDatabase
    private let provider: any AiProvider
    private let model: @Sendable () -> String

    /// Entries shorter than this have nothing worth extracting.
    static let minimumWords = 5

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
        guard Entry.wordCount(of: body) >= Self.minimumWords else {
            throw StageNotApplicable(reason: "entry too short to extract")
        }

        let modelId = model()
        let (output, usage) = try await provider.structuredChat(
            model: modelId,
            system: Prompts.extractionSystem,
            user: Prompts.extractionUser(title: entry.title, body: body),
            maxTokens: 1500,
            as: ExtractionOutput.self)

        // Bound list sizes defensively; the repository canonicalizes and
        // maps unknown entity types to 'other'.
        try MetadataRepository(db).replaceExtraction(
            entryId: entry.id,
            themes: Array(output.themes.prefix(8)),
            tags: Array(output.tags.prefix(12)),
            entities: output.entities.prefix(20).map {
                MetadataRepository.EntityRef(name: $0.name, type: $0.type)
            },
            actionItems: output.actionItems.prefix(12).map {
                MetadataRepository.ActionItemRef(text: $0.text, dueHint: $0.dueHint)
            },
            selfQuestions: Array(output.selfQuestions.prefix(8)))

        return StageOutcome(model: modelId, usage: usage)
    }
}
