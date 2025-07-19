// RecitationTokenizer

import Foundation

public struct WordUnit: Equatable {
    public let originalTextSpan: String
    public let normalizedWords: [String]
    public var validWordCount: Int { normalizedWords.count }
    public let endsWithSentenceTerminator: Bool
    public let endsWithClauseTerminator: Bool

    public init(originalTextSpan: String, normalizedWords: [String], endsWithSentenceTerminator: Bool, endsWithClauseTerminator: Bool) {
        self.originalTextSpan = originalTextSpan
        self.normalizedWords = normalizedWords
        self.endsWithSentenceTerminator = endsWithSentenceTerminator
        self.endsWithClauseTerminator = endsWithClauseTerminator
    }

    public static func == (lhs: WordUnit, rhs: WordUnit) -> Bool {
        return lhs.originalTextSpan == rhs.originalTextSpan &&
               lhs.normalizedWords == rhs.normalizedWords &&
               lhs.endsWithSentenceTerminator == rhs.endsWithSentenceTerminator &&
               lhs.endsWithClauseTerminator == rhs.endsWithClauseTerminator
    }
}

public struct RecitationTokenizer {

    public static func tokenizeVerse(
        verseText: String?,
        wordLimitForChunk: Int,
        normalizeFunction: @escaping (String) -> [String] // Marked as @escaping
    ) -> (wordUnits: [WordUnit], totalValidWords: Int) {
        
        guard let fullVerseText = verseText, !fullVerseText.isEmpty else {
            return (wordUnits: [], totalValidWords: 0)
        }

        var units: [WordUnit] = []
        var currentUnitStartIndex = fullVerseText.startIndex
        var accumulatedNormalizedWordsForUnit: [String] = []
        var lastProcessedWordOriginalEndIndex = fullVerseText.startIndex
        
        fullVerseText.enumerateSubstrings(in: fullVerseText.startIndex..<fullVerseText.endIndex, options: [.byWords, .localized]) { (wordSubstring, wordRange, enclosingRange, stop) in
            
            guard let word = wordSubstring else { return }
            let normalizedFromWord = normalizeFunction(word)

            if !normalizedFromWord.isEmpty {
                accumulatedNormalizedWordsForUnit.append(contentsOf: normalizedFromWord)
            }
            lastProcessedWordOriginalEndIndex = wordRange.upperBound

            var unitShouldEndDueToPunctuation = false
            var endsWithSentence = false
            var endsWithClause = false
            var unitActualEndIndexIncludingPunctuation = wordRange.upperBound

            // Check character *after* the current word for punctuation that might belong to this word's chunk
            if wordRange.upperBound < fullVerseText.endIndex {
                let charAfterWord = fullVerseText[wordRange.upperBound]
                if ".?!".contains(charAfterWord) {
                    unitShouldEndDueToPunctuation = true
                    endsWithSentence = true
                    // Include the punctuation in the originalTextSpan
                    unitActualEndIndexIncludingPunctuation = fullVerseText.index(after: wordRange.upperBound)
                } else if ",;:".contains(charAfterWord) {
                    unitShouldEndDueToPunctuation = true
                    endsWithClause = true
                    // Include the punctuation in the originalTextSpan
                    unitActualEndIndexIncludingPunctuation = fullVerseText.index(after: wordRange.upperBound)
                }
            } else { // This is the last word in the verse text
                unitShouldEndDueToPunctuation = true // Always end unit after last word
                // Check the last character of the word itself, or assume sentence end
                if let lastCharOfWord = word.last {
                    if ".?!".contains(lastCharOfWord) {
                        endsWithSentence = true
                    } else if ",;:".contains(lastCharOfWord) {
                        endsWithClause = true
                    } else {
                        endsWithSentence = true // Default to sentence end if no specific punctuation
                    }
                } else {
                     endsWithSentence = true // Should not happen if word is not nil/empty
                }
            }

            if !accumulatedNormalizedWordsForUnit.isEmpty &&
                (unitShouldEndDueToPunctuation || accumulatedNormalizedWordsForUnit.count >= wordLimitForChunk) {
                
                // Determine the correct end index for the original text span
                let textSpanEndIndex = unitShouldEndDueToPunctuation ? unitActualEndIndexIncludingPunctuation : lastProcessedWordOriginalEndIndex
                let textSpanRange = currentUnitStartIndex..<textSpanEndIndex
                let textSpan = String(fullVerseText[textSpanRange])
                
                let unit = WordUnit(
                    originalTextSpan: textSpan.trimmingCharacters(in: .whitespacesAndNewlines), // Trim spaces, newlines from span
                    normalizedWords: accumulatedNormalizedWordsForUnit,
                    endsWithSentenceTerminator: endsWithSentence,
                    endsWithClauseTerminator: endsWithClause && !endsWithSentence // Clause only if not sentence
                )
                units.append(unit)
                
                currentUnitStartIndex = textSpanEndIndex // Next unit starts after the consumed span
                accumulatedNormalizedWordsForUnit.removeAll()
            }
        }
        
        // Handle any remaining words that didn't form a full chunk or end with punctuation
        if !accumulatedNormalizedWordsForUnit.isEmpty {
             // The range for the last text span should go up to the last processed word's end index
             let textSpanRange = currentUnitStartIndex..<lastProcessedWordOriginalEndIndex
             let textSpan = String(fullVerseText[textSpanRange])
             
             var endsWithSentence = false
             var endsWithClause = false
             // Determine punctuation for the very last chunk based on its content
             if let lastChar = textSpan.trimmingCharacters(in: .whitespacesAndNewlines).last {
                 if ".?!".contains(lastChar) {
                     endsWithSentence = true
                 } else if ",;:".contains(lastChar) {
                     endsWithClause = true
                 } else {
                     endsWithSentence = true // Default to sentence end
                 }
             } else {
                 endsWithSentence = true // Default if span is empty or only whitespace (though guarded by !accumulatedNormalizedWordsForUnit.isEmpty)
             }

             let unit = WordUnit(
                 originalTextSpan: textSpan.trimmingCharacters(in: .whitespacesAndNewlines),
                 normalizedWords: accumulatedNormalizedWordsForUnit,
                 endsWithSentenceTerminator: endsWithSentence,
                 endsWithClauseTerminator: endsWithClause && !endsWithSentence
             )
             units.append(unit)
        }

        let totalValidWords = units.reduce(0) { $0 + $1.validWordCount }
        return (wordUnits: units, totalValidWords: totalValidWords)
    }
}
