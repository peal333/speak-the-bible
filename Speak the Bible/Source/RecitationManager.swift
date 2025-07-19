// RecitationManager.swift

import Foundation
import SwiftUI
import Combine

class RecitationManager: ObservableObject {
    // Dependencies
    private let speechServiceManager: SpeechServiceManager
    private let recitationChecker: RecitationChecker
    private var bibleViewModel: BibleViewModel // Renamed from paragraphViewModel
    // AppSettings is accessed via AppSettings.shared

    // Published State for UI
    @Published var flowState: RecitationFlowState = .idle
    @Published var isRecitationActive: Bool = false
    @Published var statusMessage: String = "Initializing..."
    @Published var currentRecitableItemIndex: Int = 0 // Index within currentBookContentVerses
    @Published var revealedInCurrentBookItemIDs: Set<UUID> = [] // Stores UUIDs of Verse
    @Published var userRecitedTextForDisplay: String = ""

    // Internal State for Chunk-by-Chunk Recitation
    // WordUnit is now defined in RecitationTokenizer.swift
    private var verseWordUnits: [WordUnit] = []
    private var currentWordUnitIndex: Int = 0
    
    private var currentVerseRecitedWordCount: Int = 0
    private var totalValidWordsInCurrentVerse: Int = 0

    // Other Internal State
    private var currentBookContentVerses: [Verse] = [] // All verses for the currently selected book (Type changed to Verse)
    private var currentBookDisplayName: String = ""
    private var allPersistedRevealedIdentifiers: Set<RevealedVerseIdentifier> = []
    private var cancellables = Set<AnyCancellable>()
    private var bvmChapterObserver: AnyCancellable? // Renamed from pvmChapterObserver


    init(speechServiceManager: SpeechServiceManager,
         recitationChecker: RecitationChecker,
         bibleViewModel: BibleViewModel) { // Renamed parameter
        self.speechServiceManager = speechServiceManager
        self.recitationChecker = recitationChecker
        self.bibleViewModel = bibleViewModel // Renamed assignment
        
        self.allPersistedRevealedIdentifiers = PersistenceManager.loadRevealedVerses()
        setupSpeechServiceCallbacks()
        
        // Observe changes to BibleViewModel's currentChapterNumber
        bvmChapterObserver = bibleViewModel.$currentChapterNumber // Renamed from paragraphViewModel
            .removeDuplicates()
            .dropFirst() // Avoid acting on initial BVM setup or RM's own immediate changes if possible
            .sink { [weak self] newChapterNumber in
                guard let self = self else { return }

                guard let chapterNum = newChapterNumber else {
                    if self.isRecitationActive {
                         self.stopRecitationProcessInternal(preserveError: false, preserveMessage: true) {
                            self.statusMessage = "Chapter selection cleared."
                         }
                    }
                    return
                }

                let currentRecitingVerseChapter = self.currentRecitingVerse?.chapterNumber // Renamed from currentRecitingItem
                
                if self.isRecitationActive && currentRecitingVerseChapter == chapterNum { // Renamed from currentRecitingItem
                    return
                }
                
                print("RecitationManager: Detected chapter change to \(chapterNum) via BVM observer (swipe/picker/jump).")
                self.handleExternalChapterChange(to: chapterNum)
            }
        cancellables.insert(bvmChapterObserver!)
    }

    var currentRecitingVerse: Verse? { // Renamed from currentRecitingItem, type changed to Verse
        guard currentRecitableItemIndex >= 0, currentRecitableItemIndex < currentBookContentVerses.count else { return nil }
        return currentBookContentVerses[currentRecitableItemIndex]
    }
    
    private var currentBookName: String? { // Renamed from currentBookFileName
        bibleViewModel.selectedBook?.name
    }
    
    private func resetVerseProgressState() {
        currentVerseRecitedWordCount = 0
        totalValidWordsInCurrentVerse = 0
        verseWordUnits.removeAll()
        currentWordUnitIndex = 0
    }

    // verses here are ALL verses for the book from BVM.verses
    // bookFileName parameter removed
    func updateWithNewBookData(verses: [Verse], bookDisplayName: String, initialStatus: String = "") {
        self.currentBookContentVerses = verses
        self.currentBookDisplayName = bookDisplayName // This is set from bibleViewModel.selectedBook.name by caller
        
        resetVerseProgressState()
        
        if self.isRecitationActive {
            stopRecitationProcessInternal(preserveError: false, preserveMessage: false) { [weak self] in
                self?.finishBookUpdate(initialStatus: initialStatus)
            }
        } else {
            finishBookUpdate(initialStatus: initialStatus)
        }
    }

    private func finishBookUpdate(initialStatus: String) {
        self.isRecitationActive = false
        self.flowState = .idle
        self.userRecitedTextForDisplay = ""
        self.speechServiceManager.recognizedText = ""

        self.allPersistedRevealedIdentifiers = PersistenceManager.loadRevealedVerses()
        repopulateRevealedItemIDsForCurrentBook()

        self.currentRecitableItemIndex = 0
        
        // BibleViewModel is responsible for setting its own currentChapterNumber
        // when a book is loaded (via selectBookAndLoadContent).
        // RecitationManager should not interfere with this initial setting.

        if !initialStatus.isEmpty {
            self.statusMessage = initialStatus
        } else if currentBookContentVerses.isEmpty {
            self.statusMessage = "\(currentBookDisplayName) has no recitable verses."
            if bibleViewModel.verses.isEmpty && bibleViewModel.selectedBook != nil { // Changed from paragraphs
                 self.statusMessage = "Error loading \(currentBookDisplayName), or no verses found."
                 self.flowState = .error("Load Failed or Empty")
            }
        } else {
            if let firstChapter = bibleViewModel.currentChapterNumber {
                 self.statusMessage = "Tap 'Start Reciting' for \(currentBookDisplayName) Chapter \(firstChapter)."
            } else {
                 self.statusMessage = "Tap 'Start Reciting' for \(currentBookDisplayName)."
            }
        }
    }
    
    private func repopulateRevealedItemIDsForCurrentBook() {
        guard let bookName = self.currentBookName else { // Changed from currentBookFile, currentBookFileName
            self.revealedInCurrentBookItemIDs = []; return
        }
        let identifiersForThisBook = allPersistedRevealedIdentifiers.filter { $0.bookName == bookName } // Changed from bookFileName
        var newRevealedIDsInBook = Set<UUID>()
        for verse in currentBookContentVerses { // Changed item to verse
            let verseAsRevealedIdentifier = RevealedVerseIdentifier( // Changed item to verse
                bookName: bookName, // Changed from bookFileName
                chapterNumber: verse.chapterNumber ?? 0,
                verseNumber: verse.verseNumber ?? 0
            )
            if identifiersForThisBook.contains(verseAsRevealedIdentifier) {
                newRevealedIDsInBook.insert(verse.id)
            }
        }
        self.revealedInCurrentBookItemIDs = newRevealedIDsInBook
    }

    func handleMainButtonTap() {
        if isRecitationActive {
            stopRecitationProcessInternal(preserveError: false, preserveMessage: false) { [weak self] in
                guard let self = self else { return }
                if self.flowState != .completedAll && !self.flowState.isError { self.statusMessage = "Recitation stopped." }
            }
        } else {
            startFullRecitationProcess()
        }
    }
    
    private func startFullRecitationProcess() {
        guard currentBookName != nil else { // Changed from currentBookFileName
            statusMessage = "No book selected."; flowState = .error("No book"); return
        }
        guard !currentBookContentVerses.isEmpty else {
            statusMessage = "No verses to recite for \(currentBookDisplayName)."; flowState = .error("No verses"); return
        }
        
        if let targetChapter = bibleViewModel.currentChapterNumber,
           currentRecitingVerse?.chapterNumber != targetChapter { // Renamed from currentRecitingItem
            if let firstVerseInTargetChapter = currentBookContentVerses.firstIndex(where: { $0.chapterNumber == targetChapter }) {
                currentRecitableItemIndex = firstVerseInTargetChapter
            } else if !currentBookContentVerses.isEmpty {
                currentRecitableItemIndex = 0
                bibleViewModel.updateCurrentChapter(for: currentRecitingVerse) // Renamed from currentRecitingItem
            }
        } else if currentRecitableItemIndex >= currentBookContentVerses.count, !currentBookContentVerses.isEmpty {
            currentRecitableItemIndex = 0
            bibleViewModel.updateCurrentChapter(for: currentRecitingVerse) // Renamed from currentRecitingItem
        }


        stopRecitationProcessInternal(preserveError: false, preserveMessage: false) { [weak self] in
            guard let self = self else { return }
            self.isRecitationActive = true
            self.resetVerseProgressState()
            self.speechServiceManager.recognizedText = ""; self.userRecitedTextForDisplay = ""
            self.bibleViewModel.updateCurrentChapter(for: self.currentRecitingVerse) // Renamed from currentRecitingItem
            self.processNextActionForVerse()
        }
    }

    func handleVerseTap(verse: Verse, proxy: ScrollViewProxy? = nil) { // Parameter changed to verse: Verse
        guard let tappedIndex = currentBookContentVerses.firstIndex(where: { $0.id == verse.id }) else { return }
        
        stopRecitationProcessInternal(preserveError: false, preserveMessage: false) { [weak self] in
            guard let self = self else { return }
            self.speechServiceManager.recognizedText = ""; self.userRecitedTextForDisplay = ""
            self.currentRecitableItemIndex = tappedIndex
            self.resetVerseProgressState()
            self.bibleViewModel.selectChapter(verse.chapterNumber)
            
            self.statusMessage = "Jumping to \(self.currentBookDisplayName) \(verse.identifierLabel)..."
            self.isRecitationActive = true
            self.processNextActionForVerse()
        }
    }

    func jumpToChapter(_ chapterNumber: Int) {
        bibleViewModel.selectChapter(chapterNumber)
    }

    private func handleExternalChapterChange(to chapterNumber: Int) {
        let wasReciting = self.isRecitationActive
        stopRecitationProcessInternal(preserveError: false, preserveMessage: false) { [weak self] in
            guard let self = self else { return }
            
            if let firstVerseIndexInNewChapter = self.currentBookContentVerses.firstIndex(where: { $0.chapterNumber == chapterNumber && $0.isRecitable }) {
                self.currentRecitableItemIndex = firstVerseIndexInNewChapter
                self.resetVerseProgressState()
                self.speechServiceManager.recognizedText = ""
                self.userRecitedTextForDisplay = ""
                
                self.statusMessage = "Switched to \(self.currentBookDisplayName) Chapter \(chapterNumber)."
                if wasReciting {
                    self.isRecitationActive = false
                    self.flowState = .idle
                }

            } else {
                self.currentRecitableItemIndex = self.currentBookContentVerses.firstIndex(where: {$0.chapterNumber == chapterNumber }) ?? 0
                self.statusMessage = "Chapter \(chapterNumber) selected in \(self.currentBookDisplayName), but no recitable verses found."
            }
        }
    }
    
    private func stopRecitationProcessInternal(preserveError: Bool = false, preserveMessage: Bool = false, completion: (() -> Void)? = nil) {
        let wasActive = self.isRecitationActive
        if self.isRecitationActive { self.isRecitationActive = false }

        let group = DispatchGroup()
        if speechServiceManager.isSpeaking  {
            group.enter(); speechServiceManager.stopTTSSpeaking { group.leave() }
        }
        if speechServiceManager.isRecording {
            group.enter(); speechServiceManager.stopRecording { group.leave() }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            if wasActive && !preserveError && !preserveMessage && self.flowState != .completedAll && !self.flowState.isError {
                // Status message is typically set by caller or specific condition
            }
            if !preserveError { if self.flowState != .completedAll && !self.flowState.isError { self.flowState = .idle } }
            completion?()
        }
    }

    private func setupSpeechServiceCallbacks() {
        speechServiceManager.onTtsDidFinish = { [weak self] in
            guard let self = self, self.flowState == .speaking, self.isRecitationActive else {
                if let strongSelf = self {
                    print("RecitationManager: onTtsDidFinish called but guard failed. FlowState: \(strongSelf.flowState), IsRecitationActive: \(strongSelf.isRecitationActive)")
                } else {
                    print("RecitationManager: onTtsDidFinish called but self was nil.")
                }
                return
            }
            print("RecitationManager: TTS finished, proceeding to start listening.")
            self.startListeningForSegmentRecitation()
        }
        speechServiceManager.onSttFinalRecognition = { [weak self] utterance in
            guard let self = self, self.flowState == .listening, self.isRecitationActive else { return }
            self.userRecitedTextForDisplay = utterance
            self.checkUserRecitationOfCurrentSegment(utterance)
        }
        speechServiceManager.onSttError = { [weak self] error in
            guard let self = self, self.isRecitationActive else { return }
            let (errMsg, flowErr) = SpeechServiceManager.formatError(error, context: "ASR Error")
            self.statusMessage = errMsg; self.flowState = flowErr
            self.stopRecitationProcessInternal(preserveError: true, preserveMessage: true)
        }
    }
    
    private func processNextActionForVerse() {
        guard isRecitationActive else {
            stopRecitationProcessInternal(preserveError: flowState.isError, preserveMessage: flowState.isError); return
        }
        
        guard let currentVerse = currentRecitingVerse else { // Renamed currentItem to currentVerse
            handleEndOfBookOrError(reason: "No current verse item."); return
        }
        
        bibleViewModel.updateCurrentChapter(for: currentVerse)

        if verseWordUnits.isEmpty && currentWordUnitIndex == 0 {
            // Tokenize the current verse using the new RecitationTokenizer
            let tokenizationResult = RecitationTokenizer.tokenizeVerse(
                verseText: currentVerse.value,
                wordLimitForChunk: AppSettings.shared.wordLimitForRecitationChunk,
                normalizeFunction: self.recitationChecker.normalizeAndSplit // Pass the normalization function
            )
            self.verseWordUnits = tokenizationResult.wordUnits
            self.totalValidWordsInCurrentVerse = tokenizationResult.totalValidWords
            
            currentVerseRecitedWordCount = 0
            if totalValidWordsInCurrentVerse == 0 {
                print("RecitationManager: Verse \(currentVerse.identifierLabel) has 0 valid words after tokenization. Advancing.")
                handleVerseFullyRecitedAndAdvance(); return
            }
        }

        if currentWordUnitIndex >= verseWordUnits.count {
            if currentVerseRecitedWordCount >= totalValidWordsInCurrentVerse || totalValidWordsInCurrentVerse == 0 {
                 print("RecitationManager: All units processed for \(currentVerse.identifierLabel). Recited words: \(currentVerseRecitedWordCount), Total: \(totalValidWordsInCurrentVerse). Advancing.")
                 handleVerseFullyRecitedAndAdvance()
            } else {
                print("RecitationManager: Warning - All units processed for \(currentVerse.identifierLabel) but word counts mismatch. Recited: \(currentVerseRecitedWordCount), Total: \(totalValidWordsInCurrentVerse). Forcing verse completion.")
                handleVerseFullyRecitedAndAdvance()
            }
            return
        }

        let currentUnit = verseWordUnits[currentWordUnitIndex]
        speakTextForCurrentSegment(currentUnit.originalTextSpan)
    }

    private func speakTextForCurrentSegment(_ text: String) {
        print("RecitationManager: speakTextForCurrentSegment - Speaking: \"\(text.prefix(50))\(text.count > 50 ? "..." : "")\"")
        flowState = .speaking
        let progressPercentage = totalValidWordsInCurrentVerse > 0 ? Int((Double(currentVerseRecitedWordCount) / Double(totalValidWordsInCurrentVerse)) * 100) : 0
        statusMessage = "Listen (\(progressPercentage)% done): \(currentBookDisplayName) \(currentRecitingVerse?.identifierLabel ?? "")" // Renamed currentRecitingItem
        
        let speakSuccess = speechServiceManager.speak(text: text)
        print("RecitationManager: speakTextForCurrentSegment - speechServiceManager.speak() returned: \(speakSuccess)")
        if !speakSuccess {
            print("RecitationManager: speakTextForCurrentSegment - TTS failed to start. Current flowState before error: \(self.flowState)")
            let (errMsg, flowErr) = SpeechServiceManager.formatError(nil, context: "TTS Failed", specificError: "Could not speak segment.")
            self.statusMessage = errMsg; self.flowState = flowErr
            print("RecitationManager: speakTextForCurrentSegment - TTS failed. New flowState: \(self.flowState), Message: \(errMsg)")
            stopRecitationProcessInternal(preserveError: true, preserveMessage: true)
        }
    }
    
    private func startListeningForSegmentRecitation() {
        print("RecitationManager: startListeningForSegmentRecitation - Entered function.")
        guard isRecitationActive else {
            print("RecitationManager: startListeningForSegmentRecitation - Guard failed: isRecitationActive is false. Stopping.")
            stopRecitationProcessInternal(preserveError: flowState.isError, preserveMessage: flowState.isError); return
        }
        print("RecitationManager: startListeningForSegmentRecitation - Setting flowState to .listening and updating statusMessage.")
        flowState = .listening
        statusMessage = "Your turn for this part..."
        userRecitedTextForDisplay = ""; speechServiceManager.recognizedText = ""
        do {
            print("RecitationManager: startListeningForSegmentRecitation - Attempting to start recording.")
            try speechServiceManager.startRecording()
            print("RecitationManager: startListeningForSegmentRecitation - speechServiceManager.startRecording() called successfully.")
        } catch {
            let (errMsg, flowErr) = SpeechServiceManager.formatError(error, context: "Mic Error")
            print("RecitationManager: startListeningForSegmentRecitation - Error starting recording: \(errMsg)")
            self.statusMessage = errMsg; self.flowState = flowErr
            stopRecitationProcessInternal(preserveError: true, preserveMessage: true)
        }
    }

    private func checkUserRecitationOfCurrentSegment(_ userRecitation: String) {
        guard isRecitationActive, currentWordUnitIndex < verseWordUnits.count else {
            if !isRecitationActive {
                print("RecitationManager: checkUserRecitationOfCurrentSegment - Recitation not active.")
            } else {
                print("RecitationManager: checkUserRecitationOfCurrentSegment - Internal error: No segment/index out of bounds. currentWordUnitIndex: \(currentWordUnitIndex), verseWordUnits.count: \(verseWordUnits.count)")
                statusMessage = "Internal error: No segment to compare or index out of bounds."; flowState = .error("Data Error")
            }
            return
        }
        
        let currentUnit = verseWordUnits[currentWordUnitIndex]
        let segmentToCompare = currentUnit.originalTextSpan
        
        flowState = .checking
        let accuracy = AppSettings.shared.requiredAccuracy
        let checkResult = recitationChecker.check(userRecitation: userRecitation,
                                                  against: segmentToCompare,
                                                  accuracy: accuracy)

        if checkResult.type == .fullMatch {
            currentVerseRecitedWordCount += currentUnit.validWordCount
            currentWordUnitIndex += 1
            
            statusMessage = "Correct!"
            if currentUnit.endsWithSentenceTerminator { statusMessage += " Next verse..." }
            else if currentUnit.endsWithClauseTerminator { statusMessage += " Continuing..." }
            else if currentWordUnitIndex < verseWordUnits.count { statusMessage += " Next part..." }
            
            flowState = .verseCorrect
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.processNextActionForVerse()
            }
        } else {
            let baseMessage = userRecitation.isEmpty ? "Didn't catch that. " : "Not quite. "
            statusMessage = "\(baseMessage)Try this part again."
            flowState = .verseIncorrect
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self = self, self.isRecitationActive else { return }
                self.speakTextForCurrentSegment(segmentToCompare)
            }
        }
    }

    private func handleVerseFullyRecitedAndAdvance() {
        guard let completedVerse = currentRecitingVerse else { // Renamed from completedItem
            print("RecitationManager: handleVerseFullyRecitedAndAdvance - No completedVerse. Bailing.")
            return
        }

        print("RecitationManager: Verse \(completedVerse.identifierLabel) fully recited.")
        statusMessage = "Verse complete! \(currentBookDisplayName) \(completedVerse.identifierLabel)"
        flowState = .verseCorrect
        revealedInCurrentBookItemIDs.insert(completedVerse.id)
        
        if let bookName = currentBookName, // Changed from bookFile, currentBookFileName
           let ch = completedVerse.chapterNumber,
           let vn = completedVerse.verseNumber {
            let idToPersist = RevealedVerseIdentifier(bookName: bookName, chapterNumber: ch, verseNumber: vn) // Changed from bookFileName
            if allPersistedRevealedIdentifiers.insert(idToPersist).inserted {
                PersistenceManager.saveRevealedVerses(allPersistedRevealedIdentifiers)
            }
        }
        
        resetVerseProgressState()
        
        let previousVerseChapter = completedVerse.chapterNumber // Renamed from previousItemChapter
        currentRecitableItemIndex += 1
        
        guard currentRecitableItemIndex < currentBookContentVerses.count else {
            bibleViewModel.updateCurrentChapter(for: nil)
            handleEndOfBookOrError(reason: "All verses in book recited.")
            return
        }

        let nextVerse = currentRecitingVerse! // Renamed from nextItem, type is Verse
        
        if nextVerse.chapterNumber != previousVerseChapter {
            print("RecitationManager: Auto-advancing to Chapter \(nextVerse.chapterNumber ?? 0)")
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self, self.isRecitationActive else { return }
            self.processNextActionForVerse()
        }
    }
    
    private func handleEndOfBookOrError(reason: String? = nil) {
        let defaultReason = "Error or end of book."
        if currentBookContentVerses.isEmpty {
            flowState = .error("No verses for \(currentBookDisplayName)."); statusMessage = "No verses in \(currentBookDisplayName)."
        } else if currentRecitableItemIndex >= currentBookContentVerses.count {
            flowState = .completedAll
            statusMessage = revealedInCurrentBookItemIDs.count == currentBookContentVerses.count ?
                "Congrats! All verses in \(currentBookDisplayName) recited." :
                "Finished \(currentBookDisplayName). Tap 'Start' for another round."
        } else {
            flowState = .error("Data Error"); statusMessage = reason ?? defaultReason
        }
        print("RecitationManager: handleEndOfBookOrError - Reason: \(reason ?? defaultReason). FlowState: \(flowState), Status: \(statusMessage)")
        stopRecitationProcessInternal(preserveError: true, preserveMessage: true)
    }
    
    func flowStateIsActiveForCurrentVerse() -> Bool { flowState.isActiveForCurrentVerse }

    public func refreshRevealedStatus() {
        self.allPersistedRevealedIdentifiers = PersistenceManager.loadRevealedVerses()
        repopulateRevealedItemIDsForCurrentBook()
    }
}
