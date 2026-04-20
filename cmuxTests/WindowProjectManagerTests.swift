import AppKit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class WindowProjectManagerTests: XCTestCase {
    private final class WeakBox<T: AnyObject> {
        weak var value: T?

        init(_ value: T?) {
            self.value = value
        }
    }

    func testOpenProjectAtEndAppendsToOpenProjectIds() throws {
        let manager = makeManager()
        let first = try makeProject(id: "11111111-1111-1111-1111-111111111111")
        let second = try makeProject(id: "22222222-2222-2222-2222-222222222222")

        try manager.openProject(first, inserting: .atEnd)
        try manager.openProject(second, inserting: .atEnd)

        XCTAssertEqual(manager.openProjectIds, [first.id, second.id])
        XCTAssertEqual(manager.activeProjectId, second.id)
    }

    func testOpenProjectAfterActiveInsertsAfterActiveProject() throws {
        let manager = makeManager()
        let first = try makeProject(id: "33333333-3333-3333-3333-333333333333")
        let second = try makeProject(id: "44444444-4444-4444-4444-444444444444")
        let third = try makeProject(id: "55555555-5555-5555-5555-555555555555")

        try manager.openProject(first, inserting: .atEnd)
        try manager.openProject(second, inserting: .atEnd)
        try manager.selectProject(first.id)
        try manager.openProject(third, inserting: .afterActive)

        XCTAssertEqual(manager.openProjectIds, [first.id, third.id, second.id])
        XCTAssertEqual(manager.activeProjectId, third.id)
    }

    func testOpenProjectAfterActiveAppendsWhenThereIsNoActiveProject() throws {
        let manager = makeManager()
        let first = try makeProject(id: "66666666-6666-6666-6666-666666666666")
        let second = try makeProject(id: "77777777-7777-7777-7777-777777777777")

        try manager.openProject(first, inserting: .atEnd)
        manager.activeProjectId = nil

        try manager.openProject(second, inserting: .afterActive)

        XCTAssertEqual(manager.openProjectIds, [first.id, second.id])
        XCTAssertEqual(manager.activeProjectId, second.id)
    }

    func testOpenProjectAtStartPrependsToOpenProjectIds() throws {
        let manager = makeManager()
        let first = try makeProject(id: "88888888-8888-8888-8888-888888888888")
        let second = try makeProject(id: "99999999-9999-9999-9999-999999999999")

        try manager.openProject(first, inserting: .atEnd)
        try manager.openProject(second, inserting: .atStart)

        XCTAssertEqual(manager.openProjectIds, [second.id, first.id])
        XCTAssertEqual(manager.activeProjectId, second.id)
    }

    func testCloseActiveProjectSelectsNextProjectInOrder() throws {
        let manager = makeManager()
        let first = try makeProject(id: "AAAAAAA1-AAAA-AAAA-AAAA-AAAAAAAAAAA1")
        let second = try makeProject(id: "AAAAAAA2-AAAA-AAAA-AAAA-AAAAAAAAAAA2")
        let third = try makeProject(id: "AAAAAAA3-AAAA-AAAA-AAAA-AAAAAAAAAAA3")

        try manager.openProject(first, inserting: .atEnd)
        try manager.openProject(second, inserting: .atEnd)
        try manager.openProject(third, inserting: .atEnd)
        try manager.selectProject(second.id)

        try manager.closeProject(second.id)

        XCTAssertEqual(manager.openProjectIds, [first.id, third.id])
        XCTAssertEqual(manager.activeProjectId, third.id)
    }

    func testCloseLastActiveProjectSelectsPreviousProject() throws {
        let manager = makeManager()
        let first = try makeProject(id: "BBBBBBB1-BBBB-BBBB-BBBB-BBBBBBBBBBB1")
        let second = try makeProject(id: "BBBBBBB2-BBBB-BBBB-BBBB-BBBBBBBBBBB2")

        try manager.openProject(first, inserting: .atEnd)
        try manager.openProject(second, inserting: .atEnd)

        try manager.closeProject(second.id)

        XCTAssertEqual(manager.openProjectIds, [first.id])
        XCTAssertEqual(manager.activeProjectId, first.id)
    }

    func testCloseOnlyActiveProjectClearsActiveProject() throws {
        let manager = makeManager()
        let project = try makeProject(id: "CCCCCCC1-CCCC-CCCC-CCCC-CCCCCCCCCCC1")

        try manager.openProject(project, inserting: .atEnd)
        try manager.closeProject(project.id)

        XCTAssertTrue(manager.openProjectIds.isEmpty)
        XCTAssertNil(manager.activeProjectId)
        XCTAssertNil(manager.activeContainer)
    }

    func testCloseNonActiveProjectLeavesActiveProjectUnchanged() throws {
        let manager = makeManager()
        let first = try makeProject(id: "DDDDDDD1-DDDD-DDDD-DDDD-DDDDDDDDDDD1")
        let second = try makeProject(id: "DDDDDDD2-DDDD-DDDD-DDDD-DDDDDDDDDDD2")
        let third = try makeProject(id: "DDDDDDD3-DDDD-DDDD-DDDD-DDDDDDDDDDD3")

        try manager.openProject(first, inserting: .atEnd)
        try manager.openProject(second, inserting: .atEnd)
        try manager.openProject(third, inserting: .atEnd)
        try manager.selectProject(second.id)

        try manager.closeProject(first.id)

        XCTAssertEqual(manager.openProjectIds, [second.id, third.id])
        XCTAssertEqual(manager.activeProjectId, second.id)
    }

    func testSelectProjectForMissingIdThrows() throws {
        let manager = makeManager()
        let missingId = UUID(uuidString: "EEEEEEE1-EEEE-EEEE-EEEE-EEEEEEEEEEE1")!

        XCTAssertThrowsError(try manager.selectProject(missingId)) { error in
            XCTAssertEqual(error as? WindowProjectManagerError, .projectNotOpen(missingId))
        }
    }

    func testReorderReplacesOrderAndRejectsNonPermutation() throws {
        let manager = makeManager()
        let first = try makeProject(id: "F0F0F0F1-F0F0-F0F0-F0F0-F0F0F0F0F0F1")
        let second = try makeProject(id: "F0F0F0F2-F0F0-F0F0-F0F0-F0F0F0F0F0F2")
        let third = try makeProject(id: "F0F0F0F3-F0F0-F0F0-F0F0-F0F0F0F0F0F3")

        try manager.openProject(first, inserting: .atEnd)
        try manager.openProject(second, inserting: .atEnd)
        try manager.openProject(third, inserting: .atEnd)
        try manager.selectProject(second.id)

        try manager.reorder(projectIds: [third.id, first.id, second.id])

        XCTAssertEqual(manager.openProjectIds, [third.id, first.id, second.id])
        XCTAssertEqual(manager.activeProjectId, second.id)

        XCTAssertThrowsError(try manager.reorder(projectIds: [first.id, first.id, third.id])) { error in
            XCTAssertEqual(error as? WindowProjectManagerError, .invalidProjectOrder)
        }
    }

    func testContainersRetainContainerForProjectLifetime() throws {
        let manager = makeManager()
        let first = try makeProject(id: "ABABABA1-ABAB-ABAB-ABAB-ABABABABABA1")
        let second = try makeProject(id: "ABABABA2-ABAB-ABAB-ABAB-ABABABABABA2")

        try manager.openProject(first, inserting: .atEnd)
        try manager.openProject(second, inserting: .atEnd)

        let firstContainer = WeakBox(manager.containers[first.id])

        XCTAssertNotNil(firstContainer.value)
        XCTAssertTrue(manager.containers[first.id] === firstContainer.value)

        try manager.reorder(projectIds: [second.id, first.id])

        XCTAssertTrue(manager.containers[first.id] === firstContainer.value)

        try manager.closeProject(first.id)

        XCTAssertNil(manager.containers[first.id])
        XCTAssertNil(firstContainer.value)
    }

    func testWindowIdentityRoundTripsAsObjectIdentifier() {
        let ownerView = NSView(frame: .zero)
        let expectedIdentity = ObjectIdentifier(ownerView)
        let manager = WindowProjectManager(owner: ownerView)

        let roundTrippedIdentity: ObjectIdentifier = genericIdentity(manager.windowIdentity)

        XCTAssertTrue(type(of: roundTrippedIdentity) == ObjectIdentifier.self)
        XCTAssertEqual(roundTrippedIdentity, expectedIdentity)
    }

    private func makeManager() -> WindowProjectManager {
        WindowProjectManager(owner: NSView(frame: .zero))
    }

    private func makeProject(id: String) throws -> Project {
        try Project(
            id: UUID(uuidString: id)!,
            name: "cmux-ex",
            monogram: "C",
            color: .palette(.green),
            repoPath: "/Users/user/projects/cmux-ex",
            bookmarkData: nil,
            lastOpenedAt: Date(timeIntervalSince1970: 1_713_720_000)
        )
    }

    private func genericIdentity<T>(_ value: T) -> T {
        value
    }
}
