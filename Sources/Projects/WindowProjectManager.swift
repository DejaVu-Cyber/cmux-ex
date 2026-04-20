import Combine
import Foundation

enum WindowProjectManagerError: Error, Equatable {
    case projectAlreadyOpen(UUID)
    case projectNotOpen(UUID)
    case invalidProjectOrder
}

@MainActor
final class WindowProjectManager: ObservableObject {
    enum InsertPolicy {
        case atEnd
        case afterActive
        case atStart
    }

    let windowIdentity: ObjectIdentifier
    @Published var openProjectIds: [UUID]
    @Published var activeProjectId: UUID?
    // Strong references keep containers alive for as long as the project remains open.
    @Published var containers: [UUID: ProjectContainer]

    var activeContainer: ProjectContainer? {
        activeProjectId.flatMap { containers[$0] }
    }

    init(
        owner: AnyObject,
        openProjectIds: [UUID] = [],
        activeProjectId: UUID? = nil,
        containers: [UUID: ProjectContainer] = [:]
    ) {
        self.windowIdentity = ObjectIdentifier(owner)
        self.openProjectIds = openProjectIds
        self.activeProjectId = activeProjectId
        self.containers = containers
    }

    func openProject(_ project: Project, inserting: InsertPolicy) throws {
        guard !openProjectIds.contains(project.id), containers[project.id] == nil else {
            throw WindowProjectManagerError.projectAlreadyOpen(project.id)
        }

        let workspaceManager = TabManager(initialWorkingDirectory: project.repoPath)
        let container = ProjectContainer(
            projectId: project.id,
            workspaces: workspaceManager.tabs,
            workspaceManager: workspaceManager
        )

        containers[project.id] = container
        openProjectIds.insert(project.id, at: insertionIndex(for: inserting))
        activeProjectId = project.id
    }

    func closeProject(_ projectId: UUID) throws {
        guard let closedIndex = openProjectIds.firstIndex(of: projectId) else {
            throw WindowProjectManagerError.projectNotOpen(projectId)
        }

        let closedWasActive = activeProjectId == projectId
        openProjectIds.remove(at: closedIndex)
        containers.removeValue(forKey: projectId)

        guard closedWasActive else { return }
        guard !openProjectIds.isEmpty else {
            activeProjectId = nil
            return
        }

        let nextIndex = min(closedIndex, openProjectIds.count - 1)
        activeProjectId = openProjectIds[nextIndex]
    }

    func selectProject(_ projectId: UUID) throws {
        guard openProjectIds.contains(projectId) else {
            throw WindowProjectManagerError.projectNotOpen(projectId)
        }

        activeProjectId = projectId
    }

    func reorder(projectIds: [UUID]) throws {
        let currentIds = openProjectIds
        let currentSet = Set(currentIds)
        let proposedSet = Set(projectIds)
        let hasUniqueProposedIds = proposedSet.count == projectIds.count

        guard hasUniqueProposedIds,
              projectIds.count == currentIds.count,
              proposedSet == currentSet else {
            throw WindowProjectManagerError.invalidProjectOrder
        }

        openProjectIds = projectIds
        if openProjectIds.isEmpty {
            activeProjectId = nil
        } else if let activeProjectId, !openProjectIds.contains(activeProjectId) {
            self.activeProjectId = openProjectIds.first
        }
    }

    private func insertionIndex(for policy: InsertPolicy) -> Int {
        switch policy {
        case .atEnd:
            return openProjectIds.count
        case .atStart:
            return 0
        case .afterActive:
            guard let activeProjectId,
                  let activeIndex = openProjectIds.firstIndex(of: activeProjectId) else {
                return openProjectIds.count
            }
            return activeIndex + 1
        }
    }
}
