//
//  Models.swift
//  Speak the Bible
//
//  Created by Panupan Sriautharawong on 25/5/25.
//

import SwiftUI
import Foundation
import Combine

struct RevealedVerseIdentifier: Codable, Hashable {
    let bookName: String // Changed from bookFileName
    let chapterNumber: Int
    let verseNumber: Int
}

struct Book: Codable, Identifiable, Hashable {
    let name: String
    var id: String { name }
}

struct Verse: Codable, Identifiable { // Renamed from ParagraphItem
    let id = UUID()
    let chapterNumber: Int?
    let verseNumber: Int?
    let value: String? // The text of the verse

    enum CodingKeys: String, CodingKey { case chapterNumber, verseNumber, value }

    var isRecitable: Bool {
        guard let val = value, !val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return true
    }
    
    // Convenience for display
    var identifierLabel: String {
        let ch = chapterNumber ?? 0
        let vn = verseNumber ?? 0
        return "\(ch):\(vn)"
    }
}
