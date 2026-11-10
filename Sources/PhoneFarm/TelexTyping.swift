import CoreGraphics
import Foundation
import ImageIO

enum TypingError: LocalizedError {
    case unsupported(Character)
    case invalidWord
    case unavailable
    case keyboardHidden
    case wrongKeyboard
    case keyboardChanged
    case calibration
    case screenshot
    case newlineUnavailable
    case commandFailed
    case textChanged

    var errorDescription: String? {
        switch self {
        case .unsupported(let character): return "Chưa hỗ trợ ký tự “\(character)”."
        case .invalidWord: return "Có từ chứa nhiều dấu thanh. Hãy kiểm tra lại đoạn văn."
        case .unavailable: return "Không tìm thấy ADB."
        case .keyboardHidden: return "Mở Gboard ở một ô nhập văn bản trên điện thoại."
        case .wrongKeyboard: return "Chọn Gboard tiếng Việt Telex trên điện thoại."
        case .keyboardChanged: return "Bàn phím hoặc cửa sổ Android đã thay đổi. Hãy mở lại ô nhập và thử lại."
        case .calibration: return "Vị trí các phím chưa hợp lệ. Hãy chụp lại và bấm vào giữa từng phím theo hướng dẫn."
        case .screenshot: return "Không đọc được ảnh bàn phím Android."
        case .newlineUnavailable: return "Ô hiện tại không có phím xuống dòng. Hãy chọn một ô nhập nhiều dòng."
        case .commandFailed: return "ADB không thực hiện được thao tác trên điện thoại."
        case .textChanged: return "Gboard đã đổi nội dung vừa gõ. Hãy kiểm tra từ đang nhập trên điện thoại."
        }
    }
}

enum Telex {
    private static let tones: [Unicode.Scalar: Character] = [
        "\u{0301}": "s", "\u{0300}": "f", "\u{0309}": "r", "\u{0303}": "x", "\u{0323}": "j"
    ]
    static func keys(for text: String) throws -> [Character] {
        var keys: [Character] = []
        var word: [Character] = []
        var tone: Character?
        var previousWasUWithHorn = false

        for letter in text {
            if [" ", ",", ".", "\n", "\r\n"].contains(letter) {
                keys.append(contentsOf: word)
                if let tone { keys.append(tone) }
                keys.append(letter == "\r\n" ? "\n" : letter)
                word.removeAll(keepingCapacity: true)
                tone = nil
                previousWasUWithHorn = false
                continue
            }

            if letter == "đ" || letter == "Đ" {
                word.append(letter == "Đ" ? "D" : "d")
                word.append("d")
                previousWasUWithHorn = false
                continue
            }

            let scalars = String(letter).decomposedStringWithCanonicalMapping.unicodeScalars
            guard let first = scalars.first, first.isASCII, Character(first).isLetter else {
                throw TypingError.unsupported(letter)
            }
            let base = Character(first)
            let lower = Character(base.lowercased())
            var shape: Character?
            for mark in scalars.dropFirst() {
                if let key = tones[mark], "aeiouy".contains(lower) {
                    guard tone == nil else { throw TypingError.invalidWord }
                    tone = key
                } else if shape == nil {
                    switch (mark, lower) {
                    case ("\u{0302}", "a"), ("\u{0302}", "e"), ("\u{0302}", "o"):
                        shape = lower
                    case ("\u{0306}", "a"), ("\u{031B}", "o"), ("\u{031B}", "u"):
                        shape = "w"
                    default: throw TypingError.unsupported(letter)
                    }
                } else {
                    throw TypingError.unsupported(letter)
                }
            }

            // In Telex, one W adds both horns in ươ.
            if previousWasUWithHorn, lower == "o", shape == "w" { word.removeLast() }
            word.append(base)
            if let shape { word.append(shape) }
            previousWasUWithHorn = lower == "u" && shape == "w"
        }

        keys.append(contentsOf: word)
        if let tone { keys.append(tone) }
        return keys
    }

    /// Rewrites AI text into what `keys(for:)` accepts: question and exclamation marks become
    /// periods, other separators become commas or spaces, numbers are spelled out in Vietnamese,
    /// foreign letters lose their marks (ñ → n), and everything else the keyboard cannot type
    /// (quotes, brackets, emoji, other scripts) is dropped.
    static func typable(_ text: String) -> String {
        var result = ""
        for character in spellingNumbers(in: text) {
            switch character {
            case "?", "!", "…", "。", "？", "！": result.append(".")
            case ";", ":", "–", "—", "；", "：": result.append(",")
            case "-", "/", "_", "|", "\t", "+", "&", "=": result.append(" ")
            case " ", ",", ".": result.append(character)
            default:
                if character.isNewline { result.append("\n") }
                else if character.isLetter {
                    if (try? keys(for: String(character))) != nil { result.append(character) }
                    else if let base = String(character).decomposedStringWithCanonicalMapping.unicodeScalars.first,
                            base.isASCII, Character(base).isLetter { result.append(Character(base)) }
                }
            }
        }
        // A word Telex still cannot build (two tone marks, for example) loses its marks, or goes.
        result = result.split(separator: " ", omittingEmptySubsequences: false).map { chunk in
            let word = String(chunk)
            if (try? keys(for: word)) != nil { return word }
            let plain = word.folding(options: .diacriticInsensitive, locale: Locale(identifier: "vi_VN"))
            return (try? keys(for: plain)) != nil ? plain : ""
        }.joined(separator: " ")
        let rules: [(String, String)] = [
            (#"[ ]+([,.])"#, "$1"),          // no space before punctuation
            (#"([,.])[,. ]*\.[,. ]*"#, "."), // a run holding a period ends the sentence
            (#",[, ]*,"#, ","),              // repeated commas
            (#"([,.])(?=[^\s,.])"#, "$1 "),  // space after punctuation
            (#"[ ]{2,}"#, " "),
            (#"(?m)^[ ,.]+|[ ,]+$"#, "")     // no line starts with punctuation or ends with a comma
        ]
        for (pattern, template) in rules {
            result = result.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "1.500" → "một nghìn năm trăm", "3,5" → "ba phẩy năm", "20%" → "hai mươi phần trăm".
    static func spellingNumbers(in text: String) -> String {
        var text = text.replacingOccurrences(of: #"(?<=\d)[.,](?=\d{3}(?!\d))"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?<=\d)[.,](?=\d)"#, with: " phẩy ", options: .regularExpression)
        text = text.replacingOccurrences(of: "%", with: " phần trăm ")
        var result = ""
        var digits = ""
        func flush() {
            guard !digits.isEmpty else { return }
            let words = digits.count <= 12 ? spelled(Int(digits)!) : digits.compactMap(\.wholeNumberValue).map { units[$0] }.joined(separator: " ")
            result += " " + words + " "
            digits = ""
        }
        for character in text {
            if character.isASCII, character.isNumber { digits.append(character) } else { flush(); result.append(character) }
        }
        flush()
        return result
    }

    private static let units = ["không", "một", "hai", "ba", "bốn", "năm", "sáu", "bảy", "tám", "chín"]

    static func spelled(_ number: Int) -> String {
        guard number > 0 else { return "không" }
        let scales = ["", "nghìn", "triệu", "tỷ", "nghìn tỷ"]
        var groups: [Int] = []
        var rest = number
        while rest > 0 { groups.append(rest % 1000); rest /= 1000 }
        var parts: [String] = []
        for (index, group) in groups.enumerated().reversed() where group > 0 {
            let full = index < groups.count - 1 // a group after a higher one reads its hundreds ("không trăm")
            parts.append(([spelledGroup(group, full: full)] + (scales[index].isEmpty ? [] : [scales[index]])).joined(separator: " "))
        }
        return parts.joined(separator: " ")
    }

    private static func spelledGroup(_ group: Int, full: Bool) -> String {
        let (hundreds, tens, ones) = (group / 100, group / 10 % 10, group % 10)
        var words: [String] = []
        if full || hundreds > 0 { words.append(units[hundreds] + " trăm") }
        switch tens {
        case 0:
            if ones > 0 { if !words.isEmpty { words.append("lẻ") }; words.append(units[ones]) }
        case 1:
            words.append("mười")
            if ones > 0 { words.append(ones == 5 ? "lăm" : units[ones]) }
        default:
            words.append(units[tens] + " mươi")
            if ones > 0 { words.append(ones == 1 ? "mốt" : ones == 4 ? "tư" : ones == 5 ? "lăm" : units[ones]) }
        }
        return words.joined(separator: " ")
    }
}

struct KeyboardContext: Equatable {
    let focus: String
    let frame: CGRect

    static func read(_ output: String) -> KeyboardContext? {
        let lines = output.split(whereSeparator: \.isNewline)
        guard let focus = lines.first(where: { $0.contains("mCurrentFocus=Window{") }),
              let ime = lines.first(where: {
                  ($0.contains("type=ITYPE_IME ") || $0.contains("type=ime ")) &&
                      $0.contains("visible=true") && $0.contains(" frame=[")
              }),
              let start = ime.range(of: " frame=[")?.upperBound else { return nil }
        let values = ime[start...].prefix(while: { !$0.isWhitespace })
            .split(whereSeparator: { !$0.isNumber && $0 != "-" }).compactMap { Int($0) }
        guard values.count == 4, values[0] >= 0, values[1] >= 0,
              values[0] < values[2], values[1] < values[3] else { return nil }
        return KeyboardContext(
            focus: focus.trimmingCharacters(in: .whitespaces),
            frame: CGRect(x: values[0], y: values[1], width: values[2] - values[0], height: values[3] - values[1])
        )
    }
}

extension KeyboardContext {
    /// Android 10 and older: the InputMethod window covers the screen and the keyboard starts at its
    /// top content inset (`mGivenContentInsets=[0,top][0,0]`) and ends at the bottom of the content frame.
    /// `focusOutput` is the `dumpsys window displays` output, which holds `mCurrentFocus` on Android 10.
    static func readLegacy(_ output: String, focusOutput: String) -> KeyboardContext? {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        guard let focus = (focusOutput + "\n" + output).split(whereSeparator: \.isNewline)
                .first(where: { $0.contains("mCurrentFocus=Window{") }).map(String.init),
              let start = lines.firstIndex(where: { $0.contains(" InputMethod}:") && $0.contains("Window #") }) else { return nil }
        let block = lines[(start + 1)...].prefix { !$0.contains("Window #") }
        guard block.contains(where: { $0.contains("isVisible=true") }),
              block.contains(where: { $0.contains("mHasSurface=true") }),
              block.contains(where: { $0.contains("mViewVisibility=0x0") }) else { return nil }
        func rect(after key: String) -> [Int]? {
            guard let line = block.first(where: { $0.contains(key) }),
                  let range = line.range(of: key) else { return nil }
            let values = line[range.upperBound...].prefix(while: { $0 != " " })
                .split(whereSeparator: { !$0.isNumber && $0 != "-" }).compactMap { Int($0) }
            return values.count == 4 ? values : nil
        }
        guard let frame = rect(after: "mFrame="), let insets = rect(after: "mGivenContentInsets=") else { return nil }
        let bottom = rect(after: "content=")?[3] ?? frame[3]
        let top = frame[1] + insets[1]
        guard insets[1] > 0, frame[0] >= 0, frame[0] < frame[2], top < bottom else { return nil }
        return KeyboardContext(focus: focus.trimmingCharacters(in: .whitespaces),
                               frame: CGRect(x: frame[0], y: top, width: frame[2] - frame[0], height: bottom - top))
    }
}

struct KeyboardCapture {
    let context: KeyboardContext
    let image: CGImage
}

struct KeyboardLayout {
    static let anchors: [Character] = ["q", "p", "a", "z", " ", ",", ".", "⇧"]
    static let enter: Character = "\n"
    let points: [Character: CGPoint]

    func taps(for keys: [Character]) throws -> [CGPoint] {
        guard let q = points["q"], let p = points["p"], let a = points["a"],
              let z = points["z"], let space = points[" "],
              q.x < p.x, q.y < a.y, a.y < z.y, z.y < space.y else { throw TypingError.calibration }
        let stride = (p.x - q.x) / 9
        guard abs(p.y - q.y) < (a.y - q.y) / 2 else { throw TypingError.calibration }
        let rows = [("qwertyuiop", q), ("asdfghjkl", a), ("zxcvbnm", z)]
        var map = points
        for (row, origin) in rows {
            for (index, letter) in row.enumerated() {
                map[letter] = CGPoint(x: origin.x + CGFloat(index) * stride, y: origin.y)
            }
        }

        guard let taps = Self.taps(for: keys, using: map) else { throw TypingError.calibration }
        return taps
    }

    static func taps(for keys: [Character], using points: [Character: CGPoint]) -> [CGPoint]? {
        var taps: [CGPoint] = []
        for key in keys {
            guard let point = points[Character(key.lowercased())] else { return nil }
            if key.isUppercase {
                guard let shift = points["⇧"] else { return nil }
                taps.append(shift)
            }
            taps.append(point)
        }
        return taps
    }
}

struct TelexTyping {
    let adb: URL
    let serial: String

    private struct SystemKeyboard {
        let points: [Character: CGPoint]
        let uppercase: Bool
    }

    func prepare(for keys: [Character]) async throws -> KeyboardContext {
        // A pulled-down notification shade covers the keyboard, so Android reports only part of its keys.
        _ = try? await command(["shell", "cmd statusbar collapse"])
        try await Task.sleep(for: .milliseconds(300))
        let context = try await keyboardContext()
        let ime = try await command(["shell", "settings", "get", "secure", "default_input_method"])
        guard ime.output.hasPrefix("com.google.android.inputmethod.latin/") else {
            throw TypingError.wrongKeyboard
        }
        if keys.contains(KeyboardLayout.enter) {
            let editor = try await command(["shell", "dumpsys input_method | grep -A 2 -E 'mCurrentTextBoxAttribute:|mCurAttribute=' || true"])
            guard Self.allowsNewline(editor.output) else { throw TypingError.newlineUnavailable }
        }
        return context
    }

    func capture(context: KeyboardContext) async throws -> KeyboardCapture {
        let snapshot = try await command(["exec-out", "screencap", "-p"])
        guard let source = CGImageSourceCreateWithData(snapshot.data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width < image.height,
              CGRect(x: 0, y: 0, width: image.width, height: image.height).contains(context.frame),
              let cropped = image.cropping(to: context.frame) else { throw TypingError.screenshot }
        guard try await keyboardContext() == context else { throw TypingError.keyboardChanged }
        return KeyboardCapture(context: context, image: cropped)
    }

    func systemTaps(for keys: [Character], context: KeyboardContext) async throws -> [CGPoint]? {
        let points = (try? await readSystemKeys().points) ?? [:]
        try Task.checkCancellation()
        guard try await keyboardContext() == context else { throw TypingError.keyboardChanged }
        guard let taps = KeyboardLayout.taps(for: keys, using: points),
              taps.allSatisfy({ context.frame.contains($0) }) else { return nil }
        return taps
    }

    private func readSystemKeys() async throws -> SystemKeyboard {
        let output = try await AndroidAccessibility.read(adb: adb, serial: serial, entry: .keyboard)
        guard output.status == 0 else { throw TypingError.commandFailed }
        return SystemKeyboard(points: Self.systemKeys(from: output.output),
                              uppercase: output.output.split(whereSeparator: \.isNewline)
                                .filter { $0 == "state\tuppercase\t1" }.count >= 26)
    }

    private static func systemKeys(from output: String) -> [Character: CGPoint] {
        let namedKeys: [Substring: Character] = ["space": " ", "shift": "⇧", "enter": KeyboardLayout.enter]
        var points: [Character: CGPoint] = [:]
        var ambiguous: Set<Character> = []
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t")
            guard fields.count == 4, fields[0] == "key",
                  let x = Int(fields[2]), let y = Int(fields[3]) else { continue }
            let label = fields[1]
            let key = namedKeys[label] ?? (label.count == 1 ? label.first : nil)
            guard let key, !ambiguous.contains(key) else { continue }
            let point = CGPoint(x: x, y: y)
            if let existing = points[key], existing != point {
                points.removeValue(forKey: key)
                ambiguous.insert(key)
            } else {
                points[key] = point
            }
        }
        return points
    }

    private struct Segment: Encodable {
        let text: String
        let keys: String
        let separator: String
    }

    private struct TypingRequest: Encodable {
        let packageName: String
        let segments: [Segment]
        let minimumDelay: Int
        let maximumDelay: Int
        let requireEmpty: Bool
    }

    private struct TypingResult: Decodable {
        let typingStatus: String
    }

    @MainActor
    func typeText(_ text: String, context: KeyboardContext, pauseMilliseconds: ClosedRange<Int>,
                  requireEmpty: Bool = false,
                  progress: @escaping @MainActor @Sendable (Int, Int) -> Void) async throws {
        var segments: [Segment] = []
        var word = ""
        for character in text {
            if [" ", ",", ".", "\n", "\r\n"].contains(character) {
                let separator = character == "\r\n" ? "\n" : String(character)
                segments.append(Segment(text: word, keys: String(try Telex.keys(for: word)), separator: separator))
                word = ""
            } else { word.append(character) }
        }
        if !word.isEmpty { segments.append(Segment(text: word, keys: String(try Telex.keys(for: word)), separator: "")) }
        guard try await keyboardContext() == context,
              let component = context.focus.split(whereSeparator: \.isWhitespace).first(where: { $0.contains("/") }),
              let package = component.split(separator: "/").first else { throw TypingError.keyboardChanged }
        let request = TypingRequest(packageName: String(package), segments: segments,
                                    minimumDelay: pauseMilliseconds.lowerBound, maximumDelay: pauseMilliseconds.upperBound,
                                    requireEmpty: requireEmpty)
        let count = segments.reduce(0) { $0 + $1.keys.count + $1.separator.count }
        // Generous bound for the human-like rhythm: skewed key intervals (up to 3× the maximum),
        // word, comma and sentence pauses plus occasional thinking stops.
        let timeout = max(60, count * (pauseMilliseconds.upperBound * 3 / 2 + 200) / 1_000 + segments.count * 4 + 60)
        let result = try await AndroidAccessibility.read(adb: adb, serial: serial, entry: .keyboardType, timeout: timeout,
                                                          payload: JSONEncoder().encode(request)) { update in
            if update.stage == "typing", let done = update.completed, let total = update.total {
                await progress(done, total)
            }
        }
        try Task.checkCancellation()
        guard result.status == 0, let line = result.output.split(whereSeparator: \.isNewline).last,
              let status = try? JSONDecoder().decode(TypingResult.self, from: Data(line.utf8)) else {
            throw TypingError.commandFailed
        }
        switch status.typingStatus {
        case "typed": return
        case "cancelled": throw CancellationError()
        case "keyboard_unavailable": throw TypingError.wrongKeyboard
        case "editor_changed", "keyboard_changed", "draft_exists": throw TypingError.keyboardChanged
        case "text_changed": throw TypingError.textChanged
        default: throw TypingError.commandFailed
        }
    }

    @MainActor
    func type(_ taps: [CGPoint], context: KeyboardContext,
              pauseMilliseconds: ClosedRange<Int>, progress: (Int, Int) -> Void) async throws {
        guard taps.allSatisfy({ context.frame.contains($0) }) else { throw TypingError.calibration }
        for (index, tap) in taps.enumerated() {
            try Task.checkCancellation()
            guard try await keyboardContext() == context else { throw TypingError.keyboardChanged }
            try Task.checkCancellation()
            _ = try await command(["shell", "input", "tap", String(Int(tap.x)), String(Int(tap.y))])
            progress(index + 1, taps.count)
            if index + 1 < taps.count {
                let delay = Int.random(in: pauseMilliseconds)
                try await Task.sleep(for: .milliseconds(delay))
            }
        }
    }

    static func allowsNewline(_ output: String) -> Bool {
        guard let line = output.split(whereSeparator: \.isNewline).first(where: { $0.contains("inputType=0x") }),
              let inputType = hexValue("inputType=0x", in: line),
              let imeOptions = hexValue("imeOptions=0x", in: line) else { return false }
        return inputType & 0xf == 1 && inputType & 0x20000 != 0
            && (imeOptions & 0xff == 1 || imeOptions & 0x40000000 != 0)
    }

    private static func hexValue(_ prefix: String, in line: Substring) -> UInt32? {
        guard let start = line.range(of: prefix)?.upperBound else { return nil }
        return UInt32(line[start...].prefix(while: \.isHexDigit), radix: 16)
    }

    private func keyboardContext() async throws -> KeyboardContext {
        let result = try await command(["shell", "dumpsys window displays | grep -E 'mCurrentFocus=|type=ITYPE_IME|type=ime'"])
        if let context = KeyboardContext.read(result.output) { return context }
        // Android 10 and older have no IME insets source in `dumpsys window displays`.
        let windows = try await command(["shell", "dumpsys window windows"])
        guard let context = KeyboardContext.readLegacy(windows.output, focusOutput: result.output) else { throw TypingError.keyboardHidden }
        return context
    }

    private func command(_ arguments: [String]) async throws -> CommandResult {
        try Task.checkCancellation()
        let process = try RunningCommand(adb, arguments: ["-s", serial] + arguments)
        let result = await process.result(timeout: 8)
        try Task.checkCancellation()
        guard result.status == 0 else { throw TypingError.commandFailed }
        return result
    }
}
