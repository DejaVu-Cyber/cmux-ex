import Foundation

/// In-memory canonical-path registry used for cross-window duplicate-open checks.
/// `AppDelegate` owns the process-wide instance via `shared()` once the open flow
/// is wired in a later task.
@MainActor
final class ProjectDuplicateRegistry {
    struct Location: Equatable, Sendable {
        let windowId: ObjectIdentifier
        let projectId: UUID
    }

    enum OpenResult: Equatable, Sendable {
        case opened
        case conflict(Location)
    }

    private static let sharedInstance = ProjectDuplicateRegistry()

    private var locationsByCanonicalPath: [String: Location] = [:]

    static func shared() -> ProjectDuplicateRegistry {
        sharedInstance
    }

    func location(forCanonicalPath canonicalPath: String) -> Location? {
        locationsByCanonicalPath[canonicalPath]
    }

    @discardableResult
    func open(canonicalPath: String, location: Location) -> OpenResult {
        if let existing = locationsByCanonicalPath[canonicalPath] {
            guard existing.windowId == location.windowId else {
                return .conflict(existing)
            }
        }

        locationsByCanonicalPath[canonicalPath] = location
        return .opened
    }

    /// Callers must unregister before the owning window deallocates. A later
    /// window can reuse the same `ObjectIdentifier` after deallocation.
    func close(canonicalPath: String, windowId: ObjectIdentifier) {
        guard let existing = locationsByCanonicalPath[canonicalPath], existing.windowId == windowId else {
            return
        }

        locationsByCanonicalPath.removeValue(forKey: canonicalPath)
    }
}
