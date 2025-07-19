// ContentViewToolbar.swift
import SwiftUI

struct ContentViewToolbar: ToolbarContent {
    // Dependencies needed by the toolbar items
    @ObservedObject var bibleViewModel: BibleViewModel // Renamed from paragraphViewModel
    @ObservedObject var recitationManager: RecitationManager // Added RecitationManager
    @Binding var showingSettingsSheet: Bool

    // This computed property provides the display name for the current book.
    // It's calculated based on the bibleViewModel's state, similar to how it was in ContentView.
    // This is used by BookSelectionMenuView.
    private var currentBookDisplayName: String {
        bibleViewModel.selectedBook?.name ?? (bibleViewModel.books.isEmpty && !bibleViewModel.isLoadingBooks ? "No Books" : "Select Book")
    }

    // The body of ToolbarContent defines the actual toolbar items
    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            BookSelectionMenuView(
                bibleViewModel: bibleViewModel, // Renamed from paragraphViewModel
                currentBookDisplayName: currentBookDisplayName
            )
            
            // Conditionally display ChapterSelectionMenuView if a book is selected
            if bibleViewModel.selectedBook != nil {
                ChapterSelectionMenuView(
                    bibleViewModel: bibleViewModel, // Renamed from paragraphViewModel
                    recitationManager: recitationManager
                )
            }
        }
        
        ToolbarItem(placement: .navigationBarLeading) {
            SettingsButtonView(showingSettingsSheet: $showingSettingsSheet)
        }
    }
}

struct BookSelectionMenuView: View {
    @ObservedObject var bibleViewModel: BibleViewModel // Renamed from paragraphViewModel
    let currentBookDisplayName: String

    var body: some View {
        Menu {
            if bibleViewModel.isLoadingBooks { Text("Loading Books...") }
            else if bibleViewModel.books.isEmpty { Text("No Books Available") }
            else {
                ForEach(bibleViewModel.books) { book in
                    Button {
                        // Pass nil for initiallySelectedChapter; BVM will use its default logic
                        // (e.g., chapter 1 for Matthew, or first available chapter).
                        // If a specific chapter was saved for this book, it should be handled by BVM's logic
                        // when it loads a book generally. Here, user is explicitly picking a new book.
                        // For now, let `selectBookAndLoadContent` handle chapter defaulting.
                        // If we want to restore the *specific* last chapter for *this* book,
                        // BVM's `selectBookAndLoadContent` needs to be smarter or we pass it here.
                        // The current BVM implementation will try to use AppSettings.lastSavedChapterNumber if the book matches AppSettings.lastSavedBookFile,
                        // or default.
                        bibleViewModel.selectBookAndLoadContent(book)
                    } label: {
                        HStack {
                            Text(book.name)
                            if bibleViewModel.selectedBook?.name == book.name {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        } label: {
            HStack { Text(currentBookDisplayName).font(.title3).fontWeight(.bold);
                Image(systemName: "chevron.down").font(.caption.weight(.bold)).foregroundColor(.blue)
            }
            .foregroundColor(.primary)
        }
        .disabled((bibleViewModel.books.isEmpty && !bibleViewModel.isLoadingBooks) || bibleViewModel.isLoadingBooks)
    }
}

// New View for Chapter Selection
struct ChapterSelectionMenuView: View {
    @ObservedObject var bibleViewModel: BibleViewModel // Renamed from paragraphViewModel
    @ObservedObject var recitationManager: RecitationManager

    private var currentChapterDisplay: String {
        return "\(bibleViewModel.currentChapterNumber ?? 1)"
    }

    var body: some View {
        Menu {
            // This menu content is shown when the user taps the chapter selector label.
            if bibleViewModel.isContentLoading {
                Text("Loading Chapters...")
            } else if bibleViewModel.availableChapters.isEmpty {
                Text(bibleViewModel.selectedBook != nil ? "No Chapters" : "Select a Book First")
            } else {
                ForEach(bibleViewModel.availableChapters, id: \.self) { chapter in
                    Button {
                        recitationManager.jumpToChapter(chapter)
                    } label: {
                        HStack {
                            Text("\(chapter)")
                            if bibleViewModel.currentChapterNumber == chapter {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        } label: {
            // This is the visible part of the chapter selector in the toolbar.
            // Only show text if there's a chapter to display or "Chapter" as a placeholder.
            if !currentChapterDisplay.isEmpty {
                HStack {
                    Text(currentChapterDisplay).font(.title3).fontWeight(.bold);
                    Image(systemName: "chevron.down").font(.caption.weight(.bold)).foregroundColor(.blue)
                }
                .foregroundColor(.primary)
            } else {
                // Fallback for when currentChapterDisplay is empty (e.g. book selected, but no chapters yet or content loading)
                // This scenario might be brief or indicate an empty book.
                // An empty HStack effectively hides the label if currentChapterDisplay is empty.
                HStack {}
            }
        }
        // Disable if content is loading or no chapters are available for the selected book.
        .disabled(bibleViewModel.isContentLoading || (bibleViewModel.selectedBook != nil && bibleViewModel.availableChapters.isEmpty))
    }
}


struct SettingsButtonView: View {
    @Binding var showingSettingsSheet: Bool
    var body: some View {
        Button { showingSettingsSheet = true } label: { Image(systemName: "gearshape.fill").foregroundColor(.blue) }
    }
}
