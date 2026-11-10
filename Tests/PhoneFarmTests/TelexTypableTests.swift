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

    func testNumbersForeignLettersAndOtherScriptsBecomeTypable() {
        let cases: [(String, String)] = [
            ("Giá 200k thôi", "Giá hai trăm k thôi"),
            ("Giảm 15% cho 1.005 bạn", "Giảm mười lăm phần trăm cho một nghìn không trăm lẻ năm bạn"),
            ("Điểm 3,5 và 21 người, 2.000.000 đồng", "Điểm ba phẩy năm và hai mươi mốt người, hai triệu đồng"),
            ("Mañana café 好 rất ngon", "Manana café rất ngon")
        ]
        for (input, expected) in cases {
            let output = Telex.typable(input)
            XCTAssertEqual(output, expected, input)
            XCTAssertNoThrow(try Telex.keys(for: output), input)
        }
    }

    func testDecisionInsideFencesAndLongRepliesAreKept() throws {
        let fenced = "```json\n{\"like\":2,\"reply\":{\"index\":1,\"text\":\"Hay quá\"}}\n```"
        XCTAssertEqual(ThreadsReplyAI.decodeDecision(fenced)?.reply.index, 1)
        XCTAssertNil(ThreadsReplyAI.decodeDecision("không có json"))

        let long = Array(repeating: "Mình thấy món này rất ngon, bạn nên thử.", count: 20).joined(separator: " ")
        let reply = ThreadsReplyAI.cleanedReply(long)
        XCTAssertLessThanOrEqual(reply.count, 450)
        XCTAssertGreaterThan(reply.count, 300)
        XCTAssertNoThrow(try Telex.keys(for: reply))
    }
}
