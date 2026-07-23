// Stage prompts (spec §8 prompts/). Kept as Swift constants so they ship
// inside the library and stay under test; the JSON shapes here are the
// contract the Codable output types decode against.
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
}
