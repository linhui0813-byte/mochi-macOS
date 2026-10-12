import XCTest

@testable import MochiApp

final class CharacterColorTests: XCTestCase {
    func testAColourDependsOnlyOnTheNameAndIsTheSameEveryLaunch() {
        // Fixed values: a hash that changed between launches would recolour every character.
        // Computed independently with FNV-1a; Mochi is purple, Loki brown, Ana green.
        XCTAssertEqual(CharacterColor.index(for: "Mochi"), 1)
        XCTAssertEqual(CharacterColor.index(for: "Loki"), 10)
        XCTAssertEqual(CharacterColor.index(for: "Ana"), 5)
        for name in ["Mochi", "Loki", "Ana", "小明", "サクラ", "Companion"] {
            XCTAssertTrue(CharacterColor.palette.indices.contains(CharacterColor.index(for: name)))
        }
    }

    func testCharactersSpreadAcrossThePalette() {
        let names = ["Mochi", "Loki", "Ana", "Sam", "Kai", "Mia", "Leo", "Zoe", "Max", "Ivy", "Eli", "Uma", "Noa"]
        let used = Set(names.map(CharacterColor.index(for:)))
        XCTAssertGreaterThanOrEqual(used.count, 7, "Thirteen names should not crowd into a few colours")
    }
}
