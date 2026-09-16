import XCTest
@testable import Fx

final class SessionArtifactsTests: XCTestCase {
    func testArtifactDirectoryScanIsShallowHiddenAndDirectoryFirst() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("fx-artifacts-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: root.appendingPathComponent("Folder 2"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: root.appendingPathComponent("Folder 10"), withIntermediateDirectories: true)
        XCTAssertTrue(fileManager.createFile(atPath: root.appendingPathComponent("artifact.txt").path, contents: Data()))
        XCTAssertTrue(fileManager.createFile(atPath: root.appendingPathComponent(".hidden").path, contents: Data()))
        XCTAssertTrue(fileManager.createFile(
            atPath: root.appendingPathComponent("Folder 10/metadata.json").path,
            contents: Data("{}".utf8)
        ))

        let entries = try await SessionArtifactTreeModel.scanDirectory(root)

        XCTAssertEqual(entries.map(\.name), ["Folder 2", "Folder 10", "artifact.txt"])
        XCTAssertEqual(entries.map(\.isDirectory), [true, true, false])

        let filtered = try await SessionArtifactTreeModel.scanDirectory(
            root,
            excluding: [root.appendingPathComponent("Folder 2").standardizedFileURL.path]
        )
        XCTAssertEqual(filtered.map(\.name), ["Folder 10", "artifact.txt"])

        let withoutManagedItems = try await SessionArtifactTreeModel.scanDirectory(
            root,
            excludingManagedItemDirectories: true
        )
        XCTAssertEqual(withoutManagedItems.map(\.name), ["Folder 2", "artifact.txt"])
    }
}
