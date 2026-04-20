import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class ProjectRegistryTests: XCTestCase {
    private let fileManager = FileManager.default

    func testSaveAndLoadRoundTripProducesValueEqualRegistry() throws {
        let root = try makeTemporaryDirectory(named: "project-registry-round-trip")
        defer { try? fileManager.removeItem(at: root) }

        let fileURL = try makeRegistryFileURL(in: root)
        let registry = ProjectRegistry(fileURL: fileURL)
        let alpha = try makeProject(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            name: "Alpha",
            monogram: "A",
            repoPath: "/tmp/alpha",
            bookmarkData: Data([0xAA]),
            lastOpenedAt: Date(timeIntervalSince1970: 1_713_720_000)
        )
        let beta = try makeProject(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            name: "Beta",
            monogram: "B",
            color: .customHex("#aabbcc"),
            repoPath: "/tmp/beta",
            bookmarkData: nil,
            lastOpenedAt: Date(timeIntervalSince1970: 1_713_730_000)
        )

        try registry.upsert(alpha)
        try registry.upsert(beta)
        try registry.save()

        let reloaded = ProjectRegistry(fileURL: fileURL)
        try reloaded.load()

        XCTAssertEqual(reloaded.projects, registry.projects)
    }

    func testLoadMissingFileClearsRegistryWithoutThrowing() throws {
        let root = try makeTemporaryDirectory(named: "project-registry-missing")
        defer { try? fileManager.removeItem(at: root) }

        let registry = ProjectRegistry(
            fileURL: try makeRegistryFileURL(in: root),
            projects: [UUID(): try makeProject()]
        )

        XCTAssertNoThrow(try registry.load())
        XCTAssertTrue(registry.projects.isEmpty)
    }

    func testLoadCorruptJSONThrowsSpecificErrorAndLeavesBytesUntouched() throws {
        let root = try makeTemporaryDirectory(named: "project-registry-corrupt")
        defer { try? fileManager.removeItem(at: root) }

        let fileURL = try makeRegistryFileURL(in: root)
        let corruptBytes = Data("{ definitely-not-json".utf8)
        try writeFixture(corruptBytes, to: fileURL)

        let existingProject = try makeProject()
        let registry = ProjectRegistry(fileURL: fileURL, projects: [existingProject.id: existingProject])

        XCTAssertThrowsError(try registry.load()) { error in
            XCTAssertEqual(error as? ProjectRegistryError, .corruptFile)
        }
        XCTAssertEqual(registry.projects, [existingProject.id: existingProject])
        XCTAssertEqual(try Data(contentsOf: fileURL), corruptBytes)
    }

    func testLoadFutureVersionThrowsIncompatibleFutureAndLeavesBytesUntouched() throws {
        let root = try makeTemporaryDirectory(named: "project-registry-future")
        defer { try? fileManager.removeItem(at: root) }

        let fileURL = try makeRegistryFileURL(in: root)
        let futureBytes = try makeRegistryData(version: ProjectRegistry.currentVersion + 1, projects: [makeProject()])
        try writeFixture(futureBytes, to: fileURL)

        let existingProject = try makeProject(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            name: "Loaded",
            monogram: "L",
            repoPath: "/tmp/loaded"
        )
        let registry = ProjectRegistry(fileURL: fileURL, projects: [existingProject.id: existingProject])

        XCTAssertThrowsError(try registry.load()) { error in
            XCTAssertEqual(error as? ProjectRegistryError, .incompatibleFuture)
        }
        XCTAssertEqual(registry.projects, [existingProject.id: existingProject])
        XCTAssertEqual(try Data(contentsOf: fileURL), futureBytes)
    }

    func testPartialWriteFailureLeavesExistingFileIntactAndThrows() throws {
        let root = try makeTemporaryDirectory(named: "project-registry-save-failure")
        defer { try? fileManager.removeItem(at: root) }

        let fileURL = try makeRegistryFileURL(in: root)
        let originalProject = try makeProject(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            name: "Original",
            monogram: "O",
            repoPath: "/tmp/original"
        )
        let baseline = ProjectRegistry(fileURL: fileURL)
        try baseline.upsert(originalProject)
        try baseline.save()
        let originalBytes = try Data(contentsOf: fileURL)

        let failingRegistry = ProjectRegistry(
            fileURL: fileURL,
            projects: [originalProject.id: originalProject],
            fileManager: FailingReplaceFileManager()
        )
        try failingRegistry.upsert(
            makeProject(
                id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                name: "Updated",
                monogram: "U",
                repoPath: "/tmp/updated"
            )
        )

        XCTAssertThrowsError(try failingRegistry.save()) { error in
            XCTAssertEqual(error as? ProjectRegistryError, .saveFailed)
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), originalBytes)
    }

    func testByCanonicalPathReturnsExpectedProjectAndNilForUnknownPath() throws {
        let root = try makeTemporaryDirectory(named: "project-registry-lookup")
        defer { try? fileManager.removeItem(at: root) }

        let project = try makeProject(
            id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
            name: "Lookup",
            monogram: "L",
            repoPath: "/tmp/lookup"
        )
        let registry = ProjectRegistry(fileURL: try makeRegistryFileURL(in: root))
        try registry.upsert(project)

        XCTAssertEqual(registry.byCanonicalPath("/tmp/lookup"), project)
        XCTAssertNil(registry.byCanonicalPath("/tmp/missing"))
    }

    func testUpsertBeyondMaximumProjectsThrowsRegistryFull() throws {
        let root = try makeTemporaryDirectory(named: "project-registry-full")
        defer { try? fileManager.removeItem(at: root) }

        let registry = ProjectRegistry(fileURL: try makeRegistryFileURL(in: root))
        for index in 0..<ProjectRegistry.maxProjects {
            try registry.upsert(
                makeProject(
                    id: UUID(),
                    name: "Project \(index)",
                    monogram: "P",
                    repoPath: "/tmp/project-\(index)"
                )
            )
        }

        XCTAssertThrowsError(
            try registry.upsert(
                makeProject(
                    id: UUID(),
                    name: "Overflow",
                    monogram: "O",
                    repoPath: "/tmp/overflow"
                )
            )
        ) { error in
            XCTAssertEqual(error as? ProjectRegistryError, .registryFull)
        }
    }

    func testUpsertRejectsBookmarksLargerThanEightKiB() throws {
        let root = try makeTemporaryDirectory(named: "project-registry-bookmark-limit")
        defer { try? fileManager.removeItem(at: root) }

        let registry = ProjectRegistry(fileURL: try makeRegistryFileURL(in: root))

        XCTAssertThrowsError(
            try registry.upsert(
                makeProject(
                    bookmarkData: Data(repeating: 0xFF, count: ProjectRegistry.maxBookmarkSize + 1)
                )
            )
        ) { error in
            XCTAssertEqual(error as? ProjectRegistryError, .bookmarkTooLarge)
        }
    }

    func testLoadIgnoresUnknownPerProjectServiceConfigKeys() throws {
        let root = try makeTemporaryDirectory(named: "project-registry-service-config")
        defer { try? fileManager.removeItem(at: root) }

        let fileURL = try makeRegistryFileURL(in: root)
        let project = try makeProject()
        var object = try makeRegistryJSONObject(projects: [project])
        guard var projects = object["projects"] as? [[String: Any]] else {
            return XCTFail("Missing projects array")
        }
        projects[0]["serviceConfig"] = [
            "provider": "example",
            "model": "phase-c-placeholder",
        ]
        object["projects"] = projects
        try writeFixture(try makeJSONData(from: object), to: fileURL)

        let registry = ProjectRegistry(fileURL: fileURL)
        XCTAssertNoThrow(try registry.load())
        XCTAssertEqual(registry.projects, [project.id: project])

        try registry.save()
        let persistedString = try XCTUnwrap(String(data: Data(contentsOf: fileURL), encoding: .utf8))
        XCTAssertFalse(persistedString.contains("serviceConfig"))
    }

    func testLoadIgnoresUnknownTopLevelKeys() throws {
        let root = try makeTemporaryDirectory(named: "project-registry-top-level")
        defer { try? fileManager.removeItem(at: root) }

        let fileURL = try makeRegistryFileURL(in: root)
        let project = try makeProject()
        var object = try makeRegistryJSONObject(projects: [project])
        object["futureTopLevel"] = [
            "enabled": true,
            "schema": 99,
        ]
        try writeFixture(try makeJSONData(from: object), to: fileURL)

        let registry = ProjectRegistry(fileURL: fileURL)
        XCTAssertNoThrow(try registry.load())
        XCTAssertEqual(registry.projects, [project.id: project])

        try registry.save()
        let persistedString = try XCTUnwrap(String(data: Data(contentsOf: fileURL), encoding: .utf8))
        XCTAssertFalse(persistedString.contains("futureTopLevel"))
    }

    private func makeTemporaryDirectory(named prefix: String) throws -> URL {
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
        return directoryURL
    }

    private func makeRegistryFileURL(in root: URL) throws -> URL {
        try XCTUnwrap(SessionPersistenceStore.projectsRegistryFileURL(appSupportDirectory: root))
    }

    private func writeFixture(_ data: Data, to fileURL: URL) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try data.write(to: fileURL)
    }

    private func makeProject(
        id: UUID = UUID(uuidString: "D9B45AB0-0A5F-4A0F-B93E-6E0A4A6C6B4A")!,
        name: String = "cmux-ex",
        monogram: String = "C",
        color: ProjectColor = .palette(.green),
        repoPath: String = "/Users/user/projects/cmux-ex",
        bookmarkData: Data? = Data([0xCA, 0xFE]),
        lastOpenedAt: Date = Date(timeIntervalSince1970: 1_713_720_000)
    ) throws -> Project {
        try Project(
            id: id,
            name: name,
            monogram: monogram,
            color: color,
            repoPath: repoPath,
            bookmarkData: bookmarkData,
            lastOpenedAt: lastOpenedAt
        )
    }

    private func makeRegistryJSONObject(
        version: Int = ProjectRegistry.currentVersion,
        projects: [Project]
    ) throws -> [String: Any] {
        let data = try makeRegistryData(version: version, projects: projects)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func makeRegistryData(
        version: Int = ProjectRegistry.currentVersion,
        projects: [Project]
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(ProjectRegistryFixture(version: version, projects: projects))
    }

    private func makeJSONData(from object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

private struct ProjectRegistryFixture: Codable {
    let version: Int
    let projects: [Project]
}

private final class FailingReplaceFileManager: AtomicFilePersistenceManaging {
    private let base = FileManager.default

    func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]?
    ) throws {
        try base.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }

    func fileExists(atPath path: String) -> Bool {
        base.fileExists(atPath: path)
    }

    func moveItem(at srcURL: URL, to dstURL: URL) throws {
        try base.moveItem(at: srcURL, to: dstURL)
    }

    func removeItem(at url: URL) throws {
        try base.removeItem(at: url)
    }

    func replaceItem(at originalURL: URL, withItemAt newURL: URL) throws -> URL? {
        throw CocoaError(.fileWriteUnknown)
    }
}
