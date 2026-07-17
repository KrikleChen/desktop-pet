import Foundation

/// Pure text matching kept separate from Accessibility polling so the accepted
/// display names can be regression-tested without reading any UI content.
struct ChatNameMentionDetector {
    private let targetNames: [String]

    init(targetNames: [String] = ["成步堂龙一", "成步堂"]) {
        self.targetNames = targetNames.map {
            $0.precomposedStringWithCanonicalMapping
        }
    }

    func containsTarget(in text: String) -> Bool {
        let normalizedText = text.precomposedStringWithCanonicalMapping
        return targetNames.contains { normalizedText.contains($0) }
    }
}
