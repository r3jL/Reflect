import Foundation
import XCTest

@testable import ReflectAI

final class OllamaProviderTests: XCTestCase {
    private struct Out: Codable, Equatable, Sendable {
        let themes: [String]
    }

    private func stubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func provider() -> OllamaProvider {
        OllamaProvider(
            rootURL: URL(string: "http://localhost:11434")!,
            session: stubbedSession())
    }

    override func tearDown() {
        StubURLProtocol.handler = nil
        StubURLProtocol.requests = []
    }

    // MARK: - Keyless local transport (DEC-P2-04)

    func testChatGoesToLocalV1WithoutAuthHeader() async throws {
        StubURLProtocol.respond(
            status: 200,
            json: """
            {"choices":[{"message":{"content":"{\\"themes\\":[\\"local\\"]}"}}],
             "usage":{"prompt_tokens":12,"completion_tokens":4}}
            """)
        let (out, usage) = try await provider().structuredChat(
            model: "qwen2.5:7b", system: "s", user: "u", maxTokens: 100,
            as: Out.self)

        XCTAssertEqual(out, Out(themes: ["local"]))
        XCTAssertEqual(usage.promptTokens, 12)
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(
            request.url?.absoluteString,
            "http://localhost:11434/v1/chat/completions")
        XCTAssertNil(
            request.value(forHTTPHeaderField: "Authorization"),
            "local transport must be keyless")
    }

    func testEmbeddingsGoToLocalV1() async throws {
        StubURLProtocol.respond(
            status: 200,
            json: """
            {"data":[{"index":0,"embedding":[0.25,0.5]}],
             "usage":{"prompt_tokens":3,"completion_tokens":0}}
            """)
        let (vectors, _) = try await provider().embed(model: "bge-m3", texts: ["x"])
        XCTAssertEqual(vectors, [[0.25, 0.5]])
        XCTAssertEqual(
            StubURLProtocol.requests.first?.url?.absoluteString,
            "http://localhost:11434/v1/embeddings")
    }

    // MARK: - Availability probe

    func testProbeUpdatesCachedAvailability() async {
        let provider = provider()
        XCTAssertFalse(provider.isAvailable, "pessimistic before first probe")

        StubURLProtocol.respond(status: 200, json: "Ollama is running")
        let up = await provider.probe()
        XCTAssertTrue(up)
        XCTAssertTrue(provider.isAvailable)

        StubURLProtocol.handler = nil  // transport now fails
        let down = await provider.probe()
        XCTAssertFalse(down)
        XCTAssertFalse(provider.isAvailable, "cache follows the probe")
    }

    // MARK: - Model listing

    func testListLocalModelsParsesTags() async throws {
        StubURLProtocol.respond(
            status: 200,
            json: """
            {"models":[{"name":"qwen2.5:7b"},{"name":"bge-m3:latest"}]}
            """)
        let models = try await provider().listLocalModels()
        XCTAssertEqual(models, ["bge-m3:latest", "qwen2.5:7b"])
        XCTAssertEqual(
            StubURLProtocol.requests.first?.url?.absoluteString,
            "http://localhost:11434/api/tags")
    }

    func testMalformedTagsPayloadIsSchemaError() async {
        StubURLProtocol.respond(status: 200, json: "{\"nope\": true}")
        do {
            _ = try await provider().listLocalModels()
            XCTFail("expected schema error")
        } catch let error as AiError {
            guard case .schema = error else { return XCTFail("\(error)") }
        } catch { XCTFail("\(error)") }
    }
}
