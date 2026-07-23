// Local price table for the KPI-10 spend estimate (§2). Approximate by
// design — OpenRouter is the billing truth; this keeps the Settings spend
// line honest without a network call. Unknown models estimate as nil.
import Foundation

public enum ModelPricing {
    /// USD per 1M tokens (input, output).
    private static let table: [String: (input: Double, output: Double)] = [
        "google/gemini-2.5-flash": (0.30, 2.50),
        "anthropic/claude-sonnet-4.6": (3.00, 15.00),
        "bge-m3": (0.02, 0.0),
        "baai/bge-m3": (0.02, 0.0),
    ]

    public static func estimate(model: String, usage: AiUsage) -> Double? {
        guard let price = table[model.lowercased()] else { return nil }
        return Double(usage.promptTokens) / 1_000_000 * price.input
            + Double(usage.completionTokens) / 1_000_000 * price.output
    }
}
