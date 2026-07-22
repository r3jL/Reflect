import XCTest
@testable import ReflectMedia

final class ReflectMediaTests: XCTestCase {
    func testModuleLoads() {
        XCTAssertEqual(ReflectMediaInfo.version, "0.1.0")
    }
}
