import Foundation
import XCTest

@testable import ReflectAI

final class OpenRouterProviderTests: XCTestCase {
    private struct Extraction: Codable, Equatable, Sendable {
        let themes: [String]
        let tags: [String]
    }

    private func makeProvider(key: String? = "sk-or-test") -> OpenRouterProvider {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return OpenRouterProvider(
            keyProvider: { key },
            session: URLSession(configuration: config))
    }

    override func tearDown() {
        StubURLProtocol.handler = nil
        StubURLProtocol.requests = []
    }

    // MARK: - Happy paths

    func testStructuredChatDecodesAndReportsUsage() async throws {
        StubURLProtocol.respond(
            status: 200,
            json: """
            {"choices":[{"message":{"content":"{\\"themes\\":[\\"beginnings\\"],\\"tags\\":[\\"studio\\"]}"}}],
             "usage":{"prompt_tokens":120,"completion_tokens":40}}
            """)

        let provider = makeProvider()
        let (out, usage) = try await provider.structuredChat(
            model: "google/gemini-2.5-flash",
            system: "extract", user: "body text", maxTokens: 500,
            as: Extraction.self)

        XCTAssertEqual(out, Extraction(themes: ["beginnings"], tags: ["studio"]))
        XCTAssertEqual(usage, AiUsage(promptTokens: 120, completionTokens: 40))

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-or-test")
        let body = try XCTUnwrap(StubURLProtocol.body(of: request))
        XCTAssertTrue(body.contains("\"model\":\"google\\/gemini-2.5-flash\"")
            || body.contains("\"model\":\"google/gemini-2.5-flash\""))
        XCTAssertTrue(body.contains("json_object"))
    }

    func testCodeFencedContentStillDecodes() async throws {
        StubURLProtocol.respond(
            status: 200,
            json: """
            {"choices":[{"message":{"content":"```json\\n{\\"themes\\":[],\\"tags\\":[]}\\n```"}}],
             "usage":{"prompt_tokens":10,"completion_tokens":5}}
            """)
        let (out, _) = try await makeProvider().structuredChat(
            model: "m", system: "s", user: "u", maxTokens: 100, as: Extraction.self)
        XCTAssertEqual(out, Extraction(themes: [], tags: []))
    }

    func testSchemaMismatchRetriesOnceThenSucceeds() async throws {
        var call = 0
        StubURLProtocol.handler = { _ in
            call += 1
            let content = call == 1
                ? "not json at all"
                : "{\\\"themes\\\":[\\\"x\\\"],\\\"tags\\\":[]}"
            let json = """
            {"choices":[{"message":{"content":"\(content)"}}],
             "usage":{"prompt_tokens":10,"completion_tokens":5}}
            """
            return (200, Data(json.utf8))
        }
        let (out, usage) = try await makeProvider().structuredChat(
            model: "m", system: "s", user: "u", maxTokens: 100, as: Extraction.self)
        XCTAssertEqual(call, 2)
        XCTAssertEqual(out.themes, ["x"])
        XCTAssertEqual(usage.promptTokens, 20, "usage sums across the retry")

        // The corrective retry tells the model what went wrong.
        let secondBody = try XCTUnwrap(StubURLProtocol.body(of: StubURLProtocol.requests[1]))
        XCTAssertTrue(secondBody.contains("previous response was not valid"))
    }

    func testSchemaMismatchTwiceFails() async throws {
        StubURLProtocol.respond(
            status: 200,
            json: """
            {"choices":[{"message":{"content":"still not json"}}],
             "usage":{"prompt_tokens":1,"completion_tokens":1}}
            """)
        do {
            _ = try await makeProvider().structuredChat(
                model: "m", system: "s", user: "u", maxTokens: 100, as: Extraction.self)
            XCTFail("expected schema error")
        } catch let error as AiError {
            guard case .schema = error else {
                return XCTFail("expected .schema, got \(error)")
            }
            XCTAssertFalse(error.isRetryable)
        }
    }

    func testEmbeddingsRoundTrip() async throws {
        StubURLProtocol.respond(
            status: 200,
            json: """
            {"data":[{"index":1,"embedding":[0.5,0.25]},{"index":0,"embedding":[1.0,2.0]}],
             "usage":{"prompt_tokens":9,"completion_tokens":0}}
            """)
        let (vectors, usage) = try await makeProvider().embed(
            model: "baai/bge-m3", texts: ["a", "b"])
        XCTAssertEqual(vectors, [[1.0, 2.0], [0.5, 0.25]], "sorted by index")
        XCTAssertEqual(usage.promptTokens, 9)
    }

    // MARK: - Error taxonomy

    func testMissingKeyFailsWithoutNetwork() async {
        StubURLProtocol.respond(status: 200, json: "{}")
        do {
            _ = try await makeProvider(key: nil).embed(model: "m", texts: ["x"])
            XCTFail()
        } catch let error as AiError {
            XCTAssertEqual(error, .notConfigured)
            XCTAssertTrue(StubURLProtocol.requests.isEmpty, "no request may be sent")
        } catch { XCTFail() }
    }

    func testAuthAndRateLimitAndServerErrorsClassified() async throws {
        for (status, expectRetryable): (Int, Bool) in [(401, false), (429, true), (503, true)] {
            StubURLProtocol.respond(status: status, json: "{\"error\":\"x\"}")
            do {
                _ = try await makeProvider().embed(model: "m", texts: ["x"])
                XCTFail("expected throw for \(status)")
            } catch let error as AiError {
                XCTAssertEqual(error.isRetryable, expectRetryable, "status \(status)")
                if status == 401 { XCTAssertEqual(error, .auth) }
            }
        }
    }

    // MARK: - Pricing

    func testPricingEstimates() {
        let usage = AiUsage(promptTokens: 1_000_000, completionTokens: 1_000_000)
        XCTAssertEqual(
            ModelPricing.estimate(model: "google/gemini-2.5-flash", usage: usage)!,
            2.80, accuracy: 0.001)
        XCTAssertNil(ModelPricing.estimate(model: "someone/unknown", usage: usage))
    }
}

// MARK: - Stub transport

final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    static func respond(status: Int, json: String) {
        handler = { _ in (status, Data(json.utf8)) }
        requests = []
    }

    static func body(of request: URLRequest) -> String? {
        if let body = request.httpBody { return String(data: body, encoding: .utf8) }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return String(data: data, encoding: .utf8)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, data) = handler(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
