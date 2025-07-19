//  VerseRowView.swift
import SwiftUI

struct VerseRowView: View {
    let verse: Verse // Renamed from item, type changed to Verse
    let isRevealed: Bool
    let isCurrentAndActive: Bool
    let blurCurrentActiveVerse: Bool
    let blurOtherUnrecitedVerses: Bool
    let onTap: () -> Void

    private var shouldBlurText: Bool {
        if isRevealed {
            return false
        } else {
            if isCurrentAndActive {
                return blurCurrentActiveVerse
            } else {
                return blurOtherUnrecitedVerses
            }
        }
    }

    var body: some View {
        HStack(alignment: .top) {
            Text(verse.identifierLabel) // Changed from item
                .font(.caption.bold()).foregroundColor(.gray)
                .frame(width: 50, alignment: .trailing).padding(.top, 2)
            
            Text(verse.value ?? "") // Changed from item
                .font(.body)
                .padding(.leading, 4)
                .foregroundColor(isCurrentAndActive ? .blue : .primary)
                .fontWeight(isCurrentAndActive ? .semibold : .regular)
                .blur(radius: shouldBlurText ? 3.0 : 0)
            
            Spacer()
        }
        .contentShape(Rectangle()).onTapGesture(perform: onTap)
    }
}
