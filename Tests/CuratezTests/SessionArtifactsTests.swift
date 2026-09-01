import XCTest
@testable import Curatez

final class SessionArtifactsTests: XCTestCase {
    func testArtifactDirectoryScanIsShallowHiddenAndDirectoryFirst() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("curatez-artifacts-\(UUID().uuidString)", isDirectory: true)
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

        let entries = try SessionArtifactTreeModel.scanDirectory(root)

        XCTAssertEqual(entries.map(\.name), ["Folder 2", "Folder 10", "artifact.txt"])
        XCTAssertEqual(entries.map(\.isDirectory), [true, true, false])

        let filtered = try SessionArtifactTreeModel.scanDirectory(
            root,
            excluding: [root.appendingPathComponent("Folder 2").standardizedFileURL.path]
        )
        XCTAssertEqual(filtered.map(\.name), ["Folder 10", "artifact.txt"])

        let withoutManagedItems = try SessionArtifactTreeModel.scanDirectory(
            root,
            excludingManagedItemDirectories: true
        )
        XCTAssertEqual(withoutManagedItems.map(\.name), ["Folder 2", "artifact.txt"])
    }
}
