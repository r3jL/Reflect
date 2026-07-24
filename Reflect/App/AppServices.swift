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

    /// Gates per AC-004/AC-025: AI on + key present + online, else jobs
    /// simply stay pending.
    static var aiIsConfigured: Bool {
        ((try? settings.getBool(.aiEnabled)) ?? false)
            && KeychainStore.cachedGet(account: KeychainStore.openRouterKeyAccount) != nil
    }

    static let orchestrator: PipelineOrchestrator = {
        let provider = OpenRouterProvider(keyProvider: {
            KeychainStore.cachedGet(account: KeychainStore.openRouterKeyAccount)
        })
        let runners: [PipelineJob.Stage: any PipelineStageRunner] = [
            .extraction: ExtractionStage(
                db: database, provider: provider,
                model: {
                    (try? settings.get(.modelExtraction))
                        ?? "google/gemini-2.5-flash"
                }),
            .reflection: ReflectionStage(
                db: database, provider: provider,
                model: {
                    (try? settings.get(.modelReflection))
                        ?? "anthropic/claude-sonnet-4.6"
                }),
            .embedding: EmbeddingStage(
                db: database, provider: provider,
                model: {
                    // Canonical name in settings; OpenRouter wants the
                    // namespaced id.
                    let raw = (try? settings.get(.modelEmbedding)) ?? "bge-m3"
                    return raw == "bge-m3" ? "baai/bge-m3" : raw
                }),
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
