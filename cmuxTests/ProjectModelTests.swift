import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class ProjectModelTests: XCTestCase {
    func testProjectRoundTripsThroughJSONWithValueEquality() throws {
        let project = try makeProject(color: .customHex("#aabbcc"))
        XCTAssertEqual(project.name, "cmux-ex")
        XCTAssertEqual(project.color, .customHex("#AABBCC"))

        let encoder = makeEncoder()
        let encoded = try encoder.encode(project)
        let decoded = try JSONDecoder().decode(Project.self, from: encoded)

        XCTAssertEqual(decoded, project)
        XCTAssertEqual(try encoder.encode(decoded), encoded)
    }

    func testNameValidatorRejectsEmptyAfterTrimAndTooLongUTF16() {
        XCTAssertThrowsError(try Project.validatedName("   \n\t ")) { error in
            XCTAssertEqual(error as? Project.NameError, .empty)
        }

        let tooLong = String(repeating: "a", count: 81)
        XCTAssertEqual(tooLong.utf16.count, 81)
        XCTAssertThrowsError(try Project.validatedName(tooLong)) { error in
            XCTAssertEqual(error as? Project.NameError, .tooLong)
        }
    }

    func testMonogramValidatorRejectsInvalidFormsAndAcceptsSingleGraphemes() throws {
        XCTAssertThrowsError(try Project.validatedMonogram("  ")) { error in
            XCTAssertEqual(error as? Project.MonogramError, .empty)
        }

        XCTAssertThrowsError(try Project.validatedMonogram("AB")) { error in
            XCTAssertEqual(error as? Project.MonogramError, .multipleGraphemes)
        }

        XCTAssertThrowsError(try Project.validatedMonogram("\u{0301}")) { error in
            XCTAssertEqual(error as? Project.MonogramError, .combiningMarksOnly)
        }

        XCTAssertEqual(try Project.validatedMonogram("A"), "A")
        XCTAssertEqual(try Project.validatedMonogram("👩🏽‍💻"), "👩🏽‍💻")
        XCTAssertEqual(try Project.validatedMonogram("漢"), "漢")
    }

    func testDecodedProjectIgnoresRuntimeOnlyIsGhostKey() throws {
        let project = try makeProject()
        var jsonObject = try makeJSONObject(from: project)
        jsonObject["isGhost"] = true

        let decoded = try JSONDecoder().decode(Project.self, from: try makeJSONData(from: jsonObject))
        let reencoded = try makeEncoder().encode(decoded)

        XCTAssertEqual(decoded, project)
        XCTAssertFalse(String(decoding: reencoded, as: UTF8.self).contains("isGhost"))
    }

    func testDecodedProjectIgnoresUnknownServiceConfigKey() throws {
        let project = try makeProject()
        var jsonObject = try makeJSONObject(from: project)
        jsonObject["serviceConfig"] = [
            "provider": "example",
            "model": "phase-c-placeholder",
        ]

        let decoded = try JSONDecoder().decode(Project.self, from: try makeJSONData(from: jsonObject))
        let reencoded = try makeEncoder().encode(decoded)

        XCTAssertEqual(decoded, project)
        XCTAssertFalse(String(decoding: reencoded, as: UTF8.self).contains("serviceConfig"))
    }

    func testProjectColorHexValidationAndNormalization() throws {
        XCTAssertEqual(
            try ProjectColor.customHex("#aabbcc").normalized(),
            .customHex("#AABBCC")
        )
        XCTAssertEqual(
            try ProjectColor.customHex("#AABBCC").normalized(),
            .customHex("#AABBCC")
        )

        for invalid in ["aabbcc", "#12", "#GGHHII"] {
            XCTAssertThrowsError(try ProjectColor.customHex(invalid).normalized()) { error in
                XCTAssertEqual(error as? ProjectColor.ValidationError, .invalidHex)
            }
        }
    }

    private func makeProject(color: ProjectColor = .palette(.green)) throws -> Project {
        try Project(
            id: UUID(uuidString: "D9B45AB0-0A5F-4A0F-B93E-6E0A4A6C6B4A")!,
            name: "  cmux-ex  ",
            monogram: "👩🏽‍💻",
            color: color,
            repoPath: "/Users/user/projects/cmux-ex",
            bookmarkData: Data([0xCA, 0xFE]),
            lastOpenedAt: Date(timeIntervalSince1970: 1_713_720_000)
        )
    }

    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func makeJSONObject(from project: Project) throws -> [String: Any] {
        let data = try makeEncoder().encode(project)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func makeJSONData(from object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
