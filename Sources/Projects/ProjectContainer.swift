import Combine
import Foundation

@MainActor
final class ProjectContainer: ObservableObject, Identifiable {
    nonisolated let projectId: UUID
    // These published mirrors keep the shell aligned with TabManager until
    // Task 5 routes all callers through workspaceManager directly.
    @Published var workspaces: [Workspace]
    @Published var selectedWorkspaceId: UUID?
    let workspaceManager: TabManager
    private var cancellables: Set<AnyCancellable> = []

    nonisolated var id: UUID { projectId }

    init(projectId: UUID, workspaces: [Workspace], workspaceManager: TabManager) {
        self.projectId = projectId
        self.workspaces = workspaces
        self.workspaceManager = workspaceManager
        self.selectedWorkspaceId = Self.resolvedSelectedWorkspaceId(
            selectedWorkspaceId: workspaceManager.selectedTabId,
            workspaces: workspaces
        )

        workspaceManager.$tabs
            .combineLatest(workspaceManager.$selectedTabId)
            .sink { [weak self] workspaces, selectedWorkspaceId in
                guard let self else { return }
                self.workspaces = workspaces
                self.selectedWorkspaceId = Self.resolvedSelectedWorkspaceId(
                    selectedWorkspaceId: selectedWorkspaceId,
                    workspaces: workspaces
                )
            }
            .store(in: &cancellables)
    }

    private static func resolvedSelectedWorkspaceId(
        selectedWorkspaceId: UUID?,
        workspaces: [Workspace]
    ) -> UUID? {
        guard let selectedWorkspaceId,
              workspaces.contains(where: { $0.id == selectedWorkspaceId }) else {
            return workspaces.first?.id
        }

        return selectedWorkspaceId
    }
}
