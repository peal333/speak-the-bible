//  StatusHeaderView.swift
import SwiftUI

struct StatusHeaderView: View {
    let statusMessage: String
    var body: some View {
        Text(statusMessage)
            .font(.headline).multilineTextAlignment(.center)
            .padding(.horizontal).frame(minHeight: 50)
    }
}
