// VerseScrollView.swift
import SwiftUI

struct VerseScrollView: View {
    @ObservedObject var recitationManager: RecitationManager
    @ObservedObject var bibleViewModel: BibleViewModel // Renamed from paragraphViewModel
    @ObservedObject private var settings = AppSettings.shared
    let isLoadingContent: Bool
    let currentBookDisplayName: String

    private var bottomPaddingForContent: CGFloat {
        // Button height (68) + button's ZStack bottom padding in ContentView (40) + extra spacing (16)
        return 68 + 40 + 16 // Total: 124
    }

    var body: some View {
        Group {
            if isLoadingContent {
                ProgressView("Loading \(currentBookDisplayName)...").padding()
            } else if bibleViewModel.availableChapters.isEmpty && bibleViewModel.selectedBook != nil {
                Text("No chapters available in \(currentBookDisplayName).")
                    .foregroundColor(.secondary).padding()
            } else if bibleViewModel.selectedBook == nil {
                 Text("Select a book to begin.")
                    .foregroundColor(.secondary).padding()
            }
            else {
                TabView(selection: $bibleViewModel.currentChapterNumber) {
                    ForEach(bibleViewModel.availableChapters, id: \.self) { chapterNum in
                        ScrollViewReader { scrollViewProxy in
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 10) {
                                    if bibleViewModel.versesForCurrentChapter.isEmpty {
                                        Text("No recitable verses in \(currentBookDisplayName) Chapter \(chapterNum).")
                                            .foregroundColor(.secondary).padding()
                                    } else {
                                        ForEach(bibleViewModel.versesForCurrentChapter) { verse in // Renamed item to verse
                                            VerseRowView(
                                                verse: verse, // Changed from item
                                                isRevealed: recitationManager.revealedInCurrentBookItemIDs.contains(verse.id), // Changed from item
                                                isCurrentAndActive: recitationManager.isRecitationActive &&
                                                                    verse.id == recitationManager.currentRecitingVerse?.id && // Changed from item and currentRecitingItem
                                                                    recitationManager.flowState.isActiveForCurrentVerse,
                                                blurCurrentActiveVerse: settings.hideVerseWhileReciting,
                                                blurOtherUnrecitedVerses: settings.blurUnrecitedVerses,
                                                onTap: { recitationManager.handleVerseTap(verse: verse, proxy: scrollViewProxy) } // Changed from item
                                            ).id(verse.id) // Changed from item
                                        }
                                    }
                                }
                                .padding(.horizontal)
                                .padding(.top)
                                .padding(.bottom, bottomPaddingForContent) // Adjusted bottom padding
                            }
                            .onChange(of: recitationManager.currentRecitableItemIndex) { _ in
                                if let currentVerse = recitationManager.currentRecitingVerse, // Changed from currentItem
                                   currentVerse.chapterNumber == chapterNum {
                                    scrollToVerseInList(proxy: scrollViewProxy,
                                                        versesInChapter: bibleViewModel.versesForCurrentChapter,
                                                        itemID: currentVerse.id)
                                }
                            }
                            .onChange(of: recitationManager.flowState) { _ in
                                if recitationManager.flowState.isActiveForCurrentVerse,
                                   let currentVerse = recitationManager.currentRecitingVerse, // Changed from currentItem
                                   currentVerse.chapterNumber == chapterNum {
                                    scrollToVerseInList(proxy: scrollViewProxy,
                                                        versesInChapter: bibleViewModel.versesForCurrentChapter,
                                                        itemID: currentVerse.id)
                                }
                            }
                        }
                        .tag(Optional(chapterNum))
                    }
                }
                .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
                .onAppear {
                    if bibleViewModel.currentChapterNumber == nil && !bibleViewModel.availableChapters.isEmpty {
                        bibleViewModel.currentChapterNumber = bibleViewModel.availableChapters.first
                    }
                }
            }
        }
    }

    private func scrollToVerseInList(proxy: ScrollViewProxy, versesInChapter: [Verse], itemID: UUID, anchor: UnitPoint = .center, animated: Bool = true) { // Parameter type changed to [Verse]
        if versesInChapter.contains(where: { $0.id == itemID }) {
            if animated {
                withAnimation(.easeInOut(duration: 0.5)) { proxy.scrollTo(itemID, anchor: anchor) }
            } else {
                proxy.scrollTo(itemID, anchor: anchor)
            }
        }
    }
}
