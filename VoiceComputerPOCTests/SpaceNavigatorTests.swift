import XCTest

@testable import VoiceComputerPOC

final class SpaceNavigatorTests: XCTestCase {
    func testOnlyExplicitSpacePhrasesSelectNativeAction() {
        XCTAssertEqual(SpaceDirection(phrase: "Switch to the next desktop Space"), .right)
        XCTAssertEqual(SpaceDirection(phrase: " Switch one desktop Space to the left "), .left)
        XCTAssertNil(SpaceDirection(phrase: "Explain how desktop Spaces work"))
        XCTAssertNil(SpaceDirection(phrase: "Switch to the next desktop Space and delete a file"))
    }

    func testAdjacentSpaceRespectsBothBoundaries() {
        let first = SpaceSnapshot(current: 3, ordered: [3, 4])
        let second = SpaceSnapshot(current: 4, ordered: [3, 4])
        XCTAssertEqual(first.adjacent(.right), 4)
        XCTAssertNil(first.adjacent(.left))
        XCTAssertEqual(second.adjacent(.left), 3)
        XCTAssertNil(second.adjacent(.right))
    }
}
