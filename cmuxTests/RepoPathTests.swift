import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class RepoPathTests: XCTestCase {
    private let fileManager = FileManager.default

    func testCanonicalThrowsEmptyForEmptyOrWhitespaceInput() {
        XCTAssertThrowsError(try RepoPath.canonical("")) { error in
            XCTAssertEqual(error as? RepoPathError, .empty)
        }

        XCTAssertThrowsError(try RepoPath.canonical("  \n\t  ")) { error in
            XCTAssertEqual(error as? RepoPathError, .empty)
        }
    }

    func testCanonicalNormalizesTrailingSlash() throws {
        let root = try makeTemporaryDirectory(named: "repo-path-trailing-slash")
        defer { try? fileManager.removeItem(at: root) }

        let result = try RepoPath.canonical(root.path + "/")

        XCTAssertEqual(result, root.path)
    }

    func testCanonicalResolvesSymlinkTarget() throws {
        let root = try makeTemporaryDirectory(named: "repo-path-symlink")
        defer { try? fileManager.removeItem(at: root) }

        let target = root.appendingPathComponent("Target", isDirectory: true)
        let link = root.appendingPathComponent("Link", isDirectory: true)
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: link, withDestinationURL: target)

        let result = try RepoPath.canonical(link.path)

        XCTAssertEqual(result, target.path)
    }

    func testCanonicalResolvesRelativePathAgainstCurrentWorkingDirectory() throws {
        let root = try makeTemporaryDirectory(named: "repo-path-relative")
        defer { try? fileManager.removeItem(at: root) }

        let child = root.appendingPathComponent("Child", isDirectory: true)
        try fileManager.createDirectory(at: child, withIntermediateDirectories: true)

        let originalWorkingDirectory = fileManager.currentDirectoryPath
        XCTAssertTrue(fileManager.changeCurrentDirectoryPath(root.path))
        defer { XCTAssertTrue(fileManager.changeCurrentDirectoryPath(originalWorkingDirectory)) }

        let result = try RepoPath.canonical("./Child")

        XCTAssertEqual(result, child.path)
    }

    func testCanonicalExpandsTildeToHomeDirectory() throws {
        let result = try RepoPath.canonical("~/")

        XCTAssertEqual(result, fileManager.homeDirectoryForCurrentUser.path)
    }

    func testCanonicalKeepsFilesystemCaseForExistingPath() throws {
        let root = try makeTemporaryDirectory(named: "repo-path-case")
        defer { try? fileManager.removeItem(at: root) }

        let actualDirectory = root.appendingPathComponent("MixedCase", isDirectory: true)
        try fileManager.createDirectory(at: actualDirectory, withIntermediateDirectories: true)

        // macOS paths are case-preserving even when lookups are case-insensitive.
        let differentlyCasedInput = root
            .appendingPathComponent("mixedcase", isDirectory: true)
            .path

        let result = try RepoPath.canonical(differentlyCasedInput)

        XCTAssertEqual(result, actualDirectory.path)
    }

    func testCanonicalNormalizesNonexistentAbsolutePathsWithoutFilesystemChecks() throws {
        let root = try makeTemporaryDirectory(named: "repo-path-missing")
        defer { try? fileManager.removeItem(at: root) }

        let expected = root.appendingPathComponent("Child", isDirectory: true)
        let raw = root
            .appendingPathComponent("Parent", isDirectory: true)
            .appendingPathComponent("..", isDirectory: true)
            .appendingPathComponent("Child", isDirectory: true)
            .path

        XCTAssertFalse(fileManager.fileExists(atPath: expected.path))

        let result = try RepoPath.canonical(raw)

        XCTAssertEqual(result, expected.path)
    }

    private func makeTemporaryDirectory(named prefix: String) throws -> URL {
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }
}
