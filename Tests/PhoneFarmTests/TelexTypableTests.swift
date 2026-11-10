import XCTest
@testable import PhoneFarm

final class TelexTypableTests: XCTestCase {
    func testPunctuationTheKeyboardCannotTypeIsRewritten() throws {
        let cases: [(String, String)] = [
            ("Bạn dùng loại nào vậy? Mình cũng muốn thử!", "Bạn dùng loại nào vậy. Mình cũng muốn thử."),
            ("Đẹp quá!!! 😍", "Đẹp quá."),
            ("Mẹo hay: để tủ lạnh – rất tiện", "Mẹo hay, để tủ lạnh, rất tiện"),
            ("Mình thích \"chiếc váy\" (màu xanh) nhé?", "Mình thích chiếc váy màu xanh nhé."),
            ("Hay quá… cảm ơn bạn nha", "Hay quá. cảm ơn bạn nha"),
            ("Ổn áp ,,  nha .", "Ổn áp, nha."),
            ("Áo/quần đều đẹp", "Áo quần đều đẹp")
        ]
        for (input, expected) in cases {
            let output = Telex.typable(input)
            XCTAssertEqual(output, expected, input)
            XCTAssertNoThrow(try Telex.keys(for: output), input)
        }
    }

    func testDigitsAndForeignLettersStillFailTelex() {
        XCTAssertThrowsError(try Telex.keys(for: Telex.typable("Giá 200k thôi")))
        XCTAssertThrowsError(try Telex.keys(for: Telex.typable("Mañana")))
    }
}
