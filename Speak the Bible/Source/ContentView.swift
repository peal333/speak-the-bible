// ContentView.swift
import SwiftUI

struct ContentView: View {
    @StateObject var bibleViewModel: BibleViewModel // Renamed from paragraphViewModel
    @StateObject var speechServiceManager: SpeechServiceManager
    @StateObject private var recitationManager: RecitationManager
    @ObservedObject private var settings = AppSettings.shared

    @State private var showingSettingsSheet = false
    
    // State for debounced button active status
    @State private var displayIsRecitationActive: Bool = false
    @State private var debounceTimer: Timer? = nil

    init() {
        let bvm = BibleViewModel() // Renamed from pvm
        let ssm = SpeechServiceManager()
        let rm = RecitationManager(
            speechServiceManager: ssm,
            recitationChecker: RecitationChecker(),
            bibleViewModel: bvm // Renamed from paragraphViewModel
        )

        _bibleViewModel = StateObject(wrappedValue: bvm) // Renamed from _paragraphViewModel
        _speechServiceManager = StateObject(wrappedValue: ssm)
        _recitationManager = StateObject(wrappedValue: rm)
    }

    private var currentBookDisplayName: String {
        bibleViewModel.selectedBook?.name ?? (bibleViewModel.books.isEmpty && !bibleViewModel.isLoadingBooks ? "No Books" : "Select Book")
    }

    private var recognizedTextDisplay: String {
        speechServiceManager.recognizedText.isEmpty && !recitationManager.isRecitationActive && recitationManager.flowState == .idle ?
            "" : speechServiceManager.recognizedText
    }

    private var mainButtonDisabled: Bool {
        (bibleViewModel.versesForCurrentChapter.isEmpty && !recitationManager.isRecitationActive) ||
        bibleViewModel.books.isEmpty ||
        bibleViewModel.isLoadingBooks ||
        bibleViewModel.isContentLoading
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                StatusHeaderView(statusMessage: recitationManager.statusMessage)
                
                Divider()

                ZStack(alignment: .bottom) {
                    VerseScrollView(
                        recitationManager: recitationManager,
                        bibleViewModel: bibleViewModel, // Renamed from paragraphViewModel
                        isLoadingContent: bibleViewModel.isContentLoading,
                        currentBookDisplayName: currentBookDisplayName
                    )

                    FloatingRecitationButton(
                        isRecitationActive: displayIsRecitationActive, // Use debounced state
                        isDisabled: mainButtonDisabled,
                        action: recitationManager.handleMainButtonTap
                    )
                    .padding(.bottom, 40)
                }.edgesIgnoringSafeArea(.bottom)

                if !settings.hideSpokenWords {
                    Divider()
                    
                    RecognitionControlsView(
                        recognizedTextDisplay: recognizedTextDisplay,
                        speechServiceManager: speechServiceManager
                    )
                }
            }
            .toolbar {
                ContentViewToolbar(
                    bibleViewModel: bibleViewModel, // Renamed from paragraphViewModel
                    recitationManager: recitationManager,
                    showingSettingsSheet: $showingSettingsSheet
                )
            }
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .onAppear {
            // Initial setup for displayIsRecitationActive if not done in init or if RM state could change before appear
            displayIsRecitationActive = recitationManager.isRecitationActive
            
            bibleViewModel.loadBibleBooksList()
            speechServiceManager.requestSTTAuthorization()
        }
        .onChange(of: recitationManager.isRecitationActive) { newIsActive in
            debounceTimer?.invalidate() // Cancel any existing timer

            if newIsActive {
                displayIsRecitationActive = true // Update immediately if becoming active
            } else {
                // If becoming inactive, start a timer to update the display state
                debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { _ in
                    // Only update if the manager's state is still inactive
                    if !recitationManager.isRecitationActive {
                        displayIsRecitationActive = false
                    }
                }
            }
        }
        .sheet(isPresented: $showingSettingsSheet, onDismiss: {
            recitationManager.refreshRevealedStatus()
        }) {
            SettingsView()
        }
        .onChange(of: bibleViewModel.books) { newBooksList in
            if newBooksList.isEmpty && !bibleViewModel.isLoadingBooks && bibleViewModel.bookListLoadingError == nil {
                 recitationManager.statusMessage = "No books found."
                 recitationManager.flowState = .error("NoBooksFound")
                 recitationManager.updateWithNewBookData(verses: [], bookDisplayName: "No books found.", initialStatus: "No books found.")
            }
        }
        .onChange(of: bibleViewModel.selectedBook) { newSelectedBook in
            if let book = newSelectedBook, bibleViewModel.isContentLoading {
                recitationManager.statusMessage = "Loading \(book.name)..."
            }
        }
        .onReceive(bibleViewModel.$verses) { allBookVerses in // Changed from $paragraphs
            guard let currentBook = bibleViewModel.selectedBook else {
                let statusMsg: String
                let flowErr: String
                if let listError = bibleViewModel.bookListLoadingError {
                    statusMsg = listError; flowErr = "BookListLoadError"
                } else if bibleViewModel.books.isEmpty && !bibleViewModel.isLoadingBooks {
                    statusMsg = "No books available."; flowErr = "NoBooksAvailable"
                } else {
                    statusMsg = "Please select a book."; flowErr = "NoBookSelected"
                }
                recitationManager.statusMessage = statusMsg
                recitationManager.flowState = .error(flowErr)
                recitationManager.updateWithNewBookData(verses: [], bookDisplayName: statusMsg, initialStatus: statusMsg)
                return
            }

            let statusForRMUpdate: String
            if let contentErr = bibleViewModel.contentLoadingError {
                statusForRMUpdate = contentErr.localizedDescription
                recitationManager.statusMessage = statusForRMUpdate
                recitationManager.flowState = .error("ContentLoadFailed: \(currentBook.name)")
            } else {
                statusForRMUpdate = ""
            }

            recitationManager.updateWithNewBookData(
                verses: allBookVerses,
                bookDisplayName: currentBook.name,
                initialStatus: statusForRMUpdate
            )
        }
        .onChange(of: bibleViewModel.bookListLoadingError) { errorMsg in
            if let error = errorMsg {
                recitationManager.statusMessage = error
                recitationManager.flowState = .error("BookListLoadError")
            }
        }
    }
}
