import Foundation

@MainActor
final class ProjectDuplicateRegistry {
    struct Location: Equatable {
        let windowId: ObjectIdentifier
        let projectId: UUID
    }

    enum OpenResult: Equatable {
        case opened
        case conflict(Location)
    }

    private var locationsByCanonicalPath: [String: Location] = [:]

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

    func close(canonicalPath: String, windowId: ObjectIdentifier) {
        guard let existing = locationsByCanonicalPath[canonicalPath], existing.windowId == windowId else {
            return
        }

        locationsByCanonicalPath.removeValue(forKey: canonicalPath)
    }
}
