import Combine
import Foundation

enum ProjectRegistryError: Error, Equatable {
    case corruptFile
    case incompatibleFuture
    case unsupportedVersion
    case registryFull
    case bookmarkTooLarge
    case saveFailed
}

@MainActor
final class ProjectRegistry: ObservableObject {
    static let currentVersion = 1
    static let maxProjects = 256
    static let maxBookmarkSize = 8 * 1024

    @Published private(set) var projects: [UUID: Project]

    private let fileURL: URL
    private let fileManager: any AtomicFilePersistenceManaging

    private static let sharedInstance: ProjectRegistry = {
        guard let fileURL = SessionPersistenceStore.projectsRegistryFileURL() else {
            preconditionFailure("Unable to resolve projects.json path.")
        }
        return ProjectRegistry(fileURL: fileURL)
    }()

    static func shared() -> ProjectRegistry {
        sharedInstance
    }

    init(
        fileURL: URL,
        projects: [UUID: Project] = [:],
        fileManager: any AtomicFilePersistenceManaging = FileManager.default
    ) {
        self.fileURL = fileURL
        self.projects = projects
        self.fileManager = fileManager
    }

    func load() throws {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            projects = [:]
            return
        } catch {
            throw ProjectRegistryError.corruptFile
        }

        let decoder = Self.makeJSONDecoder()

        let payload: RegistryPayload
        do {
            payload = try decoder.decode(RegistryPayload.self, from: data)
        } catch {
            throw ProjectRegistryError.corruptFile
        }

        if payload.version > Self.currentVersion {
            throw ProjectRegistryError.incompatibleFuture
        }
        // Defensive gate for older persisted schemas once the registry version advances.
        guard payload.version == Self.currentVersion else {
            throw ProjectRegistryError.unsupportedVersion
        }

        var loadedProjects: [UUID: Project] = [:]
        loadedProjects.reserveCapacity(payload.projects.count)
        for project in payload.projects {
            loadedProjects[project.id] = project
        }
        projects = loadedProjects
    }

    func save() throws {
        let payload = RegistryPayload(
            version: Self.currentVersion,
            projects: projects.values.sorted { lhs, rhs in
                lhs.id.uuidString < rhs.id.uuidString
            }
        )

        let data = try Self.makeJSONEncoder().encode(payload)

        do {
            try AtomicFilePersistence.write(data, to: fileURL, fileManager: fileManager)
        } catch {
            throw ProjectRegistryError.saveFailed
        }
    }

    func upsert(_ project: Project) throws {
        if let bookmarkData = project.bookmarkData, bookmarkData.count > Self.maxBookmarkSize {
            throw ProjectRegistryError.bookmarkTooLarge
        }
        if projects[project.id] == nil, projects.count >= Self.maxProjects {
            throw ProjectRegistryError.registryFull
        }
        projects[project.id] = project
    }

    func remove(_ id: UUID) {
        projects.removeValue(forKey: id)
    }

    func byCanonicalPath(_ path: String) -> Project? {
        projects.values.first { $0.repoPath == path }
    }

    private static func makeJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private struct RegistryPayload: Codable {
    let version: Int
    let projects: [Project]
}
