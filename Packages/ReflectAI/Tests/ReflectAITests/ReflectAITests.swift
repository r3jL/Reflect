import XCTest
@testable import ReflectAI

final class ReflectAITests: XCTestCase {
    func testModuleLoads() {
        XCTAssertEqual(ReflectAIInfo.version, "0.1.0")
    }
}
