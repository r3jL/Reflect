// A photograph (or video poster) woven into the page flow, with the
// design's annotation-style caption row: mono "[ photo ]" marker + text.
// Videos open in the system player on click.
import AppKit
import ReflectCore
import SwiftUI

struct MediaFigure: View {
    let media: Media
    var onRemove: (() -> Void)?

    @State private var image: NSImage?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            ZStack(alignment: .topTrailing) {
                thumbnail
                if onRemove != nil, hovering {
                    removeButton.padding(8)
                }
            }
            caption
        }
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.18)) { hovering = inside }
        }
        .task(id: media.id) { loadThumbnail() }
    }

    // MARK: - Pieces

    @ViewBuilder
    private var thumbnail: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: 340)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .contentShape(RoundedRectangle(cornerRadius: 6))
                    .onTapGesture { openIfVideo() }
                    .overlay(alignment: .bottomLeading) {
                        if media.mediaType == .video {
                            playBadge.padding(10)
                        }
                    }
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.paper3)
                    .frame(height: 220)
            }
        }
        .shadow(color: Theme.ink.opacity(0.22), radius: 16, y: 10)
    }

    private var playBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: "play.fill").font(.system(size: 8))
            if let duration = media.durationSeconds {
                Text(Self.timestamp(duration))
        .font(Typography.sans(10, weight: .medium))
            }
        }
        .foregroundStyle(Theme.paper)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Theme.ink.opacity(0.65)))
    }

    private var caption: some View {
        HStack(spacing: 8) {
            Text(media.mediaType == .photo ? "[ photo ]" : "[ video ]")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Theme.ink4)
            if media.mediaType == .video, let duration = media.durationSeconds {
                Text(Self.timestamp(duration))
                    .font(Typography.sans(11.5))
                    .foregroundStyle(Theme.ink3)
            }
        }
    }

    private var removeButton: some View {
        Button(action: { onRemove?() }) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.ink2)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Theme.paper.opacity(0.92)))
                .overlay(Circle().stroke(Theme.hair, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Behavior

    private func loadThumbnail() {
        let path = media.thumbnailPath ?? media.filePath
        let url = AppServices.mediaStore.absoluteURL(path)
        Task.detached(priority: .userInitiated) {
            let loaded = NSImage(contentsOf: url)
            await MainActor.run { image = loaded }
        }
    }

    private func openIfVideo() {
        guard media.mediaType == .video else { return }
        NSWorkspace.shared.open(AppServices.mediaStore.absoluteURL(media.filePath))
    }

    private static func timestamp(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
