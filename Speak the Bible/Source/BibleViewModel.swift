//  BibleViewModel.swift
import SwiftUI
import Combine

class BibleViewModel: ObservableObject { // Renamed from ParagraphViewModel
    // --- Book List Properties ---
    @Published var books: [Book] = []
    @Published var isLoadingBooks: Bool = false // True while loading the main version JSON
    @Published var bookListLoadingError: String? = nil // For errors loading main version JSON

    // --- Selected Book & Content Properties ---
    @Published var selectedBook: Book?
    @Published var isContentLoading: Bool = false // True during transformation of book data
    @Published var contentLoadingError: LoadError? = nil // Specific error for content transformation

    // --- Loaded Content Properties ---
    @Published var verses: [Verse] = [] // All items for the selected book (Renamed from paragraphs)
    @Published var availableChapters: [Int] = [] // Unique chapter numbers for the selected book
    
    // currentChapterNumber now has a didSet to save its value to AppSettings
    @Published var currentChapterNumber: Int? = nil {
        didSet {
            guard let chapNum = currentChapterNumber else { return; }
            
            AppSettings.shared.lastSavedChapterNumber = chapNum
        }
    }
    @Published var versesForCurrentChapter: [Verse] = [] // Verses for the current chapter (Type changed to Verse)

    // --- Internal State ---
    private var rawBibleDataForCurrentVersion: [String: [String: [String: String]]]? // Stores data for the entire selected Bible version
    private var loadVersionDataCancellable: AnyCancellable?
    private var appSettingsObserver: AnyCancellable?
    private var chapterUpdateCancellable: AnyCancellable?
    private let appSettings = AppSettings.shared // Direct access to AppSettings singleton

    init() {
        // Subscribe to changes in selectedBibleVersion from AppSettings
        appSettingsObserver = AppSettings.shared.objectWillChange
            .map { _ in AppSettings.shared.selectedBibleVersion }
            .removeDuplicates()
            .dropFirst() // Avoid running on initial BVM loads on its own init
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (newVersion: BibleVersion) in
                print("BibleViewModel: Detected Bible version change to \(newVersion.rawValue). Reloading book list.")
                self?.loadBibleBooksList() // This will trigger restoration for the new version
            }

        // Combine pipeline to update versesForCurrentChapter when verses or currentChapterNumber changes
        chapterUpdateCancellable = Publishers.CombineLatest($verses, $currentChapterNumber) // Changed from $paragraphs
            .map { verses, chapterNumber in // Changed from paragraphs
                guard let chapterNum = chapterNumber else { return [] }
                return verses.filter { $0.chapterNumber == chapterNum && $0.isRecitable }
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newVersesForChapter in
                self?.versesForCurrentChapter = newVersesForChapter
            }
    }

    // --- Book List Management (Loads entire version, extracts book list) ---
    func loadBibleBooksList() {
        updateMainThreadState {
            $0.isLoadingBooks = true
            $0.bookListLoadingError = nil
            $0.books = []
            // $0.selectedBook = nil // Keep selectedBook to see if it exists in new version, reset later if not found
            // $0.verses = [] // Reset these when a book is actually selected or if no book can be restored (Changed from paragraphs)
            // $0.availableChapters = []
            // $0.currentChapterNumber = nil // Keep to try and restore chapter
            // $0.versesForCurrentChapter = []
            $0.rawBibleDataForCurrentVersion = nil
            $0.isContentLoading = false // Should be false until a book starts loading its content
            $0.contentLoadingError = nil
        }

        let version = appSettings.selectedBibleVersion
        let resourceName = version.rawValue

        loadVersionDataCancellable?.cancel()
        loadVersionDataCancellable = Just(resourceName)
            .subscribe(on: DispatchQueue.global(qos: .userInitiated))
            .tryMap { rn -> (data: Data, resourceName: String) in
                guard let url = Bundle.main.url(forResource: rn, withExtension: "json") else {
                    throw LoadError.fileNotFound(resourceName: rn, bookFileName: rn)
                }
                do {
                    let data = try Data(contentsOf: url)
                    return (data, rn)
                } catch {
                    throw LoadError.dataLoadingError(error, resourceName: rn, bookFileName: rn)
                }
            }
            .tryMap { (data, rn) -> [String: [String: [String: String]]] in
                do {
                    let bibleData = try JSONDecoder().decode([String: [String: [String: String]]].self, from: data)
                    return bibleData
                } catch {
                    throw LoadError.decodingError(error, resourceName: rn, bookFileName: rn)
                }
            }
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { [weak self] completion in
                guard let self = self else { return }
                self.isLoadingBooks = false
                if case .failure(let error) = completion {
                    let loadError = error as? LoadError ?? .decodingError(error, resourceName: resourceName, bookFileName: resourceName)
                    self.bookListLoadingError = loadError.localizedDescription
                    self.rawBibleDataForCurrentVersion = nil
                    // Clear all book-related data on failure
                    self.books = []
                    self.selectedBook = nil
                    self.verses = [] // Changed from paragraphs
                    self.availableChapters = []
                    self.currentChapterNumber = nil // This will save nil to AppSettings
                    self.versesForCurrentChapter = []
                    print("BibleViewModel: Error loading version \(resourceName).json: \(loadError.localizedDescription)")
                }
            }, receiveValue: { [weak self] bibleData in
                guard let self = self else { return }
                self.rawBibleDataForCurrentVersion = bibleData
                let bookNames = bibleData.keys.sorted()
                self.books = bookNames.map { Book(name: $0) } // Assuming file is the same as name key

                if self.books.isEmpty {
                    self.bookListLoadingError = "No books found in \(resourceName).json."
                    // Clear selection if no books
                    self.selectedBook = nil
                    self.verses = [] // Changed from paragraphs
                    self.availableChapters = []
                    self.currentChapterNumber = nil // Will save nil
                    self.versesForCurrentChapter = []
                } else {
                    self.bookListLoadingError = nil
                    // Attempt to restore or default book and chapter
                    let savedBookName = self.appSettings.lastSavedBookName // Changed from lastSavedBookFile
                    let savedChapterNumber = self.appSettings.lastSavedChapterNumber
                    let defaultBookName = "Mark" // Changed from defaultBookFileName
                    
                    var bookToSelect: Book? = nil

                    if let foundBook = self.books.first(where: { $0.name == savedBookName }) { // Changed from savedBookFile
                        bookToSelect = foundBook
                    } else if let markBook = self.books.first(where: { $0.name.caseInsensitiveCompare(defaultBookName) == .orderedSame }) { // Changed from defaultBookFileName
                        bookToSelect = markBook
                    } else if !self.books.isEmpty {
                        bookToSelect = self.books.first
                    }

                    if let book = bookToSelect {
                        // Pass savedChapterNumber; selectBookAndLoadContent will validate it
                        self.selectBookAndLoadContent(book, initiallySelectedChapter: savedChapterNumber)
                    } else {
                        // No book could be selected (e.g., books list became empty after filtering, though unlikely here)
                        // Ensure clean state if somehow no book is selected.
                        self.selectedBook = nil
                        self.verses = [] // Changed from paragraphs
                        self.availableChapters = []
                        self.currentChapterNumber = nil // Will save nil
                        self.versesForCurrentChapter = []
                    }
                }
                print("BibleViewModel: Loaded \(self.books.count) books from \(resourceName).json for version \(resourceName).")
            })
    }

    // --- Book Content Management (Transforms data from loaded version) ---
    func selectBookAndLoadContent(_ book: Book, initiallySelectedChapter: Int? = nil) {
        appSettings.lastSavedBookName = book.name // Changed from lastSavedBookFile

        updateMainThreadState {
            $0.selectedBook = book
            $0.verses = [] // Changed from paragraphs
            $0.availableChapters = []
            // $0.currentChapterNumber = nil // Don't reset here; it will be set based on initiallySelectedChapter or default
            $0.versesForCurrentChapter = []
            $0.isContentLoading = true
            $0.contentLoadingError = nil
        }

        DispatchQueue.global(qos: .userInitiated).async {
            guard let fullBibleData = self.rawBibleDataForCurrentVersion else {
                self.updateMainThreadState {
                    $0.contentLoadingError = .fileNotFound(resourceName: self.appSettings.selectedBibleVersion.rawValue, bookFileName: book.name)
                    $0.isContentLoading = false
                }
                return
            }

            guard let chaptersData = fullBibleData[book.name] else {
                self.updateMainThreadState {
                    $0.contentLoadingError = .fileNotFound(resourceName: book.name, bookFileName: "data for \(book.name) in \(self.appSettings.selectedBibleVersion.rawValue)")
                    $0.isContentLoading = false
                }
                return
            }

            var newVerses: [Verse] = [] // Renamed from newParagraphItems, type changed to Verse
            let sortedChapterKeys = chaptersData.keys.compactMap { Int($0) }.sorted()

            for chapterKeyInt in sortedChapterKeys {
                let chapterKeyString = String(chapterKeyInt)
                guard let versesData = chaptersData[chapterKeyString] else { continue }
                let sortedVerseKeys = versesData.keys.compactMap { Int($0) }.sorted()
                for verseKeyInt in sortedVerseKeys {
                    let verseKeyString = String(verseKeyInt)
                    guard let verseText = versesData[verseKeyString] else { continue }
                    let verseItem = Verse(chapterNumber: chapterKeyInt, verseNumber: verseKeyInt, value: verseText) // Changed to Verse
                    newVerses.append(verseItem)
                }
            }
            
            let uniqueChapters = Array(Set(newVerses.compactMap { $0.chapterNumber })).sorted()

            self.updateMainThreadState {
                $0.verses = newVerses // Changed from paragraphs
                $0.availableChapters = uniqueChapters
                
                var chapterToSet: Int? = nil
                let defaultBookNameForChapterLogic = "Mark" // Changed from defaultBookFileNameForChapterLogic
                let defaultChapterForMark = 1

                if let initialChapter = initiallySelectedChapter, uniqueChapters.contains(initialChapter) {
                    chapterToSet = initialChapter
                } else if book.name.caseInsensitiveCompare(defaultBookNameForChapterLogic) == .orderedSame && uniqueChapters.contains(defaultChapterForMark) { // Changed
                    chapterToSet = defaultChapterForMark
                } else if !uniqueChapters.isEmpty {
                    chapterToSet = uniqueChapters.first
                }
                // This assignment will trigger currentChapterNumber.didSet, saving to AppSettings
                $0.currentChapterNumber = chapterToSet
                
                $0.isContentLoading = false
                if newVerses.isEmpty && !chaptersData.isEmpty {
                    print("BibleViewModel: No verse items generated for \(book.name), though chapter data might exist.")
                } else if newVerses.isEmpty && chaptersData.isEmpty {
                     print("BibleViewModel: Book \(book.name) is empty (no chapters/verses found in data).")
                } else {
                    print("BibleViewModel: Transformed \(newVerses.count) items for \(book.name). Available chapters: \(uniqueChapters.count). Current chapter set to: \($0.currentChapterNumber ?? -1).")
                }
            }
        }
    }
    
    // --- Chapter Management ---
    // This method is called by RecitationManager to inform BVM of the chapter of the current reciting verse.
    func updateCurrentChapter(for verse: Verse?) { // Parameter type changed to Verse
        let newChapter = verse?.chapterNumber
        if self.currentChapterNumber != newChapter {
            updateMainThreadState {
                $0.currentChapterNumber = newChapter // Triggers didSet, saves to AppSettings
            }
        }
    }
    
    // Method to allow explicit chapter selection, e.g., from a picker or swipe.
    func selectChapter(_ chapterNumber: Int?) {
        if self.currentChapterNumber != chapterNumber {
            updateMainThreadState {
                $0.currentChapterNumber = chapterNumber // Triggers didSet, saves to AppSettings
                print("BibleViewModel: Selected chapter: \(String(describing: chapterNumber))")
            }
        }
    }

    private func updateMainThreadState(updates: @escaping (BibleViewModel) -> Void) { // Parameter type changed
        if Thread.isMainThread {
            updates(self)
        } else {
            DispatchQueue.main.async { updates(self) }
        }
    }
}
