//  Enums.swift
import Foundation

enum BibleVersion: String, CaseIterable, Identifiable {
    //case nkjv = "NKJV"
    case kjv = "KJV"
    //case niv = "NIV"
    case web = "WEB"

    var id: String { self.rawValue }
    
    // Helper to get the filename, e.g., "KJV.json"
    var fileName: String { "\(self.rawValue).json" }
}

enum RecitationFlowState: Equatable {
    case idle, speaking, listening, checking, verseCorrect, verseIncorrect, completedAll, error(String)
    
    var isError: Bool {
        if case .error = self { return true }
        return false
    }

    var isActiveForCurrentVerse: Bool {
        switch self {
        case .speaking, .listening, .checking, .verseCorrect, .verseIncorrect: return true
        default: return false
        }
    }
}

enum RequiredAccuracy: String, CaseIterable, Codable, Identifiable {
    case none = "None"
    case low = "Low"
    case medium = "Medium"
    case high = "High"
    case exact = "Exact"

    var id: String { self.rawValue }
}

// Define a custom error for better context during loading
enum LoadError: Error, LocalizedError, Equatable { // Added Equatable for potential testing
    static func == (lhs: LoadError, rhs: LoadError) -> Bool {
        lhs.errorDescription == rhs.errorDescription // Simple comparison for this example
    }
    
    case fileNotFound(resourceName: String, bookFileName: String)
    case dataLoadingError(Error, resourceName: String, bookFileName: String)
    case decodingError(Error, resourceName: String, bookFileName: String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let resourceName, let bookFileName):
            return "Resource file \(resourceName).json (for book \(bookFileName)) not found."
        case .dataLoadingError(let underlyingError, let resourceName, let bookFileName):
            return "Failed to load data for \(resourceName).json (for book \(bookFileName)): \(underlyingError.localizedDescription)"
        case .decodingError(let underlyingError, let resourceName, let bookFileName):
            return "Failed to decode \(resourceName).json (for book \(bookFileName)): \(underlyingError.localizedDescription)"
        }
    }
}
