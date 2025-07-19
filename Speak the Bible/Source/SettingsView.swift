//  SettingsView.swift
import SwiftUI
import AVFoundation // Required for AVSpeechSynthesisVoice and utterance rate constants

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared // Use the singleton instance
    @Environment(\.dismiss) var dismiss
    
    // State to manage the confirmation dialog
    @State private var showingClearHistoryAlert = false
    // State to hold available voices
    @State private var availableVoices: [AVSpeechSynthesisVoice] = []

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Bible")) { // New Bible Section
                    Picker("Version", selection: $settings.selectedBibleVersion) {
                        ForEach(BibleVersion.allCases) { version in
                            Text(version.rawValue).tag(version)
                        }
                    }
                }
                
                Section(header: Text("Recitation")) {
                    Toggle("Hide verse while reciting", isOn: $settings.hideVerseWhileReciting)
                    Toggle("Hide unrecited verses", isOn: $settings.blurUnrecitedVerses)
                    Toggle("Hide spoken words", isOn: $settings.hideSpokenWords) // New Toggle for spoken words
                    Picker("Accuracy checking", selection: $settings.requiredAccuracy) {
                        ForEach(RequiredAccuracy.allCases) { accuracy in
                            Text(accuracy.rawValue).tag(accuracy)
                        }
                    }
                    Stepper("Word limit: \(settings.wordLimitForRecitationChunk)", value: $settings.wordLimitForRecitationChunk, in: 3...30)
                    Button("Clear", role: .destructive) {
                        showingClearHistoryAlert = true
                    }
                }
                
                Section(header: Text("Text-to-Speech")) {
                    Picker("Voice", selection: $settings.selectedVoiceIdentifier) {
                        Text("System Default").tag("") // Option for default voice
                        ForEach(availableVoices, id: \.identifier) { voice in
                            Text("\(voice.name) (\(voice.language))")
                                .tag(voice.identifier as String?) // Cast to String? to match selection type
                        }
                    }
                    .onAppear {
                        // Fetch available voices when the view appears
                        self.availableVoices = AVSpeechSynthesisVoice.speechVoices()
                                            .sorted { $0.name < $1.name } // Sort for better presentation
                    }
                    
                    VStack(alignment: .leading) {
                        Text("Rate: \(String(format: "%.2f", settings.utteranceRate))")
                        Slider(
                            value: $settings.utteranceRate,
                            in: Double(AVSpeechUtteranceMinimumSpeechRate)...Double(AVSpeechUtteranceMaximumSpeechRate),
                            step: 0.05 // Adjust step for finer control if needed
                        )
                    }
                }

            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            // Add the confirmation alert
            .alert("Starting over?", isPresented: $showingClearHistoryAlert) {
                Button("Continue", role: .destructive) {
                    // Action to clear the verse history
                    PersistenceManager.saveRevealedVerses([])
                    // Optionally, you could add a notification or feedback to the user here
                    // For example, if you have a global way to refresh data or notify other views
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("All recited verses will be cleared.\nAre you sure you want to continue?")
            }
        }
    }
}
