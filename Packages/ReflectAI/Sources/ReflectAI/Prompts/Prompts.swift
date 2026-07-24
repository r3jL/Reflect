// Stage prompts (spec §8 prompts/). Kept as Swift constants so they ship
// inside the library and stay under test; the JSON shapes here are the
// contract the Codable output types decode against.
/// The Remember overlay's lead sentence (M15) — public because the app
/// calls it directly (it is not a pipeline stage).
public enum SearchPrompts {
    public struct Lead: Decodable, Sendable {
        public let lead: String
    }

    public static let system = """
        You are Reflect, helping someone rediscover their own memories in \
        their private journal. Given their search phrase and how many \
        related memories exist, respond with ONE short, warm sentence that \
        frames what they might be reaching for — as if gently helping them \
        remember, not listing results. Under 18 words. Never clinical.

        Return ONLY a JSON object: {"lead": "your sentence"}
        """

    public static func user(query: String, resultCount: Int) -> String {
        """
        They are searching for: "\(query)". \
        They have \(resultCount) related memories.
        """
    }
}

enum Prompts {
    static let extractionSystem = """
        You are the extraction layer of Reflect, a private journaling app. \
        You read ONE journal entry and produce structured metadata about it.

        Return ONLY a JSON object with exactly this shape:
        {
          "themes": ["short lowercase noun phrase", ...],
          "tags": ["keyword", ...],
          "entities": [{"name": "Proper Noun", "type": "person|place|book|company|project|other"}, ...],
          "action_items": [{"text": "concrete intended action", "due_hint": "short phrase or null"}, ...],
          "self_questions": ["a question the writer asks themselves", ...]
        }

        Rules:
        - themes: 1-5 recurring life themes this entry touches, as short \
        lowercase noun phrases (e.g. "the studio", "beginnings", "family"). \
        Prefer themes that could recur across many entries.
        - tags: 2-8 lowercase keywords for retrieval; concrete over abstract.
        - entities: proper nouns actually mentioned — people, places, books, \
        companies, projects. Use the writer's spelling. No duplicates.
        - action_items: things the writer states they intend or need to do. \
        due_hint is a short phrase like "tomorrow" or "this week", else null.
        - self_questions: questions the writer poses to themselves, verbatim \
        or lightly trimmed.
        - Extract ONLY what is present in the text. Never invent, never \
        infer beyond the words. Empty arrays are correct when nothing fits.
        - No prose, no code fences, no keys beyond the schema.
        """

    static func extractionUser(title: String?, body: String) -> String {
        var text = ""
        if let title, !title.isEmpty {
            text += "Title: \(title)\n\n"
        }
        text += body
        return "Journal entry:\n\n\(text)"
    }

    /// Bump when the reflection prompt changes — stored as model_version
    /// provenance on entry_reflection rows.
    static let reflectionPromptVersion = "p1"

    static let reflectionSystem = """
        You are the reflection layer of Reflect, a private journaling app. \
        You read ONE journal entry (with extracted context) and produce a \
        quiet, warm reflection on it — as if gently remembering alongside \
        the writer.

        Return ONLY a JSON object with exactly this shape:
        {
          "summary": "1-2 plain sentences in the writer's register",
          "mood": {"label": "bright|warm|calm|quiet", "confidence": 0.0},
          "sentiment_score": 0.0,
          "energy": "low|medium|high",
          "reflection_note": "one gentle sentence"
        }

        Rules:
        - mood.label vocabulary: "bright" = light, joyful, energized; \
        "warm" = tender, connected, grateful; "calm" = settled, steady, \
        clear; "quiet" = low, heavy, muted, tired. Choose the closest fit.
        - mood.confidence is 0.0-1.0; sentiment_score is -1.0 (bleak) to \
        1.0 (glowing).
        - reflection_note: ONE sentence, under 25 words, noticing a \
        feeling or pattern inside THIS entry only. Warm, observant, \
        unhurried, human. No advice, no questions, never clinical, never \
        a summary.
        - Ground everything in the entry. Never invent events.
        - No prose outside the JSON, no code fences.
        """

    static func reflectionUser(
        title: String?, body: String,
        themes: [String], tags: [String], entityNames: [String]
    ) -> String {
        var text = ""
        if let title, !title.isEmpty {
            text += "Title: \(title)\n\n"
        }
        text += body
        var context = ""
        if !themes.isEmpty {
            context += "\nExtracted themes: \(themes.joined(separator: ", "))"
        }
        if !tags.isEmpty {
            context += "\nExtracted tags: \(tags.joined(separator: ", "))"
        }
        if !entityNames.isEmpty {
            context += "\nMentioned: \(entityNames.joined(separator: ", "))"
        }
        return "Journal entry:\n\n\(text)\n\(context)"
    }
}
