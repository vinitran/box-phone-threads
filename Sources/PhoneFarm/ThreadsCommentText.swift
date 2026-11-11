import Foundation

enum ThreadsCommentText {
    /// Applies only to comments: keep punctuation inside sentences, trim terminal dots.
    static func prepared(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = result.last, [".", "…", "。", "．"].contains(last) {
            result.removeLast()
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }
}
