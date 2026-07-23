// Provider abstraction (FR-025, §3.4): every AI capability sits behind
// AiProvider so cloud (OpenRouter, v1) and local (Ollama, Phase 2) are
// interchangeable. Structured output is decoded — and thereby validated —
// into caller-supplied Codable types; on any failure the pipeline stores
// null + a warning, never fabricated data (FR-024).
import Foundation

/// Token accounting for one provider call — the source for the KPI-10
/// cost ledger.
public struct AiUsage: Equatable, Sendable {
    public let promptTokens: Int
    public let completionTokens: Int

    public init(promptTokens: Int, completionTokens: Int) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
    }

    public static let zero = AiUsage(promptTokens: 0, completionTokens: 0)
}

/// Classified provider failures. `isRetryable` is the queue's contract:
/// retryable errors back off and try again (bounded), terminal ones fail
/// the job immediately (AC-024).
public enum AiError: Error, Equatable {
    case notConfigured            // AI disabled or no API key
    case auth                     // 401/403 — key invalid or revoked
    case rateLimited(retryAfterSeconds: Double?)
    case network(String)          // transport-level failure
    case schema(String)           // response did not match the expected JSON
    case provider(status: Int, message: String)

    public var isRetryable: Bool {
        switch self {
        case .notConfigured, .auth, .schema: false
        case .rateLimited, .network: true
        case .provider(let status, _): status >= 500
        }
    }
}

public protocol AiProvider: Sendable {
    /// One grouped structured-JSON call (extraction/reflection style).
    /// The provider must return output decodable as `Out` or throw
    /// `AiError.schema` — partial or repaired data is never returned.
    func structuredChat<Out: Decodable & Sendable>(
        model: String,
        system: String,
        user: String,
        maxTokens: Int,
        as output: Out.Type
    ) async throws -> (Out, AiUsage)

    /// Batch embeddings (bge-m3 @1024 in v1 — FR-023/FR-030).
    func embed(
        model: String,
        texts: [String]
    ) async throws -> ([[Float]], AiUsage)
}

/// Defined for v1, implemented in Phase 2 (Ollama adapter — §9.7).
/// Kept deliberately minimal: a local provider is an AiProvider whose
/// models live on disk.
public protocol LocalLlmProvider: AiProvider {
    var modelsDirectory: URL { get }
    var isAvailable: Bool { get }
}
