import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class ProjectDuplicateRegistryTests: XCTestCase {
    func testOpenThenCloseClearsEntryAndSubsequentOpenSucceeds() {
        let registry = ProjectDuplicateRegistry()
        let canonicalPath = "/Users/tester/projects/cmux-ex"
        let firstWindow = NSObject()
        let secondWindow = NSObject()
        let firstLocation = ProjectDuplicateRegistry.Location(
            windowId: ObjectIdentifier(firstWindow),
            projectId: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        )
        let secondLocation = ProjectDuplicateRegistry.Location(
            windowId: ObjectIdentifier(secondWindow),
            projectId: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        )

        XCTAssertEqual(registry.open(canonicalPath: canonicalPath, location: firstLocation), .opened)
        XCTAssertEqual(registry.location(forCanonicalPath: canonicalPath), firstLocation)

        registry.close(canonicalPath: canonicalPath, windowId: firstLocation.windowId)

        XCTAssertNil(registry.location(forCanonicalPath: canonicalPath))
        XCTAssertEqual(registry.open(canonicalPath: canonicalPath, location: secondLocation), .opened)
        XCTAssertEqual(registry.location(forCanonicalPath: canonicalPath), secondLocation)
    }

    func testSecondOpenFromDifferentWindowConflictsWithOriginalLocation() {
        let registry = ProjectDuplicateRegistry()
        let canonicalPath = "/Users/tester/projects/cmux-ex"
        let firstWindow = NSObject()
        let secondWindow = NSObject()
        let originalLocation = ProjectDuplicateRegistry.Location(
            windowId: ObjectIdentifier(firstWindow),
            projectId: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        )
        let conflictingLocation = ProjectDuplicateRegistry.Location(
            windowId: ObjectIdentifier(secondWindow),
            projectId: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        )

        XCTAssertEqual(registry.open(canonicalPath: canonicalPath, location: originalLocation), .opened)
        let result = registry.open(canonicalPath: canonicalPath, location: conflictingLocation)

        guard case let .conflict(conflictLocation) = result else {
            return XCTFail("Expected a conflict for a duplicate path in a different window.")
        }

        let roundTrippedWindowId: ObjectIdentifier = genericIdentity(conflictLocation.windowId)

        XCTAssertTrue(type(of: roundTrippedWindowId) == ObjectIdentifier.self)
        XCTAssertEqual(roundTrippedWindowId, originalLocation.windowId)
        XCTAssertEqual(conflictLocation, originalLocation)
        XCTAssertEqual(registry.location(forCanonicalPath: canonicalPath), originalLocation)
    }

    func testDifferentCanonicalPathsCanOpenFromSameWindow() {
        let registry = ProjectDuplicateRegistry()
        let window = NSObject()
        let windowId = ObjectIdentifier(window)
        let firstLocation = ProjectDuplicateRegistry.Location(
            windowId: windowId,
            projectId: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        )
        let secondLocation = ProjectDuplicateRegistry.Location(
            windowId: windowId,
            projectId: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        )

        XCTAssertEqual(
            registry.open(canonicalPath: "/Users/tester/projects/cmux-ex", location: firstLocation),
            .opened
        )
        XCTAssertEqual(
            registry.open(canonicalPath: "/Users/tester/projects/ghostty", location: secondLocation),
            .opened
        )
        XCTAssertEqual(
            registry.location(forCanonicalPath: "/Users/tester/projects/cmux-ex"),
            firstLocation
        )
        XCTAssertEqual(
            registry.location(forCanonicalPath: "/Users/tester/projects/ghostty"),
            secondLocation
        )
    }

    func testSameWindowReopenSamePathUpdatesLocation() {
        let registry = ProjectDuplicateRegistry()
        let canonicalPath = "/Users/tester/projects/cmux-ex"
        let window = NSObject()
        let windowId = ObjectIdentifier(window)
        let originalLocation = ProjectDuplicateRegistry.Location(
            windowId: windowId,
            projectId: UUID(uuidString: "67676767-6767-6767-6767-676767676767")!
        )
        let updatedLocation = ProjectDuplicateRegistry.Location(
            windowId: windowId,
            projectId: UUID(uuidString: "78787878-7878-7878-7878-787878787878")!
        )

        XCTAssertEqual(registry.open(canonicalPath: canonicalPath, location: originalLocation), .opened)
        XCTAssertEqual(registry.open(canonicalPath: canonicalPath, location: updatedLocation), .opened)
        XCTAssertEqual(registry.location(forCanonicalPath: canonicalPath), updatedLocation)
    }

    func testCloseOnUnknownPathIsNoOp() {
        let registry = ProjectDuplicateRegistry()
        let window = NSObject()

        XCTAssertNoThrow(
            registry.close(
                canonicalPath: "/Users/tester/projects/not-open",
                windowId: ObjectIdentifier(window)
            )
        )
        XCTAssertNil(registry.location(forCanonicalPath: "/Users/tester/projects/not-open"))
    }

    func testMainActorSerializedConcurrentOpenBatchLetsFirstWin() async {
        let registry = ProjectDuplicateRegistry()
        let canonicalPath = "/Users/tester/projects/cmux-ex"
        let firstWindow = NSObject()
        let secondWindow = NSObject()
        let firstLocation = ProjectDuplicateRegistry.Location(
            windowId: ObjectIdentifier(firstWindow),
            projectId: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
        )
        let secondLocation = ProjectDuplicateRegistry.Location(
            windowId: ObjectIdentifier(secondWindow),
            projectId: UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
        )

        let results = await MainActor.run { () -> [ProjectDuplicateRegistry.OpenResult] in
            let batch: [() -> ProjectDuplicateRegistry.OpenResult] = [
                { registry.open(canonicalPath: canonicalPath, location: firstLocation) },
                { registry.open(canonicalPath: canonicalPath, location: secondLocation) },
            ]
            return batch.map { $0() }
        }

        XCTAssertEqual(results, [.opened, .conflict(firstLocation)])
        XCTAssertEqual(registry.location(forCanonicalPath: canonicalPath), firstLocation)
    }

    private func genericIdentity<T>(_ value: T) -> T {
        value
    }
}
