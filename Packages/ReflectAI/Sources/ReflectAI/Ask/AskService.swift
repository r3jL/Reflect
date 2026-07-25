// Ask your journal (Phase 2 / M18): grounded question-answering over the
// M17 retriever. The contract is absolute — answers come from the provided
// entries or the service declines; an empty pack declines deterministically
// WITHOUT a model call (FR-024 extended to chat).
import Foundation
import ReflectCore

public enum AskPrompts {
    public struct Answer: Decodable, Sendable {
        public let answer: String
        public let citations: [Int]
    }

    public static let system = """
        You are Reflect, a quiet companion living inside someone's private \
        journal. You answer their questions about their own life using ONLY \
        the numbered journal entries provided as sources. The entries are \
        their words; treat them as the only truth available.

        Return ONLY a JSON object: {"answer": "...", "citations": [1, 2]}

        Rules:
        - Ground every claim in the provided entries. If they do not hold \
        the answer, say so plainly and warmly (e.g. "Your journal doesn't \
        seem to hold this yet.") and return an empty citations list.
        - NEVER use outside knowledge, never guess, never invent events, \
        dates, people or feelings that are not in the sources.
        - citations lists the source numbers you actually drew from.
        - Voice: warm, quiet, human. 2-5 sentences. Refer to sources \
        naturally by their date ("In late July you wrote…"), never as \
        "[1]" or "source 1" inside the answer text.
        - No advice unless asked. No prose outside the JSON, no code fences.
        """

    public static func user(
        question: String,
        context: RetrievedContext,
        thread: [AskExchange]
    ) -> String {
        var parts: [String] = []
        if !thread.isEmpty {
            let recent = thread.suffix(3).map { exchange in
                "Q: \(exchange.question)\nA: \(exchange.answer)"
            }
            parts.append(
                "Earlier in this conversation:\n" + recent.joined(separator: "\n"))
        }
        parts.append(
            "Journal entries (your only sources):\n\n\(context.promptBlock())")
        parts.append("Question: \(question)")
        return parts.joined(separator: "\n\n")
    }
}

/// One question-and-answer turn, with the entries the answer stood on.
public struct AskExchange: Equatable, Sendable {
    public let question: String
    public let answer: String
    public let cited: [RetrievedContext.Item]
    public let declined: Bool

    public init(
        question: String, answer: String,
        cited: [RetrievedContext.Item], declined: Bool
    ) {
        self.question = question
        self.answer = answer
        self.cited = cited
        self.declined = declined
    }
}

public struct AskService {
    public static let declineAnswer =
        "Your journal doesn't seem to hold this yet."

    private let db: AppDatabase
    private let provider: any AiProvider
    private let chatModel: @Sendable () -> String
    private let retriever: JournalRetriever

    public init(
        db: AppDatabase,
        provider: any AiProvider,
        chatModel: @escaping @Sendable () -> String,
        embeddingModel: @escaping @Sendable () -> String,
        retrieverConfiguration: JournalRetriever.Configuration = .init()
    ) {
        self.db = db
        self.provider = provider
        self.chatModel = chatModel
        self.retriever = JournalRetriever(
            db: db, provider: provider, embeddingModel: embeddingModel,
            configuration: retrieverConfiguration)
    }

    public func ask(
        question: String, thread: [AskExchange] = []
    ) async throws -> AskExchange {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = try await retriever.retrieve(question: trimmed)

        // Nothing relevant: decline deterministically — no model call, no
        // chance of an ungrounded answer, no spend.
        guard context.verdict == .relevant else {
            return AskExchange(
                question: trimmed, answer: Self.declineAnswer,
                cited: [], declined: true)
        }

        let model = chatModel()
        let (output, usage) = try await provider.structuredChat(
            model: model,
            system: AskPrompts.system,
            user: AskPrompts.user(
                question: trimmed, context: context, thread: thread),
            maxTokens: 700,
            as: AskPrompts.Answer.self)

        try? UsageRepository(db).record(
            entryId: nil, stage: "chat", model: model,
            promptTokens: usage.promptTokens,
            completionTokens: usage.completionTokens,
            costEstimate: ModelPricing.estimate(model: model, usage: usage))

        // Only citation ids that exist in the pack survive.
        let validCitations = Set(output.citations)
        let cited = context.items.filter { validCitations.contains($0.citation) }
        let declined = cited.isEmpty && output.citations.isEmpty

        return AskExchange(
            question: trimmed,
            answer: output.answer.trimmingCharacters(in: .whitespacesAndNewlines),
            cited: cited,
            declined: declined)
    }
}
