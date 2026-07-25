// The local adapter (M19 — FR-025 completed): Ollama through its
// OpenAI-compatible /v1 endpoint (DEC-P2-04). No key, no cloud; when
// Ollama isn't running the app behaves as if offline (jobs wait).
import Foundation

public final class OllamaProvider: LocalLlmProvider, @unchecked Sendable {
    private let core: OpenAICompatibleProvider
    private let rootURL: URL
    private let session: URLSession
    private let lock = NSLock()
    private var lastKnownAvailable = false

    public init(
        rootURL: URL = URL(string: "http://localhost:11434")!,
        session: URLSession = .shared
    ) {
        self.rootURL = rootURL
        self.session = session
        self.core = OpenAICompatibleProvider(
            keyProvider: { nil },
            session: session,
            baseURL: rootURL.appendingPathComponent("v1"),
            requiresKey: false)
    }

    // MARK: - LocalLlmProvider

    public var modelsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ollama/models")
    }

    /// Last probe result (cached; the pipeline gate reads this
    /// synchronously — call `probe()` at launch and on settings changes).
    public var isAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return lastKnownAvailable
    }

    /// Pings the Ollama root (fast, 1.5s timeout) and updates the cache.
    @discardableResult
    public func probe() async -> Bool {
        var request = URLRequest(url: rootURL)
        request.timeoutInterval = 1.5
        let available: Bool
        if let (_, response) = try? await session.data(for: request),
           let http = response as? HTTPURLResponse, http.statusCode == 200
        {
            available = true
        } else {
            available = false
        }
        lock.lock()
        lastKnownAvailable = available
        lock.unlock()
        return available
    }

    /// Locally installed models, via `/api/tags`.
    public func listLocalModels() async throws -> [String] {
        struct Tags: Decodable {
            struct Model: Decodable {
                let name: String
            }
            let models: [Model]
        }
        var request = URLRequest(url: rootURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 3
        let data: Data
        do {
            (data, _) = try await session.data(for: request)
        } catch {
            throw AiError.network(error.localizedDescription)
        }
        guard let tags = try? JSONDecoder().decode(Tags.self, from: data) else {
            throw AiError.schema("unexpected /api/tags payload")
        }
        return tags.models.map(\.name).sorted()
    }

    // MARK: - AiProvider (delegated to the shared transport)

    public func structuredChat<Out: Decodable & Sendable>(
        model: String, system: String, user: String, maxTokens: Int,
        as output: Out.Type
    ) async throws -> (Out, AiUsage) {
        try await core.structuredChat(
            model: model, system: system, user: user, maxTokens: maxTokens,
            as: output)
    }

    public func embed(
        model: String, texts: [String]
    ) async throws -> ([[Float]], AiUsage) {
        try await core.embed(model: model, texts: texts)
    }
}
