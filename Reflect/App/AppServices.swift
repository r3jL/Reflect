// Process-wide services. The database opens once at first use, at the
// sandboxed Application Support location (§3.2); media files live beside it.
import Foundation
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
}
