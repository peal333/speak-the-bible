//  PersistenceManager.swift
import Foundation

class PersistenceManager {
    static let revealedVersesKey = "revealedVerseIdentifiers_v1"

    static func saveRevealedVerses(_ identifiers: Set<RevealedVerseIdentifier>) {
        do {
            let data = try JSONEncoder().encode(identifiers)
            UserDefaults.standard.set(data, forKey: revealedVersesKey)
        } catch {
            print("PersistenceManager: Error saving revealed verses: \(error)")
        }
    }

    static func loadRevealedVerses() -> Set<RevealedVerseIdentifier> {
        guard let data = UserDefaults.standard.data(forKey: revealedVersesKey) else {
            return []
        }
        do {
            let identifiers = try JSONDecoder().decode(Set<RevealedVerseIdentifier>.self, from: data)
            return identifiers
        } catch {
            print("PersistenceManager: Error loading revealed verses: \(error)")
            return [] // If decoding fails (e.g. due to structure change), return empty set.
        }
    }
}

