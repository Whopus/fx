import XCTest

final class EngineeringTests: XCTestCase {
    @MainActor
    func testEngineeringRegressions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FxEngineering-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try await EngineeringChecks.run(in: root)
    }
}
