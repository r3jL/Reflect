// Embedding stage (FR-023/FR-030): paragraph-aware chunking for long
// entries, bge-m3 @1024 via the provider, versioned writes to
// embeddings_meta + vec_entries. Runs independent of extraction (AC-020).
import Foundation
import ReflectCore

public struct EmbeddingStage: PipelineStageRunner {
    public static let expectedDim = 1024
    /// ~1k tokens of journal prose (§ M13 plan).
    static let maxChunkChars = 3500

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
        guard !body.isEmpty else {
            throw StageNotApplicable(reason: "nothing to embed")
        }

        var text = body
        if let title = entry.title, !title.isEmpty {
            text = title + "\n\n" + body
        }
        let chunks = Self.chunk(text)

        let modelId = model()
        let (vectors, usage) = try await provider.embed(model: modelId, texts: chunks)

        for vector in vectors where vector.count != Self.expectedDim {
            throw AiError.schema(
                "embedding dim \(vector.count), expected \(Self.expectedDim)")
        }

        try EmbeddingsRepository(db).replaceEmbeddings(
            entryId: entry.id,
            chunks: vectors,
            model: "bge-m3",  // canonical name (§3.4); provider id may vary
            modelVersion: modelId)

        return StageOutcome(model: modelId, usage: usage)
    }

    /// Greedy paragraph packing: chunks stay under `maxChunkChars`, split
    /// mid-paragraph only when a single paragraph exceeds the budget.
    static func chunk(_ text: String) -> [String] {
        let paragraphs = text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var chunks: [String] = []
        var current = ""
        for paragraph in paragraphs {
            if paragraph.count > maxChunkChars {
                if !current.isEmpty {
                    chunks.append(current)
                    current = ""
                }
                var rest = paragraph[...]
                while rest.count > maxChunkChars {
                    let cut = rest.index(rest.startIndex, offsetBy: maxChunkChars)
                    chunks.append(String(rest[..<cut]))
                    rest = rest[cut...]
                }
                current = String(rest)
            } else if current.isEmpty {
                current = paragraph
            } else if current.count + 2 + paragraph.count <= maxChunkChars {
                current += "\n\n" + paragraph
            } else {
                chunks.append(current)
                current = paragraph
            }
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks.isEmpty ? [text] : chunks
    }
}
