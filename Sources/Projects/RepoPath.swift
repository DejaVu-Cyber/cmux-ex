import Foundation

enum RepoPathError: Error, Equatable {
    case empty
    case normalizationFailed
}

enum RepoPath {
    /// Canonical form used for repo identity and duplicate detection.
    /// This normalizes the path string but does not require the path to exist.
    static func canonical(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RepoPathError.empty }

        let expanded = (trimmed as NSString).expandingTildeInPath
        let canonicalPath = URL(fileURLWithPath: expanded)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path

        guard !canonicalPath.isEmpty else {
            throw RepoPathError.normalizationFailed
        }

        return canonicalPath
    }
}
