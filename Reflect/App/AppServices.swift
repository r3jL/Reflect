// Process-wide services. The database opens once at first use, at the
// sandboxed Application Support location (§3.2); media files live beside it.
import Foundation
import ReflectAI
import ReflectCore
import ReflectMedia

enum AppServices {
    static let database: AppDatabase = {
        do {
            return try AppDatabase(at: AppDatabase.defaultURL())
        } catch {
            // A journal that cannot open its store cannot run; surface loudly.
            fatalError("Reflect could not open its database: \(error)")
        }
    }()

    static let mediaStore: MediaStore = {
        do {
            return try MediaStore(
                rootURL: try AppDatabase.defaultURL().deletingLastPathComponent())
        } catch {
            fatalError("Reflect could not prepare its media directory: \(error)")
        }
    }()

    static var entries: EntriesRepository { EntriesRepository(database) }
    static var media: MediaRepository { MediaRepository(database) }
    static var settings: SettingsRepository { SettingsRepository(database) }
    static var metadata: MetadataRepository { MetadataRepository(database) }
    static var usage: UsageRepository { UsageRepository(database) }

    // MARK: - AI pipeline (Phase 1)

    static let networkMonitor = NetworkMonitor()

    // MARK: Provider selection (M19 — the §1.3 cloud↔local toggle)

    static let openRouterProvider = OpenAICompatibleProvider(keyProvider: {
        KeychainStore.cachedGet(account: KeychainStore.openRouterKeyAccount)
    })
    static let ollamaProvider = OllamaProvider()

    static var usingOllama: Bool {
        (try? settings.get(.aiProvider)) == "ollama"
    }

    /// Everything — pipeline stages, semantic search, chat — routes
    /// through this facade, so the settings toggle applies at call time.
    static let aiProvider: any AiProvider = RoutingProvider()

    struct RoutingProvider: AiProvider {
        func structuredChat<Out: Decodable & Sendable>(
            model: String, system: String, user: String, maxTokens: Int,
            as output: Out.Type
        ) async throws -> (Out, AiUsage) {
            try await AppServices.resolvedProvider.structuredChat(
                model: model, system: system, user: user,
                maxTokens: maxTokens, as: output)
        }

        func embed(model: String, texts: [String]) async throws -> ([[Float]], AiUsage) {
            try await AppServices.resolvedProvider.embed(model: model, texts: texts)
        }
    }

    private static var resolvedProvider: any AiProvider {
        usingOllama ? ollamaProvider : openRouterProvider
    }

    /// Gates per AC-004/AC-025: AI on + a usable provider, else jobs
    /// simply stay pending. Ollama-not-running behaves like offline.
    static var aiIsConfigured: Bool {
        guard (try? settings.getBool(.aiEnabled)) ?? false else { return false }
        return usingOllama
            ? ollamaProvider.isAvailable
            : KeychainStore.cachedGet(account: KeychainStore.openRouterKeyAccount) != nil
    }

    // MARK: Model ids (provider-aware)

    static var extractionModelId: String {
        usingOllama
            ? localChatModelId
            : (try? settings.get(.modelExtraction)) ?? "google/gemini-2.5-flash"
    }

    static var reflectionModelId: String {
        usingOllama
            ? localChatModelId
            : (try? settings.get(.modelReflection)) ?? "anthropic/claude-sonnet-4.6"
    }

    /// Chat (ask-your-journal + search lead) follows the reflection model.
    static var chatModelId: String { reflectionModelId }

    static var localChatModelId: String {
        (try? settings.get(.localChatModel)) ?? "qwen2.5:7b"
    }

    /// bge-m3 on both providers (DEC-P2-05, same vector space) — only the
    /// id differs: OpenRouter namespaces it, Ollama doesn't.
    static var embeddingModelId: String {
        if usingOllama { return "bge-m3" }
        let raw = (try? settings.get(.modelEmbedding)) ?? "bge-m3"
        return raw == "bge-m3" ? "baai/bge-m3" : raw
    }

    static let orchestrator: PipelineOrchestrator = {
        let provider = aiProvider
        let runners: [PipelineJob.Stage: any PipelineStageRunner] = [
            .extraction: ExtractionStage(
                db: database, provider: provider,
                model: { extractionModelId }),
            .reflection: ReflectionStage(
                db: database, provider: provider,
                model: { reflectionModelId }),
            .embedding: EmbeddingStage(
                db: database, provider: provider,
                model: { embeddingModelId }),
        ]
        let orchestrator = PipelineOrchestrator(
            db: database,
            runners: runners,
            isEnabled: { aiIsConfigured },
            isOnline: { networkMonitor.isOnline })
        networkMonitor.setOnReconnect { orchestrator.kick() }
        return orchestrator
    }()
}
