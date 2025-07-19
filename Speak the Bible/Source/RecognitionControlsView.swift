//  RecognitionControlsView.swift
import SwiftUI

struct RecognitionControlsView: View {
    let recognizedTextDisplay: String
    @ObservedObject var speechServiceManager: SpeechServiceManager

    var body: some View {
        VStack {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(recognizedTextDisplay).padding().frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
                        .background(Color(.secondarySystemBackground)).cornerRadius(12).id("BOTTOM_REC")
                }
                .frame(height: 82)
                .onChange(of: speechServiceManager.recognizedText) { _ in withAnimation { proxy.scrollTo("BOTTOM_REC", anchor: .bottom) } }
            }
        }
        .padding()
    }
}
