// The writing room (§3.6), wired to ReflectCore (M3): the day's draft loads
// or is created on appear, autosaves on idle/blur, and completes into the
// pipeline. Responsive per the mockup: wide windows carry the living layer
// in the page margins; narrow windows fold it into an inline section below
// the writing. Marginalia content (echoes, observations) arrives in Phase 1.
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct TodayView: View {
    @State private var model = TodayModel()
    @State private var isTyping = false
    @State private var idleTimer: Timer?
    @State private var showFileImporter = false
    @State private var pickedPhotos: [PhotosPickerItem] = []

    private var marginOpacity: Double { isTyping ? 0.25 : 1 }

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width >= 1160
            ScrollView(.vertical, showsIndicators: false) {
                if wide {
                    HStack(alignment: .top, spacing: 0) {
                        marginColumn {
                            // Memory echoes appear here (Phase 1).
                            EmptyView()
                        }
                        centerColumn
                            .layoutPriority(1)
                        marginColumn {
                            marginMetaBlocks
                        }
                    }
                    .padding(.bottom, 100)
                    .frame(maxWidth: 1300)
                    .frame(maxWidth: .infinity)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        centerColumn
                        inlineLivingLayer
                    }
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(.horizontal, 40)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .background(Theme.paper)
        .onAppear { model.load() }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.willTerminateNotification)
        ) { _ in
            model.flush()
            model.saveContext()
        }
    }

    // MARK: - Center: the writing

    private var centerColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Kicker(text: Date.now.formatted(.dateTime.weekday(.wide)))
                .padding(.bottom, 14)

            Text(Date.now.formatted(.dateTime.month(.wide).day()))
                .font(Typography.serif(56, weight: .light))
                .foregroundStyle(Theme.ink)

            metaRow.padding(.top, 14)

            ZStack(alignment: .topLeading) {
                if model.text.isEmpty {
                    // Clear of the caret, which blinks at x0 (design: caret
                    // sits just left of the first glyph).
                    Text("Begin…")
                        .font(Typography.serif(22))
                        .foregroundStyle(Theme.ink4)
                        .padding(.leading, 5)
                        .padding(.top, 1)
                        .allowsHitTesting(false)
                }
                SerifTextView(
                    text: $model.text,
                    onEdit: handleEdit,
                    onBlur: { model.flush() },
                    focusOnAppear: true
                )
                .frame(minHeight: 320)
            }
            .padding(.top, 44)

            if !model.attachments.isEmpty {
                VStack(alignment: .leading, spacing: 26) {
                    ForEach(model.attachments) { media in
                        MediaFigure(media: media) {
                            model.removeAttachment(media)
                        }
                    }
                }
                .padding(.top, 26)
            }

            HStack(spacing: 22) {
                completeRow
                attachButtons
                Spacer()
            }
            .padding(.top, 34)
        }
        .frame(maxWidth: Theme.writingColumnWidth, alignment: .leading)
        .padding(.top, 120)
        .padding(.bottom, 60)
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.image, .movie],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                Task { await model.attach(fileURLs: urls) }
            }
        }
        .onChange(of: pickedPhotos) { _, items in
            guard !items.isEmpty else { return }
            pickedPhotos = []
            Task { await importPickedPhotos(items) }
        }
    }

    /// Quiet attach affordances beside Complete: files + Photos library.
    private var attachButtons: some View {
        HStack(spacing: 16) {
            Button(action: { showFileImporter = true }) {
                attachLabel("photo.on.rectangle", "Add photo or video")
            }
            .buttonStyle(.plain)

            PhotosPicker(
                selection: $pickedPhotos,
                matching: .any(of: [.images, .videos])
            ) {
                attachLabel("photo.stack", "From Photos")
            }
            .buttonStyle(.plain)
        }
    }

    private func attachLabel(_ symbol: String, _ title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11))
            Text(title).font(Typography.sans(11)).tracking(0.4)
        }
        .foregroundStyle(Theme.ink3)
        .contentShape(Rectangle())
    }

    // MARK: - Attach plumbing

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            handled = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { await model.attach(fileURLs: [url]) }
            }
        }
        return handled
    }

    /// Photos-library items arrive as data; stage to temp files, then reuse
    /// the standard import path.
    private func importPickedPhotos(_ items: [PhotosPickerItem]) async {
        var staged: [URL] = []
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self)
            else { continue }
            let type = item.supportedContentTypes.first
            let ext = type?.preferredFilenameExtension ?? "jpg"
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("photos-import-\(UUID().uuidString).\(ext)")
            do {
                try data.write(to: temp)
                staged.append(temp)
            } catch { continue }
        }
        await model.attach(fileURLs: staged)
        for url in staged { try? FileManager.default.removeItem(at: url) }
    }

    /// Mood dot (hollow until reflection exists) · place · weather (FR-015).
    private var metaRow: some View {
        HStack(spacing: 14) {
            Circle()
                .stroke(Theme.ink4, lineWidth: 1.5)
                .frame(width: 8, height: 8)

            dotSeparator
            contextField("Add place", text: $model.place)
            dotSeparator
            contextField("Weather", text: $model.weather)
            Spacer()
        }
        .font(Typography.sans(12.5))
        .foregroundStyle(Theme.ink3)
    }

    private var dotSeparator: some View {
        Circle().fill(Theme.ink4).frame(width: 3, height: 3)
    }

    private func contextField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .foregroundStyle(Theme.ink3)
            .fixedSize()
            .onSubmit { model.saveContext() }
    }

    /// Quiet completion affordance; after completing, the AI-pending state
    /// (AC-004) shows as a breathing dot until the pipeline drains (Phase 1).
    @ViewBuilder
    private var completeRow: some View {
        if model.canComplete {
            Button(action: { model.complete() }) {
                HStack(spacing: 6) {
                    Circle().fill(Theme.accent).frame(width: 5, height: 5)
                    Text("Complete entry")
                        .font(Typography.sans(11))
                        .tracking(0.4)
                }
                .foregroundStyle(Theme.accent)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else if model.isCompleted {
            HStack(spacing: 8) {
                Kicker(text: "Completed")
                if model.pendingJobs {
                    HStack(spacing: 6) {
                        BreathingDot(color: Theme.accentSoft)
                        Text("AI pending")
                            .font(Typography.sans(11))
                            .foregroundStyle(Theme.ink4)
                    }
                }
            }
        }
    }

    // MARK: - The living layer (margins when wide, inline when narrow)

    @ViewBuilder
    private var marginMetaBlocks: some View {
        metaBlock(label: "Words today", value: "\(model.wordCount)")
        if model.streakDays > 1 {
            metaBlock(label: "Writing streak", value: "\(model.streakDays) days")
        }
        if model.onThisDay > 0 {
            metaBlock(
                label: "On this day",
                value: "\(model.onThisDay) past \(model.onThisDay == 1 ? "entry" : "entries")")
        }
    }

    private func marginColumn<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 34, content: content)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, 34)
            .padding(.top, 130)
            .opacity(marginOpacity)
    }

    /// Narrow windows: the mockup folds the living layer below the entry,
    /// behind a hairline.
    private var inlineLivingLayer: some View {
        VStack(alignment: .leading, spacing: 30) {
            Rectangle().fill(Theme.hair).frame(height: 1)
            HStack(alignment: .top, spacing: 34) {
                marginMetaBlocks
                Spacer()
            }
        }
        .padding(.top, 22)
        .padding(.bottom, 120)
        .opacity(marginOpacity)
    }

    private func metaBlock(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Kicker(text: label)
            Text(value)
                .font(Typography.serif(16))
                .foregroundStyle(Theme.ink2)
        }
    }

    // MARK: - Focus behavior

    private func handleEdit() {
        withAnimation(.easeOut(duration: 0.3)) { isTyping = true }
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { _ in
            DispatchQueue.main.async {
                withAnimation(.easeIn(duration: 0.7)) { isTyping = false }
            }
        }
    }
}

/// The design's "breathing" dot (§3.6 motion vocabulary).
struct BreathingDot: View {
    let color: Color
    @State private var up = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 5, height: 5)
            .opacity(up ? 1 : 0.55)
            .scaleEffect(up ? 1.35 : 1)
            .animation(.easeInOut(duration: 2).repeatForever(autoreverses: true), value: up)
            .onAppear { up = true }
    }
}
