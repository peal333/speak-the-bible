//  AppSettings.swift
import SwiftUI
import AVFoundation // Required for AVSpeechSynthesisVoice and utterance rate constants

// MARK: - App Settings (New)
class AppSettings: ObservableObject {
    static let shared = AppSettings() // Singleton instance

    @AppStorage("hideVerseWhileReciting") var hideVerseWhileReciting: Bool = false
    @AppStorage("blurUnrecitedVerses") var blurUnrecitedVerses: Bool = false // New setting
    @AppStorage("hideSpokenWords") var hideSpokenWords: Bool = false // New setting for spoken words visibility
    @AppStorage("selectedVoiceIdentifier") var selectedVoiceIdentifier: String = ""
    @AppStorage("utteranceRate") var utteranceRate: Double = Double(AVSpeechUtteranceDefaultSpeechRate)
    @AppStorage("requiredAccuracy") var requiredAccuracy: RequiredAccuracy = .low // New setting
    @AppStorage("wordLimitForRecitationChunk") var wordLimitForRecitationChunk: Int = 12 // New setting for word limit
    @AppStorage("selectedBibleVersion") var selectedBibleVersion: BibleVersion = .kjv // New setting for Bible version

    // Properties for saving last selected book and chapter
    @AppStorage("lastSavedBookName") var lastSavedBookName: String = "" // Changed from lastSavedBookFile
    @AppStorage("lastSavedChapterNumber") var lastSavedChapterNumber: Int = 1

    private init() {} // Private initializer for singleton
}
