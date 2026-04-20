import Foundation

enum RepoPathError: Error, Equatable {
    case empty
    case normalizationFailed
}

enum RepoPath {
    /// Canonical form used for repo identity and duplicate detection.
    static func canonical(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RepoPathError.empty }

        let canonicalPath = URL(fileURLWithPath: trimmed)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path

        guard !canonicalPath.isEmpty else {
            throw RepoPathError.normalizationFailed
        }

        return canonicalPath
    }
}
