//  RecitationChecker.swift

import Foundation // Required for NumberFormatter

struct RecitationChecker {

    /// Result of a recitation check.
    struct CheckResult {
        enum MatchType {
            case noMatch
            case partialMatch // User recited some correct words/Soundex codes (non-sequentially), but not enough for a full match by the 66% rule.
            case fullMatch    // User recited the verse sufficiently well, meeting the non-sequential 66% threshold.
        }
        let type: MatchType
        /// For fullMatch, this is originalWordCount.
        /// For partialMatch or noMatch, it's the actual number of non-sequentially matched words.
        let matchedWordCount: Int
        let originalWordCount: Int // Total words in the original text (after normalization).
    }

    // Static NumberFormatter for converting cardinal numbers to words (e.g., "10" to "ten").
    // Standardized to "en_US" locale for consistent English spelling of numbers.
    private static let cardinalNumberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        formatter.locale = Locale(identifier: "en_US")
        return formatter
    }()

    // Regex for cardinal numbers:
    // 1. `\b\d{1,3}(?:,\d{3})*(?:\.\d+)?\b`: Matches numbers like "1,234", "1,234.56". (Integers with commas, optional decimal)
    // 2. `\b\d+\.\d+\b`: Matches numbers like "123.45". (Decimals without commas)
    // 3. `\b\d+\b`: Matches simple integers like "123". (Integers without commas or decimals)
    // `\b` ensures word boundaries.
    private static let cardinalNumberRegex = try! NSRegularExpression(
        pattern: #"\b\d{1,3}(?:,\d{3})*(?:\.\d+)?\b|\b\d+\.\d+\b|\b\d+\b"#
    )

    // Regex for ordinal numbers (e.g., "1st", "22nd", "10th").
    // Captures the numeric part in group 1.
    private static let ordinalRegex = try! NSRegularExpression(pattern: #"\b(\d+)(?:st|nd|rd|th)\b"#, options: .caseInsensitive)

    /// Custom function to convert an integer to its spelled-out ordinal English form.
    /// E.g., 1 -> "first", 21 -> "twenty-first".
    /// Falls back to cardinal spelling if specific ordinal rules are not met or for very large numbers.
    private static func getSpelledOutOrdinal(for number: Int) -> String? {
        guard let cardinal = cardinalNumberFormatter.string(from: NSNumber(value: number)) else {
            return nil // Cardinal conversion failed, cannot proceed.
        }

        // Handle numbers that have completely irregular ordinal forms or simple suffixes to their cardinal form.
        // These are usually small numbers.
        let simpleOrdinalMap: [String: String] = [
            "one": "first", "two": "second", "three": "third", "five": "fifth", "eight": "eighth", "nine": "ninth", "twelve": "twelfth"
        ]
        // Covers "one" through "twelve" and other simple cases.
        if let specificOrdinal = simpleOrdinalMap[cardinal] {
            return specificOrdinal
        }

        // For compound numbers like "twenty-one", "thirty-two", etc.
        // We need to check the original number to apply rules correctly, not just the string.
        if number % 100 >= 11 && number % 100 <= 19 { // 11-19 (eleventh, twelfth, thirteenth, etc.)
            if cardinal == "twelve" { return "twelfth" } // Should be caught by map, but good check.
             // Most numbers 11-19 just add "th" to cardinal, e.g. "eleven" -> "eleventh"
             // "Thirteenth", "Fourteenth", "Fifteenth", "Sixteenth", "Seventeenth", "Eighteenth", "Nineteenth"
             // The simple "cardinal + th" rule generally works for these, except for those already in simpleOrdinalMap.
             return cardinal + "th"
        }
        
        // Check last word for compound numbers like "twenty-one" -> "twenty-first"
        if let lastWordSeparator = cardinal.lastIndex(of: "-") {
            let prefix = String(cardinal[...lastWordSeparator]) // e.g., "twenty-"
            let lastCardinalWord = String(cardinal[cardinal.index(after: lastWordSeparator)...]) // e.g., "one"
            
            if let lastOrdinalWord = simpleOrdinalMap[lastCardinalWord] {
                return prefix + lastOrdinalWord // e.g., "twenty-" + "first"
            } else if lastCardinalWord.hasSuffix("y") { // e.g., "seventy" in "one hundred seventy" if it was the last part
                 return prefix + lastCardinalWord.dropLast() + "ieth"
            } else {
                 // Fallback for compound words where last part isn't special: append "th" to last part
                 return prefix + lastCardinalWord + "th"
            }
        }

        // For single-word cardinals not in simpleOrdinalMap (e.g., "twenty", "thirty", "four")
        if cardinal.hasSuffix("y") { // e.g., "twenty" -> "twentieth", "thirty" -> "thirtieth"
            return cardinal.dropLast() + "ieth"
        }
        
        // Default for other single-word cardinals: append "th"
        // e.g., "four" -> "fourth", "hundred" -> "hundredth"
        return cardinal + "th"
    }


    /// Generates a Soundex code for a given word.
    /// Soundex is a phonetic algorithm for indexing names by sound, as pronounced in English.
    /// - Parameter word: The word to encode.
    /// - Returns: A 4-character Soundex code (e.g., "R163").
    private func getSoundexCode(for word: String) -> String {
        guard !word.isEmpty else { return "" }

        let uppercasedWord = word.uppercased()
        let firstLetter = uppercasedWord.first!

        var soundex = "\(firstLetter)"
        var prevCode = getSoundexDigit(for: firstLetter)

        for char in uppercasedWord.dropFirst() {
            if soundex.count >= 4 { break }

            let code = getSoundexDigit(for: char)

            if code != "0" && code != prevCode {
                soundex.append(code)
            }
            if code != "0" {
                 prevCode = code
            } else {
                prevCode = "0"
            }
        }

        while soundex.count < 4 {
            soundex.append("0")
        }

        return String(soundex.prefix(4))
    }

    /// Helper for Soundex: maps a character to its Soundex digit.
    private func getSoundexDigit(for char: Character) -> Character {
        switch char {
        case "B", "F", "P", "V": return "1"
        case "C", "G", "J", "K", "Q", "S", "X", "Z": return "2"
        case "D", "T": return "3"
        case "L": return "4"
        case "M", "N": return "5"
        case "R": return "6"
        default: return "0" // Vowels (A, E, I, O, U), H, W, Y and others
        }
    }

    /// Checks the user's recitation against the original text.
    /// Determines if it's a full match, a partial match, or no match based on non-sequential word/Soundex comparison.
    func check(userRecitation: String, against originalText: String, accuracy: RequiredAccuracy) -> CheckResult {
        print("--- Recitation Check (Accuracy: \(accuracy.rawValue)) ---")
        print("Original Text (raw): \"\(originalText.prefix(100))\(originalText.count > 100 ? "..." : "")\"")
        print("User Recitation (raw): \"\(userRecitation.prefix(100))\(userRecitation.count > 100 ? "..." : "")\"")

        let originalWords = normalizeAndSplit(originalText)
        let recitedWords = normalizeAndSplit(userRecitation)

        print("Normalized Original Words (\(originalWords.count)): \(originalWords.prefix(10))\(originalWords.count > 10 ? "..." : "")")
        print("Normalized Recited Words (\(recitedWords.count)): \(recitedWords.prefix(10))\(recitedWords.count > 10 ? "..." : "")")
        
        if originalWords.isEmpty {
            let matchType = recitedWords.isEmpty ? CheckResult.MatchType.fullMatch : CheckResult.MatchType.noMatch
            print("Original text is empty. Result: \(matchType)")
            print("--- End Check ---")
            return CheckResult(type: matchType, matchedWordCount: 0, originalWordCount: 0)
        }

        var finalMatchedWordCount = 0

        if accuracy == .none {
            print("Matching mode: Direct word comparison (normalized), non-sequential.")
            var mutableRecitedWords = recitedWords
            for originalWord in originalWords {
                if let idx = mutableRecitedWords.firstIndex(of: originalWord) {
                    finalMatchedWordCount += 1
                    mutableRecitedWords.remove(at: idx)
                }
            }
        } else {
            let originalSoundexCodes = originalWords.map { getSoundexCode(for: $0) }
            var mutableRecitedSoundexCodesToConsume = recitedWords.map { getSoundexCode(for: $0) }
            let initialRecitedSoundexCodesForLog = recitedWords.map { getSoundexCode(for: $0) }

            let soundexMatchLength: Int
            switch accuracy {
            case .low: soundexMatchLength = 1
            case .medium: soundexMatchLength = 2
            case .high: soundexMatchLength = 3
            case .exact: soundexMatchLength = 4
            case .none:
                fatalError("RecitationChecker: .none accuracy should not reach Soundex comparison path.")
            }
            print("Matching mode: Soundex, non-sequential. Required prefix length: \(soundexMatchLength)")
            
            let originalSoundexDisplay = originalSoundexCodes.count > 5 ? Array(originalSoundexCodes.prefix(5)) + ["..."] : originalSoundexCodes
            let recitedSoundexDisplay = initialRecitedSoundexCodesForLog.count > 5 ? Array(initialRecitedSoundexCodesForLog.prefix(5)) + ["..."] : initialRecitedSoundexCodesForLog

            print("Original Soundex (first 5 if long): \(originalSoundexDisplay)")
            print("Recited Soundex (first 5 if long): \(recitedSoundexDisplay)")

            for originalCode in originalSoundexCodes {
                if originalCode.isEmpty { continue }
                if let idx = mutableRecitedSoundexCodesToConsume.firstIndex(where: { recitedCodeToCompare -> Bool in
                    if recitedCodeToCompare.isEmpty { return false }
                    return originalCode.count >= soundexMatchLength &&
                           recitedCodeToCompare.count >= soundexMatchLength &&
                           originalCode.prefix(soundexMatchLength) == recitedCodeToCompare.prefix(soundexMatchLength)
                }) {
                    finalMatchedWordCount += 1
                    mutableRecitedSoundexCodesToConsume.remove(at: idx)
                }
            }
        }
        
        print("Non-Sequential Matched Word Count: \(finalMatchedWordCount)")
        print("Original Word Count: \(originalWords.count)")

        let requiredMatchesForFullRecitation = Int(ceil(Double(originalWords.count) * 0.66))
        print("Required matches for Full Match: \(requiredMatchesForFullRecitation) (ceil(\(originalWords.count) * 0.66))")

        if finalMatchedWordCount >= requiredMatchesForFullRecitation && originalWords.count > 0 {
            print("Result: Full Match (met or exceeded \(requiredMatchesForFullRecitation) matches for 66% threshold)")
            print("--- End Check ---")
            return CheckResult(type: .fullMatch, matchedWordCount: originalWords.count, originalWordCount: originalWords.count)
        }
        
        let partialMatchMinPercentage = 0.25
        let partialMatchMinAbsoluteWords = 2
        
        let minPercentageWordsForPartial = Int(Double(originalWords.count) * partialMatchMinPercentage)
        let actualMinWordsNeededForPartial = max(partialMatchMinAbsoluteWords, minPercentageWordsForPartial)
        
        if finalMatchedWordCount >= actualMinWordsNeededForPartial && originalWords.count > 0 {
            print("Result: Partial Match (met partial match threshold: \(actualMinWordsNeededForPartial) words, but not full match 66% threshold)")
            print("--- End Check ---")
            return CheckResult(type: .partialMatch, matchedWordCount: finalMatchedWordCount, originalWordCount: originalWords.count)
        }

        print("Result: No Match (did not meet 66% full match threshold or partial match threshold)")
        print("--- End Check ---")
        return CheckResult(type: .noMatch, matchedWordCount: finalMatchedWordCount, originalWordCount: originalWords.count)
    }

    /// Normalizes text for comparison by:
    /// 1. Lowercasing.
    /// 2. Converting ordinal numbers (e.g., "10th" to "tenth") using custom logic.
    /// 3. Converting cardinal numbers (e.g., "123" to "one hundred twenty-three").
    /// 4. Folding diacritics (e.g., "é" to "e").
    /// 5. Removing all characters except for lowercase English letters and spaces.
    /// 6. Splitting the text into an array of words.
    public func normalizeAndSplit(_ text: String) -> [String] {
        var mutableText = text.lowercased()

        // 1. Ordinal Number Conversion (e.g., "10th" to custom "tenth")
        let ordinalMatches = RecitationChecker.ordinalRegex.matches(in: mutableText, options: [], range: NSRange(mutableText.startIndex..., in: mutableText)).reversed()

        for match in ordinalMatches {
            let fullOrdinalRange = Range(match.range, in: mutableText)! // e.g., range of "10th"
            let originalOrdinalString = String(mutableText[fullOrdinalRange])

            if match.numberOfRanges > 1, let numberPartRange = Range(match.range(at: 1), in: mutableText) {
                let numberString = String(mutableText[numberPartRange]) // e.g., "10"
                
                if let numberValue = Int(numberString) {
                    if let spelledOutOrdinal = RecitationChecker.getSpelledOutOrdinal(for: numberValue) {
                        mutableText.replaceSubrange(fullOrdinalRange, with: spelledOutOrdinal.lowercased())
                    } else {
                        // Fallback: Custom ordinal spell-out failed (e.g., cardinal itself failed).
                        // Replace "10th" with "10" so cardinal formatter can try.
                        print("RecitationChecker: Custom ordinal spell-out failed for '\(originalOrdinalString)'. Falling back to numeric part '\(numberString)'.")
                        mutableText.replaceSubrange(fullOrdinalRange, with: numberString)
                    }
                } else {
                    print("RecitationChecker: Could not parse ordinal number part '\(numberString)' to Int from '\(originalOrdinalString)'.")
                    // Leave original ordinal string (e.g., "10th") if its number part isn't an Int.
                }
            }
        }

        // 2. Cardinal Number Conversion
        let cardinalMatches = RecitationChecker.cardinalNumberRegex.matches(in: mutableText, options: [], range: NSRange(mutableText.startIndex..., in: mutableText)).reversed()

        for match in cardinalMatches {
            let numberStringRange = Range(match.range, in: mutableText)!
            let numberString = String(mutableText[numberStringRange])
            let cleanedNumberString = numberString.replacingOccurrences(of: ",", with: "")

            if let numberValue = Double(cleanedNumberString) {
                let nsNumber = NSNumber(value: numberValue)
                if let spelledOutNumber = RecitationChecker.cardinalNumberFormatter.string(from: nsNumber) {
                    mutableText.replaceSubrange(numberStringRange, with: spelledOutNumber.lowercased())
                } else {
                    print("RecitationChecker: Cardinal formatter failed for '\(cleanedNumberString)'.")
                }
            } else {
                print("RecitationChecker: Could not parse cardinal number string '\(cleanedNumberString)' to Double.")
            }
        }
        
        // 3. Fold diacritics
        let foldedText = mutableText
            .folding(options: .diacriticInsensitive, locale: .current)
        
        // 4. Remove non-alphabetic characters, replace with space
        let characterCleanedText = foldedText
            .replacingOccurrences(of: #"[^a-z\s]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // 5. Split into words
        return characterCleanedText.split { $0.isWhitespace }.map(String.init).filter { !$0.isEmpty }
    }
}
