import XCTest
@testable import ReflectSTT

final class ReflectSTTTests: XCTestCase {
    func testModuleLoads() {
        XCTAssertEqual(ReflectSTTInfo.version, "0.1.0")
    }
}
