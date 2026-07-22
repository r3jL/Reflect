import XCTest
@testable import ReflectCore

final class ReflectCoreTests: XCTestCase {
    func testModuleLoads() {
        XCTAssertEqual(ReflectCoreInfo.version, "0.1.0")
    }
}
