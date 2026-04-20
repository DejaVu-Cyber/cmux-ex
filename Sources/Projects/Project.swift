import Foundation

struct Project: Identifiable, Codable, Equatable, Hashable {
    enum ValidationError: Error, Equatable {
        case invalidName(NameError)
        case invalidMonogram(MonogramError)
        case invalidColor(ProjectColor.ValidationError)
    }

    enum NameError: Error, Equatable {
        case empty
        case tooLong
    }

    enum MonogramError: Error, Equatable {
        case empty
        case multipleGraphemes
        case combiningMarksOnly
    }

    let id: UUID
    private(set) var name: String
    private(set) var monogram: String
    private(set) var color: ProjectColor
    // RepoPath.canonical(_:) is the only normalization authority. Project keeps
    // repoPath as pure data so callers can canonicalize once at ingress.
    private(set) var repoPath: String
    var bookmarkData: Data?
    var lastOpenedAt: Date

    // Validation is centralized here so callers and Codable decoding use the
    // same normalization rules for every stored Project value.
    init(
        id: UUID,
        name: String,
        monogram: String,
        color: ProjectColor,
        repoPath: String,
        bookmarkData: Data?,
        lastOpenedAt: Date
    ) throws {
        self.id = id
        self.name = try Self.normalizedName(name)
        self.monogram = try Self.normalizedMonogram(monogram)
        self.color = try Self.normalizedColor(color)
        self.repoPath = repoPath
        self.bookmarkData = bookmarkData
        self.lastOpenedAt = lastOpenedAt
    }

    mutating func setName(_ raw: String) throws {
        name = try Self.validatedName(raw)
    }

    mutating func setMonogram(_ raw: String) throws {
        monogram = try Self.validatedMonogram(raw)
    }

    mutating func setColor(_ raw: ProjectColor) throws {
        color = try Self.normalizedColor(raw)
    }

    mutating func setCanonicalRepoPath(_ canonicalPath: String) {
        repoPath = canonicalPath
    }

    static func validatedName(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw NameError.empty }
        guard trimmed.utf16.count <= 80 else { throw NameError.tooLong }
        return trimmed
    }

    static func validatedMonogram(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MonogramError.empty }
        guard trimmed.count == 1 else { throw MonogramError.multipleGraphemes }
        guard trimmed.unicodeScalars.contains(where: { !Self.isCombiningMark($0) }) else {
            throw MonogramError.combiningMarksOnly
        }
        return trimmed
    }

    private static func isCombiningMark(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark:
            return true
        default:
            return false
        }
    }

    private static func normalizedName(_ raw: String) throws -> String {
        do {
            return try validatedName(raw)
        } catch let error as NameError {
            throw ValidationError.invalidName(error)
        }
    }

    private static func normalizedMonogram(_ raw: String) throws -> String {
        do {
            return try validatedMonogram(raw)
        } catch let error as MonogramError {
            throw ValidationError.invalidMonogram(error)
        }
    }

    private static func normalizedColor(_ color: ProjectColor) throws -> ProjectColor {
        do {
            return try color.normalized()
        } catch let error as ProjectColor.ValidationError {
            throw ValidationError.invalidColor(error)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case monogram
        case color
        case repoPath
        case bookmarkData
        case lastOpenedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let name = try container.decode(String.self, forKey: .name)
        let monogram = try container.decode(String.self, forKey: .monogram)
        let color = try container.decode(ProjectColor.self, forKey: .color)
        let repoPath = try container.decode(String.self, forKey: .repoPath)
        let bookmarkData = try container.decodeIfPresent(Data.self, forKey: .bookmarkData)
        let lastOpenedAt = try container.decode(Date.self, forKey: .lastOpenedAt)

        do {
            try self.init(
                id: id,
                name: name,
                monogram: monogram,
                color: color,
                repoPath: repoPath,
                bookmarkData: bookmarkData,
                lastOpenedAt: lastOpenedAt
            )
        } catch let error as ValidationError {
            switch error {
            case .invalidName:
                throw DecodingError.dataCorruptedError(
                    forKey: .name,
                    in: container,
                    debugDescription: "Project name is invalid."
                )
            case .invalidMonogram:
                throw DecodingError.dataCorruptedError(
                    forKey: .monogram,
                    in: container,
                    debugDescription: "Project monogram is invalid."
                )
            case .invalidColor:
                throw DecodingError.dataCorruptedError(
                    forKey: .color,
                    in: container,
                    debugDescription: "Project color is invalid."
                )
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(monogram, forKey: .monogram)
        try container.encode(color, forKey: .color)
        try container.encode(repoPath, forKey: .repoPath)
        try container.encodeIfPresent(bookmarkData, forKey: .bookmarkData)
        try container.encode(lastOpenedAt, forKey: .lastOpenedAt)
    }
}

enum ProjectColor: Codable, Equatable, Hashable {
    enum ValidationError: Error, Equatable {
        case invalidHex
    }

    case palette(PaletteKey)
    case customHex(String)

    func normalized() throws -> Self {
        switch self {
        case .palette:
            return self
        case .customHex(let hex):
            return .customHex(try Self.validatedCustomHex(hex))
        }
    }

    static func validatedCustomHex(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("#") else { throw ValidationError.invalidHex }

        let body = String(trimmed.dropFirst())
        guard body.count == 6 else { throw ValidationError.invalidHex }
        guard UInt32(body, radix: 16) != nil else { throw ValidationError.invalidHex }

        return "#" + body.uppercased()
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case key
        case hex
    }

    private enum Kind: String, Codable {
        case palette
        case customHex
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)

        switch kind {
        case .palette:
            self = .palette(try container.decode(PaletteKey.self, forKey: .key))
        case .customHex:
            let rawHex = try container.decode(String.self, forKey: .hex)
            do {
                self = .customHex(try Self.validatedCustomHex(rawHex))
            } catch {
                throw DecodingError.dataCorruptedError(
                    forKey: .hex,
                    in: container,
                    debugDescription: "Project custom hex color must be formatted as #RRGGBB."
                )
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch try normalized() {
        case .palette(let key):
            try container.encode(Kind.palette, forKey: .kind)
            try container.encode(key, forKey: .key)
        case .customHex(let hex):
            try container.encode(Kind.customHex, forKey: .kind)
            try container.encode(hex, forKey: .hex)
        }
    }
}

enum PaletteKey: String, Codable, CaseIterable {
    case green
    case yellow
    case red
    case orange
    case purple
    case cyan
    case accent
}
