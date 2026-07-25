// The OpenAI-compatible transport (§3.4, generalized in M19): one core
// speaks to OpenRouter (cloud, keyed) and Ollama (local /v1, keyless)
// alike. Strict about output: JSON is decoded into the caller's type; a
// mismatch gets exactly one corrective retry, then fails as `.schema` so
// the pipeline can store null + warning.
import Foundation

/// The cloud configuration keeps its historical name at every call site.
public typealias OpenRouterProvider = OpenAICompatibleProvider

public final class OpenAICompatibleProvider: AiProvider {
    private let keyProvider: @Sendable () -> String?
    private let session: URLSession
    private let baseURL: URL
    private let requiresKey: Bool

    public init(
        keyProvider: @escaping @Sendable () -> String? = { nil },
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://openrouter.ai/api/v1")!,
        requiresKey: Bool = true
    ) {
        self.keyProvider = keyProvider
        self.session = session
        self.baseURL = baseURL
        self.requiresKey = requiresKey
    }

    // MARK: - AiProvider

    public func structuredChat<Out: Decodable & Sendable>(
        model: String,
        system: String,
        user: String,
        maxTokens: Int,
        as output: Out.Type
    ) async throws -> (Out, AiUsage) {
        var attempt = 0
        var lastSchemaError = ""
        var usageTotal = AiUsage.zero

        while attempt < 2 {
            attempt += 1
            let correctiveSuffix = attempt == 1
                ? ""
                : "\n\nYour previous response was not valid for the required "
                    + "schema (\(lastSchemaError)). Respond again with ONLY the "
                    + "corrected JSON object — no prose, no code fences."
            let body: [String: Any] = [
                "model": model,
                "max_tokens": maxTokens,
                "response_format": ["type": "json_object"],
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user", "content": user + correctiveSuffix],
                ],
            ]
            let data = try await post(path: "chat/completions", body: body)
            let envelope = try decodeEnvelope(ChatResponse.self, from: data)
            let usage = envelope.usage?.asAiUsage ?? .zero
            usageTotal = AiUsage(
                promptTokens: usageTotal.promptTokens + usage.promptTokens,
                completionTokens: usageTotal.completionTokens + usage.completionTokens)

            guard let content = envelope.choices.first?.message.content else {
                throw AiError.schema("empty completion")
            }
            do {
                let decoded = try Self.decodeStructured(output, from: content)
                return (decoded, usageTotal)
            } catch {
                lastSchemaError = String(describing: error).prefix(300)
                    .description
                continue
            }
        }
        throw AiError.schema(lastSchemaError)
    }

    public func embed(
        model: String,
        texts: [String]
    ) async throws -> ([[Float]], AiUsage) {
        guard !texts.isEmpty else { return ([], .zero) }
        let body: [String: Any] = ["model": model, "input": texts]
        let data = try await post(path: "embeddings", body: body)
        let envelope = try decodeEnvelope(EmbeddingsResponse.self, from: data)
        let vectors = envelope.data
            .sorted { $0.index < $1.index }
            .map { $0.embedding.map(Float.init) }
        guard vectors.count == texts.count else {
            throw AiError.schema(
                "expected \(texts.count) embeddings, got \(vectors.count)")
        }
        return (vectors, envelope.usage?.asAiUsage ?? .zero)
    }

    // MARK: - Transport

    private func post(path: String, body: [String: Any]) async throws -> Data {
        let key = keyProvider()
        if requiresKey {
            guard let key, !key.isEmpty else { throw AiError.notConfigured }
        }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        if let key, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Reflect", forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 120

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AiError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AiError.network("non-HTTP response")
        }
        switch http.statusCode {
        case 200...299:
            return data
        case 401, 403:
            throw AiError.auth
        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                .flatMap(Double.init)
            throw AiError.rateLimited(retryAfterSeconds: retryAfter)
        default:
            let message = String(data: data.prefix(500), encoding: .utf8) ?? ""
            throw AiError.provider(status: http.statusCode, message: message)
        }
    }

    private func decodeEnvelope<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw AiError.schema("envelope: \(error)")
        }
    }

    /// Decodes model output into the expected type, tolerating the code
    /// fences some models wrap JSON in despite instructions.
    static func decodeStructured<Out: Decodable>(
        _ type: Out.Type, from content: String
    ) throws -> Out {
        var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text
                .replacingOccurrences(
                    of: "^```[a-zA-Z]*\\n?", with: "", options: .regularExpression)
                .replacingOccurrences(
                    of: "\\n?```$", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return try JSONDecoder().decode(type, from: Data(text.utf8))
    }
}

// MARK: - Wire formats (OpenAI-compatible)

private struct ChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
        }
        let message: Message
    }
    let choices: [Choice]
    let usage: WireUsage?
}

private struct EmbeddingsResponse: Decodable {
    struct Item: Decodable {
        let index: Int
        let embedding: [Double]
    }
    let data: [Item]
    let usage: WireUsage?
}

private struct WireUsage: Decodable {
    let prompt_tokens: Int?
    let completion_tokens: Int?

    var asAiUsage: AiUsage {
        AiUsage(
            promptTokens: prompt_tokens ?? 0,
            completionTokens: completion_tokens ?? 0)
    }
}
