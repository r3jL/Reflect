// DEBUG-only sample month: launch with REFLECT_SEED=1 to populate recent
// weeks so the Life map can be browsed before real history exists.
// Idempotent via a UserDefaults marker; never compiled into Release.
#if DEBUG
import CoreGraphics
import Foundation
import ImageIO
import ReflectAI
import ReflectCore
import UniformTypeIdentifiers

enum DebugSeed {
    static func runIfRequested() {
        seedEntriesIfRequested()
        seedMediaIfRequested()
        askIfRequested()
    }

    /// REFLECT_ASK="question": run the full live ask flow (retrieval +
    /// chat) against the real journal and print the answer — the M18
    /// headless smoke.
    private static func askIfRequested() {
        guard let question = ProcessInfo.processInfo.environment["REFLECT_ASK"],
              !question.isEmpty
        else { return }
        Task {
            let service = AskService(
                db: AppServices.database,
                provider: AppServices.aiProvider,
                chatModel: { AppServices.chatModelId },
                embeddingModel: { AppServices.embeddingModelId })
            do {
                let exchange = try await service.ask(question: question)
                print("ASK Q: \(exchange.question)")
                print("ASK A: \(exchange.answer)")
                print("ASK cited: \(exchange.cited.map(\.entryDate).joined(separator: ", "))")
                print("ASK declined: \(exchange.declined)")
            } catch {
                print("ASK failed: \(error)")
            }
            fflush(stdout)
        }
    }

    /// REFLECT_SEED_MEDIA=1: run one generated photo through the real
    /// import path (MediaStore + MediaRepository) onto today's entry.
    private static func seedMediaIfRequested() {
        guard ProcessInfo.processInfo.environment["REFLECT_SEED_MEDIA"] == "1",
              !UserDefaults.standard.bool(forKey: "reflect.debug.mediaSeeded")
        else { return }
        Task {
            do {
                let temp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("seed-photo-\(UUID().uuidString).jpg")
                try makeJPEG(at: temp, width: 1600, height: 1000)
                let entry = try AppServices.entries.fetchOrCreateForDate(
                    DBFormat.entryDate(.now))
                let imported = try await AppServices.mediaStore.importFile(from: temp)
                _ = try AppServices.media.insert(
                    entryId: entry.id,
                    filePath: imported.relativePath,
                    thumbnailPath: imported.thumbnailRelativePath,
                    mediaType: .photo,
                    mimeType: imported.mimeType,
                    fileSizeBytes: imported.fileSizeBytes,
                    width: imported.width,
                    height: imported.height)
                try? FileManager.default.removeItem(at: temp)
                UserDefaults.standard.set(true, forKey: "reflect.debug.mediaSeeded")
                print("DebugSeed: media seeded at \(imported.relativePath)")
            } catch {
                print("DebugSeed: media seed failed: \(error)")
            }
        }
    }

    private static func makeJPEG(at url: URL, width: Int, height: Int) throws {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
            let destination = { () -> CGImageDestination? in
                context.setFillColor(CGColor(red: 0.65, green: 0.42, blue: 0.27, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                context.setFillColor(CGColor(red: 0.97, green: 0.96, blue: 0.94, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
                guard let image = context.makeImage() else { return nil }
                guard let dest = CGImageDestinationCreateWithURL(
                    url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
                else { return nil }
                CGImageDestinationAddImage(dest, image, nil)
                return dest
            }()
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private static func seedEntriesIfRequested() {
        guard ProcessInfo.processInfo.environment["REFLECT_SEED"] == "1",
              !UserDefaults.standard.bool(forKey: "reflect.debug.seeded")
        else { return }

        let repo = AppServices.entries
        let calendar = Calendar.current
        let now = Date.now
        let bodies = [
            "Slow morning. The city is emptying out for summer.",
            String(repeating: "A long day of small decisions, each one lighter than the last. ", count: 4),
            String(repeating: "Wrote until the afternoon lost its color and the room went quiet around the desk. ", count: 8),
            "Read on the tram all afternoon. Missed my stop twice.",
            String(repeating: "The market, the hill, the small green door we could not open. ", count: 6),
        ]

        for dayOffset in 1...18 {
            guard let date = calendar.date(byAdding: .day, value: -dayOffset, to: now)
            else { continue }
            // A lived-in month has gaps.
            if dayOffset % 5 == 0 { continue }
            let entryDate = DBFormat.entryDate(date)
            guard let entry = try? repo.fetchOrCreateForDate(entryDate, now: date)
            else { continue }
            try? repo.updateBody(
                id: entry.id, title: nil,
                body: bodies[dayOffset % bodies.count], now: date)
            if dayOffset == 4 || dayOffset == 11 {
                try? repo.updateContext(
                    id: entry.id, place: "The studio", weather: nil, isMilestone: true)
            }
            try? repo.complete(id: entry.id, now: date)
        }
        UserDefaults.standard.set(true, forKey: "reflect.debug.seeded")
    }
}
#endif
