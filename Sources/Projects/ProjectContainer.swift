import Combine
import Foundation

@MainActor
final class ProjectContainer: ObservableObject, Identifiable {
    nonisolated let projectId: UUID
    @Published var workspaces: [Workspace]
    @Published var selectedWorkspaceId: UUID?
    let workspaceManager: TabManager

    nonisolated var id: UUID { projectId }

    init(projectId: UUID, workspaces: [Workspace], workspaceManager: TabManager) {
        self.projectId = projectId
        self.workspaces = workspaces
        self.workspaceManager = workspaceManager

        if let selectedWorkspaceId = workspaceManager.selectedTabId,
           workspaces.contains(where: { $0.id == selectedWorkspaceId }) {
            self.selectedWorkspaceId = selectedWorkspaceId
        } else {
            self.selectedWorkspaceId = workspaces.first?.id
        }
    }
}
