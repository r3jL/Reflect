// Settings (FR-013/014), reachable via ⌘,. Non-secret values persist in
// the settings table; the OpenRouter key goes to the Keychain only.
import ReflectCore
import SwiftUI

@Observable
@MainActor
final class SettingsModel {
    private let settings = AppServices.settings

    var aiEnabled = false
    var extractionModel = "google/gemini-2.5-flash"
    var reflectionModel = "anthropic/claude-sonnet-4.6"
    var sttModel = "large-v3-turbo"
    var appLock = false

    var keyDraft = ""
    private(set) var keyStored = false
    private(set) var monthCalls = 0
    private(set) var monthCost: Double?

    func load() {
        let month = String(DBFormat.entryDate(.now).prefix(7))
        if let total = try? AppServices.usage.monthTotal(month) {
            monthCalls = total.calls
            monthCost = total.costEstimate
        }
        aiEnabled = (try? settings.getBool(.aiEnabled)) ?? false
        extractionModel =
            (try? settings.get(.modelExtraction)) ?? "google/gemini-2.5-flash"
        reflectionModel =
            (try? settings.get(.modelReflection)) ?? "anthropic/claude-sonnet-4.6"
        sttModel = (try? settings.get(.sttModel)) ?? "large-v3-turbo"
        appLock = (try? settings.getBool(.appLock)) ?? false
        keyStored = KeychainStore.cachedGet(account: KeychainStore.openRouterKeyAccount) != nil
    }

    func persist() {
        try? settings.setBool(.aiEnabled, aiEnabled)
        try? settings.set(.modelExtraction, extractionModel)
        try? settings.set(.modelReflection, reflectionModel)
        try? settings.set(.modelEmbedding, "bge-m3")
        try? settings.set(.sttModel, sttModel)
        try? settings.setBool(.appLock, appLock)
    }

    func saveKey() {
        let trimmed = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? KeychainStore.set(trimmed, account: KeychainStore.openRouterKeyAccount)
        keyDraft = ""
        keyStored = true
    }

    func removeKey() {
        KeychainStore.delete(account: KeychainStore.openRouterKeyAccount)
        keyStored = false
    }
}

struct SettingsView: View {
    @State private var model = SettingsModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 34) {
            section("Intelligence") {
                themedToggle("Enable AI enrichment", isOn: $model.aiEnabled)
                Text("Extraction, reflection and embeddings run only when enabled and a key is set. The journal is fully usable without it.")
                    .font(Typography.sans(11))
                    .foregroundStyle(Theme.ink4)
            }

            section("OpenRouter API key") {
                HStack(spacing: 10) {
                    SecureField("sk-or-…", text: $model.keyDraft)
                        .textFieldStyle(.plain)
                        .font(Typography.sans(13))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Theme.hair2, lineWidth: 1))
                    Button("Save") { model.saveKey() }
                        .buttonStyle(.plain)
                        .font(Typography.sans(12, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
                HStack(spacing: 8) {
                    Circle()
                        .fill(model.keyStored ? Theme.Mood.calm.dot : Theme.ink4)
                        .frame(width: 6, height: 6)
                    Text(model.keyStored
                        ? "A key is stored in the macOS Keychain."
                        : "No key stored.")
                        .font(Typography.sans(11))
                        .foregroundStyle(Theme.ink3)
                    if model.keyStored {
                        Button("Remove") { model.removeKey() }
                            .buttonStyle(.plain)
                            .font(Typography.sans(11))
                            .foregroundStyle(Theme.ink4)
                    }
                }
            }

            section("Models") {
                labeledField("Extraction", text: $model.extractionModel)
                labeledField("Reflection", text: $model.reflectionModel)
                HStack(spacing: 10) {
                    Text("Embeddings")
                        .font(Typography.sans(12))
                        .foregroundStyle(Theme.ink3)
                        .frame(width: 90, alignment: .leading)
                    Text("bge-m3 · 1024")
                        .font(Typography.sans(12))
                        .foregroundStyle(Theme.ink4)
                }
            }

            section("This month") {
                HStack(spacing: 8) {
                    Text("\(model.monthCalls) AI calls")
                        .font(Typography.sans(12))
                        .foregroundStyle(Theme.ink2)
                    Circle().fill(Theme.ink4).frame(width: 3, height: 3)
                    Text(model.monthCost.map {
                        String(format: "≈ $%.4f", $0)
                    } ?? "≈ $0")
                        .font(Typography.sans(12))
                        .foregroundStyle(Theme.ink2)
                }
                Text("Local estimate from token counts; your OpenRouter dashboard is the billing truth.")
                    .font(Typography.sans(11))
                    .foregroundStyle(Theme.ink4)
            }

            section("Voice") {
                Picker("", selection: $model.sttModel) {
                    Text("large-v3-turbo (accurate)").tag("large-v3-turbo")
                    Text("small (faster, smaller)").tag("small")
                    Text("base (fastest)").tag("base")
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .font(Typography.sans(12))
            }

            section("Security") {
                themedToggle("Require Touch ID to open", isOn: $model.appLock)
                Text("Uses your device password as fallback. Takes effect at next launch.")
                    .font(Typography.sans(11))
                    .foregroundStyle(Theme.ink4)
            }
        }
        .padding(36)
        .frame(width: 480)
        .background(Theme.paper)
        .onAppear { model.load() }
        .onDisappear { model.persist() }
        .onChange(of: model.aiEnabled) { model.persist() }
        .onChange(of: model.extractionModel) { model.persist() }
        .onChange(of: model.reflectionModel) { model.persist() }
        .onChange(of: model.sttModel) { model.persist() }
        .onChange(of: model.appLock) { model.persist() }
    }

    // MARK: - Pieces

    private func section<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Kicker(text: title)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func themedToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(Typography.sans(13))
                .foregroundStyle(Theme.ink)
        }
        .toggleStyle(.switch)
        .tint(Theme.accent)
    }

    private func labeledField(_ label: String, text: Binding<String>) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(Typography.sans(12))
                .foregroundStyle(Theme.ink3)
                .frame(width: 90, alignment: .leading)
            TextField("", text: text)
                .textFieldStyle(.plain)
                .font(Typography.sans(12))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Theme.hair2, lineWidth: 1))
        }
    }
}
